import Foundation
import HomeKit
import SwiftData

// MARK: - ToolDispatcher
//
// Maps tool names received from the LLM to calls on existing services.
// Phase 2: adds controlAccessory (write, reversible) and proposeAction (structured button).
// Security carve-out: locks, alarm, garage door CANNOT be executed via chat.

@MainActor
final class ToolDispatcher {

    private let environmentVM:        EnvironmentViewModel
    private let accessoriesVM:        AccessoriesViewModel
    private let homeKit:              HomeKitService
    private let weatherKit:           WeatherKitService
    private let behavioralService:    BehavioralAnalysisService
    private let ruleEngine:           RuleEngineService
    private let modelContainer:       ModelContainer
    private let smartLightingEngine:  SmartLightingEngine
    private let scenesService:        HomeKitScenesService

    /// Executor used for controlAccessory. NOT wrapped in performWithRetry (A3).
    private let executor = NextActionExecutor()

    /// Set by controlAccessory (undo), proposeAction (executeNow), or proposeOpportunity (reviewAutomation).
    /// Read by AgentLoopService after the text response to attach to AgentResponse.
    private(set) var lastActionPayload: AgentActionPayload?

    /// B2 — intra-session semantic dedup for proposeOpportunity.
    /// Key = "\(accessoryID):\(action)" — prevents duplicate rule proposals in one chat session.
    private var proposedSemanticKeys: Set<String> = []

    init(
        environmentVM:       EnvironmentViewModel,
        accessoriesVM:       AccessoriesViewModel,
        homeKit:             HomeKitService,
        weatherKit:          WeatherKitService,
        behavioralService:   BehavioralAnalysisService,
        ruleEngine:          RuleEngineService,
        modelContainer:      ModelContainer,
        smartLightingEngine: SmartLightingEngine,
        scenesService:       HomeKitScenesService
    ) {
        self.environmentVM       = environmentVM
        self.accessoriesVM       = accessoriesVM
        self.homeKit             = homeKit
        self.weatherKit          = weatherKit
        self.behavioralService   = behavioralService
        self.ruleEngine          = ruleEngine
        self.modelContainer      = modelContainer
        self.smartLightingEngine = smartLightingEngine
        self.scenesService       = scenesService
    }

    // MARK: - Security helpers

    /// HAP service-type UUID for SecuritySystem (no named constant in public HomeKit API).
    private static let securitySystemServiceType = "0000007E-0000-1000-8000-0026BB765291"

    private func isSecurityAccessory(_ accessory: HMAccessory) -> Bool {
        accessory.services.contains { service in
            let t = service.serviceType.uppercased()
            return t == Self.securitySystemServiceType ||
                   t == HMServiceTypeLockMechanism.uppercased() ||
                   t == HMServiceTypeGarageDoorOpener.uppercased()
        }
    }

    private func supportsAction(_ action: String, accessory: HMAccessory) -> Bool {
        guard !isSecurityAccessory(accessory) else { return false }

        let services = Set(accessory.services.map { $0.serviceType.lowercased() })
        let chars = Set(accessory.services
            .flatMap(\.characteristics)
            .map { $0.characteristicType.lowercased() })

        let lightbulb = "00000043-0000-1000-8000-0026bb765291"
        let cover = "0000008c-0000-1000-8000-0026bb765291"
        let humidifier = "000000bd-0000-1000-8000-0026bb765291"

        switch action {
        case "on", "off":
            return chars.contains("00000025-0000-1000-8000-0026bb765291")
                || chars.contains("000000b0-0000-1000-8000-0026bb765291")
        case "dim":
            return services.contains(lightbulb)
                && !services.contains(humidifier)
                && chars.contains("00000008-0000-1000-8000-0026bb765291")
        case "setColorTemp":
            return services.contains(lightbulb)
                && !services.contains(humidifier)
                && chars.contains("000000ce-0000-1000-8000-0026bb765291")
        case "open", "close":
            return services.contains(cover)
                && chars.contains("0000007c-0000-1000-8000-0026bb765291")
        case "setSpeed":
            return chars.contains("00000029-0000-1000-8000-0026bb765291")
        case "setTemp":
            return chars.contains("00000035-0000-1000-8000-0026bb765291")
        case "setHumidity":
            return chars.contains("000000ca-0000-1000-8000-0026bb765291")
                || chars.contains("000000c9-0000-1000-8000-0026bb765291")
        case "setMode":
            return chars.contains("000000b2-0000-1000-8000-0026bb765291")
                || chars.contains("00000033-0000-1000-8000-0026bb765291")
                || chars.contains("000000a8-0000-1000-8000-0026bb765291")
                || chars.contains("000000b4-0000-1000-8000-0026bb765291")
        default:
            return false
        }
    }

    private func supportsAutomationAction(_ action: String, accessory: HMAccessory) -> Bool {
        if supportsAction(action, accessory: accessory) {
            return true
        }

        let services = Set(accessory.services.map { $0.serviceType.lowercased() })
        let chars = Set(accessory.services
            .flatMap(\.characteristics)
            .map { $0.characteristicType.lowercased() })

        let lock = HMServiceTypeLockMechanism.lowercased()
        let garage = HMServiceTypeGarageDoorOpener.lowercased()
        let security = Self.securitySystemServiceType.lowercased()

        switch action {
        case "lock", "unlock":
            return services.contains(lock) && chars.contains("0000001e-0000-1000-8000-0026bb765291")
        case "open", "close", "openGarage", "closeGarage":
            return services.contains(garage) && chars.contains("00000032-0000-1000-8000-0026bb765291")
        case "armStay", "armAway", "armNight", "disarm", "setMode":
            return services.contains(security) && chars.contains("00000067-0000-1000-8000-0026bb765291")
        default:
            return false
        }
    }

    // MARK: - Capability helpers

    /// Returns a compact capability string for an accessory, e.g. "on/off+dim" or "on/off+setTemp".
    /// Used by listAccessories so the LLM knows what actions make sense without tool-round-trips.
    private func accessoryCapabilities(_ accessory: HMAccessory) -> String {
        let serviceTypes = Set(accessory.services.map { $0.serviceType.lowercased() })
        let charTypes = accessory.services
            .flatMap(\.characteristics)
            .map { $0.characteristicType.lowercased() }

        let lock = HMServiceTypeLockMechanism.lowercased()
        let garage = HMServiceTypeGarageDoorOpener.lowercased()
        let security = Self.securitySystemServiceType.lowercased()

        if serviceTypes.contains(lock) {
            return "automation:lock/unlock"
        }
        if serviceTypes.contains(garage) {
            return "automation:openGarage/closeGarage"
        }
        if serviceTypes.contains(security) {
            return "automation:armStay/armAway/armNight/disarm"
        }

        var caps: [String] = ["on/off"]

        let lightbulb  = "00000043-0000-1000-8000-0026bb765291"
        let humidifier = "000000bd-0000-1000-8000-0026bb765291"
        if serviceTypes.contains(lightbulb), !serviceTypes.contains(humidifier) {
            if charTypes.contains("00000008-0000-1000-8000-0026bb765291") { caps.append("dim") }
            if charTypes.contains("000000ce-0000-1000-8000-0026bb765291") { caps.append("setColorTemp") }
        }
        if charTypes.contains("00000035-0000-1000-8000-0026bb765291") { caps.append("setTemp") }
        if charTypes.contains("00000029-0000-1000-8000-0026bb765291") { caps.append("setSpeed") }
        // setMode: TargetHeaterCoolerState (AC), TargetHeatingCoolingState (thermostat/TRV), TargetAirPurifierState, TargetHumidifierDehumidifierState
        if charTypes.contains("000000b2-0000-1000-8000-0026bb765291")
            || charTypes.contains("00000033-0000-1000-8000-0026bb765291")
            || charTypes.contains("000000a8-0000-1000-8000-0026bb765291")
            || charTypes.contains("000000b4-0000-1000-8000-0026bb765291") { caps.append("setMode") }
        return caps.joined(separator: "+")
    }

    // MARK: - Accessory type label

    /// Returns a compact category label for an accessory based on its HAP service types.
    /// Used by listAccessories so the LLM can filter by type (luce, presa, etc.)
    private func accessoryTypeLabel(_ accessory: HMAccessory) -> String {
        let lightbulb  = "00000043-0000-1000-8000-0026bb765291"
        let outlet     = "00000047-0000-1000-8000-0026bb765291"
        let switchSvc  = "00000049-0000-1000-8000-0026bb765291"
        let fanV2      = "000000b7-0000-1000-8000-0026bb765291"
        let fanV1      = "00000040-0000-1000-8000-0026bb765291"
        let cover      = "0000008c-0000-1000-8000-0026bb765291"
        let thermostat = "0000004a-0000-1000-8000-0026bb765291"
        let lock       = "00000045-0000-1000-8000-0026bb765291"
        let garage     = "00000041-0000-1000-8000-0026bb765291"
        let airPurif   = "000000bb-0000-1000-8000-0026bb765291"
        let humidifier = "000000bd-0000-1000-8000-0026bb765291"
        let services   = Set(accessory.services.map { $0.serviceType.lowercased() })
        if services.contains(humidifier)                    { return "umidificatore" }
        if services.contains(airPurif)                      { return "purificatore" }
        if services.contains(thermostat)                    { return "termostato" }
        if services.contains(lock)                          { return "serratura" }
        if services.contains(garage)                        { return "portone" }
        if services.contains(Self.securitySystemServiceType.lowercased()) { return "sicurezza" }
        if services.contains(lightbulb)                     { return "luce" }
        if services.contains(outlet)                        { return "presa" }
        if services.contains(switchSvc)                     { return "interruttore" }
        if services.contains(fanV2) || services.contains(fanV1) { return "ventilatore" }
        if services.contains(cover)                         { return "tenda" }
        return "altro"
    }

    // MARK: - Power state helper

    /// Returns the current power state of an accessory using cached characteristic values.
    /// "on", "off", "on 80%" when the state is known; falls back to "online"/"offline".
    private func accessoryPowerState(_ accessory: HMAccessory) -> String {
        let allChars = accessory.services.flatMap(\.characteristics)

        func intVal(_ uuid: String) -> Int? {
            guard let char = allChars.first(where: { $0.characteristicType.lowercased() == uuid }),
                  let raw = homeKit.characteristicValues[char.uniqueIdentifier] else { return nil }
            if let i = raw as? Int { return i }
            if let n = raw as? NSNumber { return n.intValue }
            return nil
        }

        let activeUUID     = "000000b0-0000-1000-8000-0026bb765291"
        let onUUID         = "00000025-0000-1000-8000-0026bb765291"
        let brightnessUUID = "00000008-0000-1000-8000-0026bb765291"

        let isOn: Bool?
        if let v = intVal(activeUUID)    { isOn = v != 0 }
        else if let v = intVal(onUUID)   { isOn = v != 0 }
        else                             { isOn = nil }

        guard let on = isOn else {
            return homeKit.isReachable(accessory) ? "online" : "offline"
        }
        if on, let brightness = intVal(brightnessUUID) { return "on \(brightness)%" }
        return on ? "on" : "off"
    }

    // MARK: - Undo capture (pre-execution state snapshot)

    /// Reads characteristicValues BEFORE executing an action and builds the exact
    /// undo payload needed to restore the previous state.
    /// For on/off: reads actual power state (not assumed). For dim/setSpeed/setTemp:
    /// reads the actual current value so the undo restores the exact prior level.
    private func captureUndoPayload(
        for accessory: HMAccessory,
        action: String
    ) -> AgentActionPayload? {
        let id = accessory.uniqueIdentifier.uuidString
        let allChars = accessory.services.flatMap(\.characteristics)

        func intFromChars(_ charUUID: String) -> Int? {
            guard let char = allChars.first(where: { $0.characteristicType.lowercased() == charUUID }),
                  let raw = homeKit.characteristicValues[char.uniqueIdentifier] else { return nil }
            if let i = raw as? Int { return i }
            if let n = raw as? NSNumber { return n.intValue }
            return nil
        }

        switch action {
        case "on", "off":
            let activeUUID = "000000b0-0000-1000-8000-0026bb765291"
            let onUUID     = "00000025-0000-1000-8000-0026bb765291"
            let current = intFromChars(activeUUID) ?? intFromChars(onUUID)
            let undoAction: String
            let undoLabel: String
            if let c = current {
                undoAction = c == 1 ? "on" : "off"
                undoLabel  = c == 1 ? "Riaccendi" : "Spegni"
            } else {
                undoAction = action == "on" ? "off" : "on"
                undoLabel  = action == "on" ? "Spegni" : "Riaccendi"
            }
            return .undo(accessoryID: id, action: undoAction, value: nil, label: undoLabel)

        case "open":
            return .undo(accessoryID: id, action: "close", value: nil, label: "Chiudi")
        case "close":
            return .undo(accessoryID: id, action: "open", value: nil, label: "Riapri")

        case "dim":
            let brightnessUUID = "00000008-0000-1000-8000-0026bb765291"
            if let raw = intFromChars(brightnessUUID) {
                return .undo(accessoryID: id, action: "dim",
                             value: Double(raw) / 100.0, label: "Ripristina \(raw)%")
            }
            return .undo(accessoryID: id, action: "off", value: nil, label: "Spegni")

        case "setSpeed":
            let rotSpeedUUID = "00000029-0000-1000-8000-0026bb765291"
            if let raw = intFromChars(rotSpeedUUID) {
                return .undo(accessoryID: id, action: "setSpeed",
                             value: Double(raw) / 100.0, label: "Ripristina")
            }
            return nil

        case "setTemp":
            let targetTempUUID = "00000035-0000-1000-8000-0026bb765291"
            if let char = allChars.first(where: { $0.characteristicType.lowercased() == targetTempUUID }),
               let raw = homeKit.characteristicValues[char.uniqueIdentifier] {
                let temp: Double?
                if let d = raw as? Double { temp = d }
                else if let n = raw as? NSNumber { temp = n.doubleValue }
                else { temp = nil }
                if let t = temp {
                    return .undo(accessoryID: id, action: "setTemp",
                                 value: t, label: "Ripristina \(Int(t))°C")
                }
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Schemas sent to LLM

    static let tools: [ToolSchema] = [
        ToolSchema(
            name: "readSensor",
            description: "Legge il valore corrente di un sensore ambientale (temperatura, umidità, qualità aria, CO₂, PM2.5, PM10, ecc.). Se 'room' è omesso restituisce tutti i sensori di quel tipo in tutte le stanze — utile per trovare il sensore esterno senza conoscere la stanza.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "room": [
                        "type": "string",
                        "description": "Nome della stanza HomeKit (es. 'Cucina'). Ometti per cercare il sensore in tutte le stanze."
                    ],
                    "type": [
                        "type": "string",
                        "description": "Tipo sensore: temperature | humidity | airQuality | carbonMonoxide | carbonDioxide | smoke | vocDensity | pm25 | pm10 | lightSensor"
                    ]
                ],
                "required": ["type"]
            ]
        ),
        ToolSchema(
            name: "getRoomState",
            description: "Restituisce lo stato aggregato degli accessori di una stanza: conteggio, quanti sono online/offline, health score.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "room": [
                        "type": "string",
                        "description": "Nome della stanza (es. 'Cucina')"
                    ]
                ],
                "required": ["room"]
            ]
        ),
        ToolSchema(
            name: "listAccessories",
            description: "Elenca gli accessori HomeKit presenti in casa, opzionalmente filtrati per stanza.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "room": [
                        "type": "string",
                        "description": "Filtro stanza opzionale. Ometti per listare tutti gli accessori."
                    ]
                ],
                "required": []
            ]
        ),
        ToolSchema(
            name: "getHistory",
            description: "Restituisce lo storico dei sensori ambientali (min/max/media) per una stanza nelle ultime N ore. Utile per trend e confronti.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "room": [
                        "type": "string",
                        "description": "Nome della stanza. Ometti per tutte le stanze."
                    ],
                    "hours": [
                        "type": "integer",
                        "description": "Ore di storico da recuperare (default 24, max 168)."
                    ]
                ],
                "required": []
            ]
        ),
        ToolSchema(
            name: "getSecurityState",
            description: "Restituisce lo stato del sistema di sicurezza: allarme, serrature chiuse/aperte, sensori di contatto.",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "required": []
            ]
        ),
        ToolSchema(
            name: "getHabits",
            description: "Restituisce le abitudini comportamentali rilevate e le opportunità di automazione in attesa di approvazione.",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "required": []
            ]
        ),
        ToolSchema(
            name: "diagnoseAutomations",
            description: "Elenca e diagnostica le regole/automazioni create nell'app: trigger, azione, modalità HomeKit/In-App, stato enabled, scene collegate e problemi evidenti. Usa per domande come 'che automazioni ho?', 'perché non parte?', 'questa regola è sincronizzata con HomeKit?'.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Filtro opzionale su nome regola, descrizione, scena o azione."
                    ]
                ],
                "required": []
            ]
        ),
        ToolSchema(
            name: "getOutdoor",
            description: "Restituisce le condizioni meteo esterne correnti e la previsione per domani (richiede posizione casa configurata).",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "required": []
            ]
        ),
        ToolSchema(
            name: "controlAccessory",
            description: """
            Esegue un'azione su un accessorio HomeKit. \
            Richiede l'accessoryID (UUID) ottenuto da listAccessories. \
            VIETATO su serrature (LockMechanism), sistemi di allarme (SecuritySystem) e portoni garage. \
            Azioni supportate: on, off, dim (value 0.0–1.0), open, close, setSpeed (0.0–1.0), \
            setMode (int), setTemp (°C).
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "accessoryID": [
                        "type": "string",
                        "description": "UUID opzionale di un accessorio specifico (da listAccessories). Di norma NON serve: usa room + type."
                    ],
                    "action": [
                        "type": "string",
                        "description": "on | off | dim | open | close | setSpeed | setMode | setTemp"
                    ],
                    "value": [
                        "type": "number",
                        "description": "Valore per dim/setSpeed (0.0–1.0), setTemp (°C), setMode (int). Ometti per on/off/open/close."
                    ],
                    "room": [
                        "type": "string",
                        "description": "Nome stanza HomeKit in cui risolvere il target (es. 'Cucina')."
                    ],
                    "type": [
                        "type": "string",
                        "description": "Tipo accessori da colpire nella stanza: luci | prese | ventilatore | tende. Il tool risolve da solo gli accessori; non serve listAccessories prima."
                    ]
                ],
                "required": ["action"]
            ]
        ),
        ToolSchema(
            name: "proposeAction",
            description: """
            Propone un'azione all'utente come bottone senza eseguirla. \
            Usa SOLO dopo una risposta valutativa ("Vuoi accenderla?"). \
            Richiede l'accessoryID (UUID) da listAccessories. \
            NON usare per imperativi diretti — quelli vanno a controlAccessory.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "accessoryID": [
                        "type": "string",
                        "description": "UUID dell'accessorio target (da listAccessories)."
                    ],
                    "action": [
                        "type": "string",
                        "description": "on | off | dim | open | close"
                    ],
                    "value": [
                        "type": "number",
                        "description": "Valore per dim (0.0–1.0). Ometti per on/off/open/close."
                    ],
                    "label": [
                        "type": "string",
                        "description": "Testo del bottone (max 20 caratteri, es. 'Accendi', 'Spegni')."
                    ]
                ],
                "required": ["accessoryID", "action", "label"]
            ]
        ),
        ToolSchema(
            name: "chooseAccessory",
            description: """
            Mostra all'utente una lista di accessori come pills selezionabili. \
            Usa quando la richiesta è vaga e non specifica cosa fare \
            (es. "le luci in cucina" senza azione). \
            Per accessori on/off: imposta action="on" — il tap esegue direttamente. \
            Per accessori dim/setTemp senza valore: NON includere qui, chiedi prima il valore. \
            Richiede che gli accessoryID siano presi da listAccessories.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "accessories": [
                        "type": "array",
                        "description": "Lista degli accessori tra cui scegliere.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "id":   ["type": "string", "description": "UUID dell'accessorio (da listAccessories)."],
                                "name": ["type": "string", "description": "Nome leggibile dell'accessorio."]
                            ],
                            "required": ["id", "name"]
                        ]
                    ],
                    "action": [
                        "type": "string",
                        "description": "Azione da eseguire sull'accessorio scelto: dim | setTemp | setSpeed | setMode"
                    ],
                    "value": [
                        "type": "number",
                        "description": "Valore per l'azione (dim 0.0–1.0, setTemp °C). Ometti se da determinare dopo la scelta."
                    ],
                    "promptText": [
                        "type": "string",
                        "description": "Testo breve mostrato sopra le pills (es. 'Quale vuoi dimmerare?')."
                    ]
                ],
                "required": ["accessories", "action", "promptText"]
            ]
        ),
        ToolSchema(
            name: "createScene",
            description: """
            Crea una scena HomeKit (un insieme di azioni su più accessori eseguibili insieme). \
            Usa quando l'utente chiede di creare una scena ("crea una scena Cinema", \
            "imposta le luci in cucina a 2700K", ecc.). Per automazioni multi-azione native \
            usa proposeOpportunity con actions[] invece di creare una scena. \
            Prima chiama listAccessories per ottenere gli UUID e verificare le capabilities. \
            Includi SOLO gli accessori che supportano l'azione richiesta (controlla caps in listAccessories). \
            Valori per le azioni: \
            · setColorTemp: Kelvin (2700=caldo, 4000=neutro, 6500=freddo) — solo luci con caps:setColorTemp. \
            · setMode: per AC (caps:setMode) → 0=Auto, 1=Caldo, 2=Freddo; \
              per valvole termostatiche → 0=Off, 1=Caldo, 2=Freddo, 3=Auto; \
              per purificatori → 0=Manuale, 1=Auto; \
              per umidificatori/diffusori → 0=Auto, 1=Umidifica, 2=Deumidifica. \
              Attiva automaticamente il dispositivo. \
            · setSpeed: 0.0–1.0 (es. 1.0=100% velocità ventola). \
            · setTemp: °C (es. 22.0). \
            La scena viene creata direttamente su HomeKit ed è subito visibile nell'app e in Apple Home.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Nome della scena (es. 'Luce Calda Cucina', 'Cinema', 'Lettura'). Breve e descrittivo."
                    ],
                    "actions": [
                        "type": "array",
                        "description": "Lista delle azioni da includere nella scena.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "accessoryID": [
                                    "type": "string",
                                    "description": "UUID dell'accessorio (da listAccessories)."
                                ],
                                "action": [
                                    "type": "string",
                    "description": "on | off | dim | setColorTemp | setTemp | setSpeed | setMode | open | close"
                                ],
                                "value": [
                                    "type": "number",
                        "description": "dim: 0.0–1.0, setColorTemp: Kelvin (es. 2700), setTemp: °C, setSpeed: 0.0–1.0, setMode: valore intero della modalità. Ometti per on/off/open/close."
                                ]
                            ],
                            "required": ["accessoryID", "action"]
                        ]
                    ]
                ],
                "required": ["name", "actions"]
            ]
        ),
        ToolSchema(
            name: "listScenes",
            description: """
            Elenca le scene HomeKit personalizzate esistenti con il dettaglio delle azioni di ciascuna. \
            Usa quando l'utente vuole vedere, riusare o verificare una scena HomeKit esistente. \
            Parametro opzionale 'query': filtra per nome scena.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "Filtro opzionale: restituisce solo le scene il cui nome contiene questa stringa (case-insensitive)."
                    ]
                ],
                "required": []
            ]
        ),
        ToolSchema(
            name: "getLightingStatus",
            description: "Restituisce lo stato attuale dello Smart Lighting Engine: fase del giorno corrente, sunrise/sunset, profili configurati per stanza e log dell'ultima valutazione.",
            inputSchema: [
                "type": "object",
                "properties": [:],
                "required": []
            ]
        ),
        ToolSchema(
            name: "configureLighting",
            description: """
            Configura il profilo di illuminazione automatica per una stanza. \
            Crea un nuovo profilo o aggiorna uno esistente. \
            Per ogni fase del giorno (alba, mattino, pre-tramonto, tramonto, sera, notte) \
            specifica il nome della scena HomeKit da attivare. \
            Usa una stringa vuota "" per disabilitare una fase. \
            Prima chiama getLightingStatus per vedere i profili già configurati, \
            e listScenes (o listAccessories) per conoscere i nomi delle scene disponibili.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "roomName": [
                        "type": "string",
                        "description": "Nome della stanza HomeKit (es. 'Cucina', 'Soggiorno')."
                    ],
                    "isEnabled": [
                        "type": "boolean",
                        "description": "Abilita o disabilita il profilo. Default: true."
                    ],
                    "sceneDawn": [
                        "type": "string",
                        "description": "Nome scena HomeKit per la fase Alba (sunrise-60' → sunrise+90'). Stringa vuota per skip."
                    ],
                    "sceneMorning": [
                        "type": "string",
                        "description": "Nome scena HomeKit per la fase Mattino (sunrise+90' → sunset-120'). Stringa vuota per skip."
                    ],
                    "scenePreSunset": [
                        "type": "string",
                        "description": "Nome scena HomeKit per Pre-tramonto (sunset-120' → sunset-30'). Stringa vuota per skip."
                    ],
                    "sceneSunset": [
                        "type": "string",
                        "description": "Nome scena HomeKit per Tramonto (sunset-30' → sunset+45'). Stringa vuota per skip."
                    ],
                    "sceneEvening": [
                        "type": "string",
                        "description": "Nome scena HomeKit per Sera (sunset+45' → nightHour). Stringa vuota per skip."
                    ],
                    "sceneNight": [
                        "type": "string",
                        "description": "Nome scena HomeKit per Notte (nightHour → sleepHour o sunrise). Stringa vuota per skip. Usa una luce molto soffice (es. 5-10%) come scena Notte."
                    ],
                    "luxBypassThreshold": [
                        "type": "number",
                        "description": "Soglia lux sopra cui la luce naturale è sufficiente e l'engine non agisce (default 150, 0 per disabilitare il bypass)."
                    ],
                    "luxSensorRoomName": [
                        "type": "string",
                        "description": "Nome stanza del sensore lux se diversa dalla stanza controllata. Stringa vuota per usare la stessa stanza."
                    ],
                    "luxOffSceneName": [
                        "type": "string",
                        "description": "Nome scena HomeKit da attivare quando la luce naturale torna sopra soglia. Stringa vuota per non spegnere/cambiare nulla."
                    ],
                    "nightHour": [
                        "type": "integer",
                        "description": "Ora (0-23) in cui la fase 'Sera' diventa 'Notte' per questa stanza (default 23)."
                    ],
                    "sleepHour": [
                        "type": "integer",
                        "description": "Ora (0-23) in cui l'engine smette completamente di agire su questa stanza durante la notte. Dopo quest'ora le luci non vengono più toccate (rimangono nello stato manuale). Esempio: nightHour=23, sleepHour=1 → scena Notte attiva 23:00-01:00, poi silenzio fino al mattino."
                    ],
                    "wakeHour": [
                        "type": "integer",
                        "description": "Ora (0-23) prima della quale l'engine non attiva scene per questa stanza. Esempio: 7 evita accensioni prima delle 07:00."
                    ]
                ],
                "required": ["roomName"]
            ]
        ),
        ToolSchema(
            name: "proposeOpportunity",
            description: """
            Crea una proposta di automazione dalla conversazione e la mostra all'utente \
            come bottone di revisione nel nuovo Automation Builder e nella sezione Abitudini. \
            Usa quando l'utente chiede una regola/automazione oppure usa un comando con trigger \
            temporale o condizionale anche senza dire "automazione" \
            ("ogni sera alle 22 spegni le luci", "quando la porta si apre accendi i faretti", \
            "al tramonto attiva Relax", "20 minuti dopo il tramonto accendi le luci"). \
            NON usare per esecuzioni immediate — usa controlAccessory o proposeAction. \
            \
            Per azioni avanzate singole puoi usare direttamente accessoryID+action \
            (es. setMode value=2 value2=24 per clima in freddo a 24°C, lock/unlock, closeGarage, armAway). \
            Per automazioni multi-azione vere (es. "accendi AC in freddo e chiudi tende") usa \
            actions=[{accessoryID, action, value, value2}, ...] così il nuovo Automation Builder \
            riceve tutte le azioni native. Usa sceneName solo quando l'utente chiede esplicitamente \
            una scena o quando vuoi riusare una scena HomeKit esistente.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "accessoryID": [
                        "type": "string",
                        "description": "UUID dell'accessorio (da listAccessories). Obbligatorio se sceneName è assente."
                    ],
                    "action": [
                        "type": "string",
                        "description": "on | off | dim | open | close | openGarage | closeGarage | lock | unlock | setSpeed | setTemp | setMode | setHumidity | armStay | armAway | armNight | disarm. Obbligatorio se sceneName è assente."
                    ],
                    "sceneName": [
                        "type": "string",
                        "description": "Nome esatto di una scena HomeKit esistente o appena creata. Non usarlo per multi-azione native: in quel caso usa actions."
                    ],
                    "actions": [
                        "type": "array",
                        "description": "Azioni multiple native per Automation Builder. Usa per automazioni multi-azione senza creare scene.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "accessoryID": [
                                    "type": "string",
                                    "description": "UUID accessorio da listAccessories."
                                ],
                                "action": [
                                    "type": "string",
                                    "description": "on | off | dim | open | close | openGarage | closeGarage | lock | unlock | setSpeed | setTemp | setMode | setHumidity | armStay | armAway | armNight | disarm."
                                ],
                                "value": [
                                    "type": "number",
                                    "description": "Valore primario opzionale."
                                ],
                                "value2": [
                                    "type": "number",
                                    "description": "Valore secondario opzionale, es. target °C per setMode."
                                ]
                            ],
                            "required": ["accessoryID", "action"]
                        ]
                    ],
                    "value": [
                        "type": "number",
                        "description": "Valore primario: dim/setSpeed 0.0–1.0, setTemp °C, setMode mode int. Ometti per on/off/open/close/lock/unlock o quando si usa sceneName."
                    ],
                    "value2": [
                        "type": "number",
                        "description": "Valore secondario opzionale. Per setMode su climatizzatori/termostati usa la temperatura target in °C (es. setMode value=2, value2=24)."
                    ],
                    "label": [
                        "type": "string",
                        "description": "Titolo breve della regola — solo nome accessorio/scena e azione, SENZA orario né simboli speciali (es. 'Spegni Luci Cucina', 'Attiva AC Freddo'). L'orario va in naturalLanguage, non qui."
                    ],
                    "naturalLanguage": [
                        "type": "string",
                        "description": "Descrizione completa in linguaggio naturale mostrata in HabitsView (include orario, giorni, condizioni, ecc.)."
                    ],
                    "triggerType": [
                        "type": "string",
                        "description": "calendar (orario fisso, alba/tramonto) | characteristic (sensore/stato) | presence (arrivo/uscita casa) | inApp. Per 'alle 22:20', 'al tramonto', 'ogni mattina' usa calendar. Per 'quando arrivo a casa' o 'quando esco di casa' usa presence."
                    ],
                    "triggerScheduleKind": [
                        "type": "string",
                        "description": "fixedTime | sunrise | sunset. Usa sunset per 'al tramonto' e sunrise per 'all'alba'. Ometti o fixedTime per triggerTime HH:mm."
                    ],
                    "triggerOffsetMinutes": [
                        "type": "integer",
                        "description": "Offset in minuti rispetto ad alba/tramonto. Esempio: 20 minuti dopo il tramonto = 20, 15 minuti prima = -15."
                    ],
                    "triggerTime": [
                        "type": "string",
                        "description": "Ora in formato HH:mm (es. '22:20'). Obbligatorio se triggerType=calendar e triggerScheduleKind è fixedTime/omesso. Per 'mattino' senza ora usa 08:00."
                    ],
                    "triggerWeekdays": [
                        "type": "string",
                        "description": "Giorni come numeri 1-7 separati da virgola (1=domenica). Ometti per tutti i giorni."
                    ],
                    "triggerSensorType": [
                        "type": "string",
                        "description": "Tipo sensore che attiva la regola: temperature | humidity | airQuality | carbonDioxide | carbonMonoxide | vocDensity | pm25 | pm10 | lightSensor | contact | motion | occupancy | smoke | leak. Obbligatorio se triggerType=characteristic."
                    ],
                    "triggerSensorRoom": [
                        "type": "string",
                        "description": "Nome stanza del sensore trigger (es. 'Balcone'). Obbligatorio se triggerType=characteristic."
                    ],
                    "triggerSensorAccessoryName": [
                        "type": "string",
                        "description": "Nome o parola chiave dell'accessorio sensore da usare come trigger quando l'utente cita un target specifico, es. 'finestra', 'porta ingresso', 'sensore finestra Mansarda'. Serve a non scegliere un contatto qualsiasi nella stanza."
                    ],
                    "triggerThreshold": [
                        "type": "number",
                        "description": "Valore soglia numerica per il trigger (es. 30.0 per 30°C, 1200 per CO2 ppm). Obbligatorio per sensori numerici; omettere per contact/motion/occupancy/smoke/leak quando basta aperto/attivo."
                    ],
                    "triggerDirection": [
                        "type": "string",
                        "description": "above/open/active (sopra soglia o sensore attivo/aperto) | below/closed/inactive (sotto soglia o sensore chiuso/inattivo)."
                    ],
                    "triggerPresenceKind": [
                        "type": "string",
                        "description": "Per triggerType=presence: everyEntry quando arrivo a casa, everyExit quando esco di casa, firstEntry quando arriva la prima persona, lastExit quando esce l'ultima persona."
                    ],
                    "triggerPresenceUserScope": [
                        "type": "string",
                        "description": "Per triggerType=presence: currentUser per io/me, homeUsers per chiunque/tutti gli utenti della casa."
                    ],
                ],
                "required": ["label", "naturalLanguage", "triggerType"]
            ]
        )
    ]

    // MARK: - Dispatch

    func dispatch(toolName: String, input: [String: Any]) async -> String {
        switch toolName {
        case "readSensor":         return readSensor(input: input)
        case "getRoomState":       return getRoomState(input: input)
        case "listAccessories":    return listAccessories(input: input)
        case "getHistory":         return await getHistory(input: input)
        case "getSecurityState":   return getSecurityState(input: input)
        case "getHabits":          return getHabits(input: input)
        case "diagnoseAutomations": return diagnoseAutomations(input: input)
        case "getOutdoor":         return getOutdoor(input: input)
        case "controlAccessory":    return await controlAccessory(input: input)
        case "proposeAction":       return proposeAction(input: input)
        case "chooseAccessory":     return chooseAccessory(input: input)
        case "proposeOpportunity":  return proposeOpportunity(input: input)
        case "createScene":         return await createScene(input: input)
        case "listScenes":          return listScenes(input: input)
        case "getLightingStatus":   return getLightingStatus(input: input)
        case "configureLighting":   return configureLighting(input: input)
        default:
            return "Tool '\(toolName)' non riconosciuto. Tool disponibili: readSensor, getRoomState, listAccessories, getHistory, getSecurityState, getHabits, diagnoseAutomations, getOutdoor, controlAccessory, proposeAction, chooseAccessory, proposeOpportunity, createScene, listScenes, getLightingStatus, configureLighting."
        }
    }

    // MARK: - readSensor

    private func readSensor(input: [String: Any]) -> String {
        if environmentVM.isLoading {
            return "Dati ambientali in caricamento. Di' all'utente di attendere un istante; non ritentare subito."
        }

        guard let typeStr = input["type"] as? String else {
            return "Parametro mancante: 'type' è obbligatorio."
        }
        let typeNeedle = normalizedSensorType(typeStr).lowercased()

        // Senza stanza → restituisce tutti i sensori di quel tipo in ogni stanza.
        if let room = input["room"] as? String, !room.isEmpty {
            let needle = room.lowercased()
            guard let roomData = environmentVM.rooms.first(where: {
                $0.roomName.lowercased() == needle || $0.roomName.lowercased().contains(needle)
            }) else {
                let available = environmentVM.rooms.map(\.roomName).joined(separator: ", ")
                return "Nessun dato ambientale per '\(room)'. Stanze con sensori disponibili: \(available.isEmpty ? "nessuna (avvia campionamento dalla Dashboard Ambiente)" : available)."
            }
            guard let sensor = roomData.sensors.first(where: {
                $0.serviceType.rawValue.lowercased() == typeNeedle
            }) else {
                let available = roomData.sensors.map { $0.serviceType.displayName }.joined(separator: ", ")
                return "Nessun sensore '\(typeStr)' in '\(roomData.roomName)'. Sensori presenti: \(available.isEmpty ? "nessuno" : available)."
            }
            let thresholdText: String
            if sensor.warningThreshold > 0 || sensor.dangerThreshold > 0 {
                thresholdText = " | soglie: attenzione≥\(String(format: "%.1f", sensor.warningThreshold)), critica≥\(String(format: "%.1f", sensor.dangerThreshold))"
            } else {
                thresholdText = ""
            }
            return "\(sensor.serviceType.displayName) in \(roomData.roomName): \(sensor.formattedValue) (stato: \(sensor.urgency.label)\(thresholdText))"
        }

        // Room omessa → cerca il tipo in tutte le stanze e restituisce l'elenco.
        var results: [String] = []
        for roomData in environmentVM.rooms {
            if let sensor = roomData.sensors.first(where: {
                $0.serviceType.rawValue.lowercased() == typeNeedle
            }) {
                let thresholdText = (sensor.warningThreshold > 0 || sensor.dangerThreshold > 0)
                    ? " | soglie: attenzione≥\(String(format: "%.1f", sensor.warningThreshold)), critica≥\(String(format: "%.1f", sensor.dangerThreshold))"
                    : ""
                results.append("\(roomData.roomName): \(sensor.formattedValue) (stato: \(sensor.urgency.label)\(thresholdText))")
            }
        }
        if results.isEmpty {
            let available = environmentVM.rooms.map(\.roomName).joined(separator: ", ")
            return "Nessun sensore '\(typeStr)' trovato in nessuna stanza. Stanze disponibili: \(available.isEmpty ? "nessuna" : available)."
        }
        return "Sensori \(typeStr) rilevati:\n" + results.joined(separator: "\n")
    }

    // MARK: - getRoomState

    private func getRoomState(input: [String: Any]) -> String {
        guard let room = input["room"] as? String else {
            return "Parametro mancante: 'room' è obbligatorio."
        }

        let needle = room.lowercased()
        guard let roomData = accessoriesVM.rooms.first(where: {
            $0.roomName.lowercased() == needle || $0.roomName.lowercased().contains(needle)
        }) else {
            let available = accessoriesVM.rooms.map(\.roomName).joined(separator: ", ")
            return "Stanza '\(room)' non trovata. Stanze disponibili: \(available.isEmpty ? "nessuna" : available)."
        }

        let total = roomData.totalCount
        let offline = roomData.offlineCount
        let online = total - offline
        let score = roomData.healthScore

        let accessoryList = roomData.accessories.prefix(8).map { acc in
            let status = homeKit.isReachable(acc) ? "online" : "offline"
            return "\(acc.name) (\(status))"
        }.joined(separator: ", ")
        let more = roomData.accessories.count > 8 ? " + altri \(roomData.accessories.count - 8)" : ""

        return "Stanza \(roomData.roomName): \(total) accessori (\(online) online, \(offline) offline), health score \(score)/100. Accessori: \(accessoryList)\(more)."
    }

    // MARK: - listAccessories

    private func listAccessories(input: [String: Any]) -> String {
        let roomFilter = input["room"] as? String

        let roomsToSearch: [RoomAccessoryData]
        if let filter = roomFilter {
            let needle = filter.lowercased()
            roomsToSearch = accessoriesVM.rooms.filter {
                $0.roomName.lowercased() == needle || $0.roomName.lowercased().contains(needle)
            }
        } else {
            roomsToSearch = accessoriesVM.rooms
        }

        if roomsToSearch.isEmpty {
            return "Nessun accessorio trovato\(roomFilter.map { " nella stanza '\($0)'" } ?? "")."
        }

        var lines: [String] = []
        for r in roomsToSearch {
            for acc in r.accessories {
                let type  = accessoryTypeLabel(acc)
                let state = accessoryPowerState(acc)
                let caps  = accessoryCapabilities(acc)
                let uuid  = acc.uniqueIdentifier.uuidString
                lines.append("- \(acc.name) [\(r.roomName), \(type), \(state), caps:\(caps)] id=\(uuid)")
            }
        }

        guard !lines.isEmpty else { return "Nessun accessorio." }

        let capped = Array(lines.prefix(30))
        let suffix = lines.count > 30 ? "\n(+ altri \(lines.count - 30) accessori)" : ""
        return capped.joined(separator: "\n") + suffix
    }

    // MARK: - getHistory

    private func getHistory(input: [String: Any]) async -> String {
        if environmentVM.isLoading {
            return "Dati storici in caricamento. Di' all'utente di attendere un istante."
        }

        let roomFilter = input["room"] as? String
        let hours = min((input["hours"] as? Int) ?? 24, 168)
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate<SensorReading> { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let allReadings = (try? context.fetch(descriptor)) ?? []

        let filtered: [SensorReading]
        if let room = roomFilter {
            let needle = room.lowercased()
            filtered = allReadings.filter { $0.roomName.lowercased().contains(needle) }
        } else {
            filtered = allReadings
        }

        if filtered.isEmpty {
            return "Nessuna lettura trovata\(roomFilter.map { " per '\($0)'" } ?? "") nelle ultime \(hours)h."
        }

        struct GroupKey: Hashable { let room: String; let typeRaw: String }
        var groups: [GroupKey: [Double]] = [:]
        for r in filtered {
            let k = GroupKey(room: r.roomName, typeRaw: r.serviceTypeRaw)
            groups[k, default: []].append(r.value)
        }

        var lines: [String] = ["Storico ultime \(hours)h (\(filtered.count) letture):"]
        for (key, values) in groups.sorted(by: { $0.key.room < $1.key.room || ($0.key.room == $1.key.room && $0.key.typeRaw < $1.key.typeRaw) }) {
            let avg = values.reduce(0, +) / Double(values.count)
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 0
            let typeName = SensorServiceType(rawValue: key.typeRaw)?.displayName ?? key.typeRaw
            lines.append("- \(key.room) / \(typeName): avg \(String(format: "%.1f", avg)), min \(String(format: "%.1f", minV)), max \(String(format: "%.1f", maxV)) (\(values.count) camp.)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - getSecurityState

    private func getSecurityState(input: [String: Any]) -> String {
        var alarmState: String? = nil
        var lockedCount = 0, unlockedCount = 0
        var closedContacts = 0, openContacts = 0

        for acc in homeKit.allAccessories {
            for service in acc.services {
                for char in service.characteristics {
                    guard let number = char.value as? NSNumber else { continue }
                    let v = number.intValue
                    // HAP UUIDs: 0x66 = CurrentSecuritySystemState, 0x1D = CurrentLockMechanismState
                    switch char.characteristicType.lowercased() {
                    case "00000066-0000-1000-8000-0026bb765291":
                        switch v {
                        case 0: alarmState = "armato (in casa)"
                        case 1: alarmState = "armato (fuori casa)"
                        case 2: alarmState = "armato (notte)"
                        case 3: alarmState = "disarmato"
                        case 4: alarmState = "⚠️ ALLARME ATTIVO"
                        default: alarmState = "stato \(v)"
                        }
                    case HMCharacteristicTypeCurrentLockMechanismState.lowercased():
                        if v == 1 { lockedCount += 1 } else { unlockedCount += 1 }
                    case HMCharacteristicTypeContactState.lowercased():
                        if v == 0 { closedContacts += 1 } else { openContacts += 1 }
                    default:
                        break
                    }
                }
            }
        }

        var lines: [String] = []
        lines.append("Sistema di allarme: \(alarmState ?? "non rilevato")")
        if lockedCount + unlockedCount > 0 {
            lines.append("Serrature: \(lockedCount) chiuse, \(unlockedCount) aperte")
        }
        if openContacts + closedContacts > 0 {
            lines.append("Sensori contatto: \(openContacts) aperti, \(closedContacts) chiusi")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - getHabits

    private func getHabits(input: [String: Any]) -> String {
        let stable  = behavioralService.stablePatterns
        let pending = behavioralService.pendingOpportunities

        if stable.isEmpty && pending.isEmpty {
            return "Nessuna abitudine rilevata. L'analisi richiede alcune settimane di utilizzo."
        }

        var lines: [String] = []

        if !stable.isEmpty {
            lines.append("Abitudini confermate (\(stable.count)):")
            for p in stable.prefix(8) {
                let pct = Int(p.confidence * 100)
                lines.append("- \(p.accessoryName) [\(p.roomName)]: \(p.observations) osservazioni, \(pct)% confidenza")
            }
            if stable.count > 8 { lines.append("  (+ altri \(stable.count - 8))") }
        }

        if !pending.isEmpty {
            lines.append("Opportunità di automazione in attesa (\(pending.count)):")
            for opp in pending.prefix(5) {
                lines.append("- \(opp.title): \(opp.naturalLanguage)")
            }
            if pending.count > 5 { lines.append("  (+ altre \(pending.count - 5))") }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - diagnoseAutomations

    private func diagnoseAutomations(input: [String: Any]) -> String {
        let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let rules = ruleEngine.rules.filter { rule in
            guard let query, !query.isEmpty else { return true }
            let haystack = [
                rule.name,
                rule.ruleDescription,
                rule.actionSceneName ?? "",
                rule.actionType,
                rule.triggerType
            ].joined(separator: " ").lowercased()
            return haystack.contains(query)
        }

        guard !rules.isEmpty else {
            lastActionPayload = .automationDiagnostics(
                title: String(localized: "chat.diagnostics.title", defaultValue: "Automazioni"),
                items: []
            )
            return query == nil
                ? "Nessuna automazione attiva nell'app."
                : "Nessuna automazione corrisponde al filtro '\(query ?? "")'."
        }

        let homeTriggers = Set(homeKit.currentHome?.triggers.map { $0.uniqueIdentifier.uuidString } ?? [])
        let sceneNames = Set(homeKit.currentHome?.actionSets.map { $0.name.lowercased() } ?? [])
        let accessoryIDs = Set(homeKit.allAccessories.map { $0.uniqueIdentifier.uuidString })

        var lines: [String] = ["Automazioni nell'app (\(rules.count)):"]
        var diagnosticItems: [AutomationDiagnosticItem] = []
        for rule in rules.prefix(12) {
            var issues: [String] = []
            if !rule.isEnabled {
                issues.append("disabilitata")
            }
            if rule.executionMode == "homeKit" {
                if let triggerID = rule.homeKitTriggerID {
                    if !homeTriggers.contains(triggerID) {
                        issues.append("trigger HomeKit non trovato")
                    }
                } else {
                    issues.append("trigger HomeKit assente")
                }
            }
            if let sceneName = rule.actionSceneName {
                if !sceneNames.contains(sceneName.lowercased()) {
                    issues.append("scena non trovata")
                }
            } else if !rule.actionAccessoryID.isEmpty,
                      !accessoryIDs.contains(rule.actionAccessoryID) {
                issues.append("accessorio non trovato")
            }
            if rule.triggerType == "calendar", rule.triggerTime == nil {
                issues.append("orario mancante")
            }
            if rule.triggerType == "characteristic",
               (rule.triggerCharacteristicID == nil || rule.triggerThreshold == nil) {
                issues.append("soglia sensore incompleta")
            }

            let status = issues.isEmpty ? "ok" : issues.joined(separator: ", ")
            let sceneOrAction = rule.actionSceneName.map { "scena '\($0)'" } ?? automationActionSummary(rule)
            diagnosticItems.append(AutomationDiagnosticItem(
                title: rule.name,
                trigger: automationTriggerSummary(rule),
                action: sceneOrAction,
                mode: rule.executionModeLabel,
                isEnabled: rule.isEnabled,
                status: status
            ))
            lines.append("- \(rule.name): \(rule.isEnabled ? "attiva" : "spenta"), \(rule.executionModeLabel), trigger \(automationTriggerSummary(rule)), azione \(sceneOrAction), stato: \(status)")
        }
        if rules.count > 12 {
            lines.append("(+ altre \(rules.count - 12) automazioni)")
        }

        lastActionPayload = .automationDiagnostics(
            title: "Automazioni nell'app",
            items: diagnosticItems
        )

        return lines.joined(separator: "\n")
    }

    private func automationTriggerSummary(_ rule: Rule) -> String {
        switch rule.triggerType {
        case "calendar":
            let time = rule.triggerTime ?? "--:--"
            let weekdays = rule.weekdaysArray
            guard !weekdays.isEmpty else { return "ogni giorno alle \(time)" }
            let symbols = Calendar.current.shortWeekdaySymbols
            let days = weekdays.sorted().compactMap { day -> String? in
                guard day >= 1, day <= symbols.count else { return nil }
                return symbols[day - 1]
            }.joined(separator: ", ")
            return "\(days) alle \(time)"
        case "characteristic":
            guard let condition = rule.triggerCharacteristicID,
                  let threshold = rule.triggerThreshold else {
                return "soglia sensore"
            }
            let parts = condition.split(separator: "|").map(String.init)
            let sensorRaw = parts.first ?? ""
            let sensorName = SensorServiceType(rawValue: sensorRaw)?.displayName ?? sensorRaw
            let room = parts.count > 1 ? " (\(parts[1]))" : ""
            let direction = parts.count > 2 ? parts[2] : "below"
            let symbol = direction == "above" ? ">" : "<"
            return "\(sensorName)\(room) \(symbol) \(String(format: "%.1f", threshold))"
        default:
            return "manuale/in-app"
        }
    }

    private func automationActionSummary(_ rule: Rule) -> String {
        switch rule.actionType {
        case "on": return "accendi"
        case "off": return "spegni"
        case "dim":
            return "luminosità \(Int((rule.actionValue ?? 0.3) * 100))%"
        case "setSpeed":
            return "velocità \(Int((rule.actionValue ?? 0.5) * 100))%"
        case "setTemp":
            return "temperatura \(Int(rule.actionValue ?? 22.0))°C"
        case "setMode": return "modalità"
        case "open": return "apri"
        case "close": return "chiudi"
        default: return rule.actionType
        }
    }

    // MARK: - controlAccessory (Phase 2 — write, reversible only)

    private func controlAccessory(input: [String: Any]) async -> String {
        guard let action = input["action"] as? String else {
            return "Parametro mancante: action."
        }

        // Target: accessoryID esplicito OPPURE room+type (riferimento)
        var targets: [HMAccessory] = []
        if let idStr = input["accessoryID"] as? String,
           let uuid = UUID(uuidString: idStr),
           let acc = homeKit.allAccessories.first(where: { $0.uniqueIdentifier == uuid }) {
            targets = [acc]
        } else {
            targets = resolveTargets(room: input["room"] as? String,
                                     type: input["type"] as? String)
        }

        guard !targets.isEmpty else {
            // niente "UUID" qui: istruzione interna, non domanda all'utente
            return "Nessun accessorio corrispondente. Richiama listAccessories internamente e riprova; non chiedere identificatori all'utente."
        }

        // Carve-out sicurezza
        targets = targets.filter { !isSecurityAccessory($0) }
        guard !targets.isEmpty else {
            return "⛔ Serrature, allarmi e portoni non si comandano via chat."
        }

        // Parametrico su >1 target → disambigua, non agire alla cieca
        let parametric: Set<String> = ["dim", "setTemp", "setSpeed", "setMode"]
        if parametric.contains(action) && targets.count > 1 {
            let choices = targets.map { AccessoryChoice(id: $0.uniqueIdentifier.uuidString, name: $0.name) }
            lastActionPayload = .choose(accessories: choices, action: action,
                                        value: input["value"] as? Double,
                                        promptText: "Quale vuoi regolare?")
            return "Più accessori compatibili — presentata disambiguazione."
        }

        guard let home = homeKit.currentHome else { return "Casa HomeKit non disponibile." }
        let value = input["value"] as? Double

        // on/off di gruppo (o singolo) → esegui su TUTTI
        var done: [String] = [], failed: [String] = []
        var singleUndo: AgentActionPayload?
        for acc in targets {
            let undo = captureUndoPayload(for: acc, action: action)
            let na = AINextAction(label: action, actionType: "executeNow",
                                  accessoryID: acc.uniqueIdentifier.uuidString,
                                  accessoryActionType: action, accessoryValue: value)
            if await executor.execute(na, in: home) { done.append(acc.name); singleUndo = undo }
            else { failed.append(acc.name) }
        }
        lastActionPayload = (done.count == 1) ? singleUndo : nil   // undo multi-target = §16.3, dopo

        if failed.isEmpty { return "✅ \(action) eseguito su: \(done.joined(separator: ", "))." }
        if done.isEmpty   { return "❌ Azione fallita su: \(failed.joined(separator: ", "))." }
        return "Parziale: ok \(done.joined(separator: ", ")); non risponde \(failed.joined(separator: ", "))."
    }

    // MARK: - proposeAction (Phase 2 — structured button proposal)

    private func proposeAction(input: [String: Any]) -> String {
        guard let accessoryIDStr = input["accessoryID"] as? String,
              let action = input["action"] as? String,
              let label = input["label"] as? String else {
            return "Parametri mancanti: accessoryID, action, label sono obbligatori."
        }

        guard let uuid = UUID(uuidString: accessoryIDStr),
              let accessory = homeKit.allAccessories.first(where: { $0.uniqueIdentifier == uuid }) else {
            return "Accessorio non trovato con ID '\(accessoryIDStr)'. Usa listAccessories per ottenere gli UUID corretti."
        }
        guard supportsAction(action, accessory: accessory) else {
            return "Azione '\(action)' non consentita o non supportata per '\(accessory.name)'."
        }

        let value = input["value"] as? Double

        lastActionPayload = .executeNow(accessoryID: accessoryIDStr, action: action,
                                        value: value, label: label)
        return "Proposta registrata: il bottone '\(label)' sarà mostrato all'utente."
    }

    // MARK: - chooseAccessory (Phase 3 — disambiguation pills)

    private func chooseAccessory(input: [String: Any]) -> String {
        guard let accessoriesRaw = input["accessories"] as? [[String: Any]],
              let action         = input["action"]      as? String,
              let promptText     = input["promptText"]  as? String else {
            return "Parametri mancanti: accessories, action, promptText sono obbligatori."
        }

        let choices: [AccessoryChoice] = accessoriesRaw.compactMap { dict in
            guard let id   = dict["id"]   as? String,
                  let name = dict["name"] as? String else { return nil }
            return AccessoryChoice(id: id, name: name)
        }
        guard !choices.isEmpty else {
            return "Nessun accessorio valido passato a chooseAccessory."
        }

        let value = input["value"] as? Double
        let safeChoices = choices.filter { choice in
            guard let uuid = UUID(uuidString: choice.id),
                  let accessory = homeKit.allAccessories.first(where: { $0.uniqueIdentifier == uuid }) else {
                return false
            }
            return supportsAction(action, accessory: accessory)
        }
        guard !safeChoices.isEmpty else {
            return "Nessun accessorio selezionabile supporta in sicurezza l'azione '\(action)'."
        }

        lastActionPayload = .choose(accessories: safeChoices, action: action,
                                    value: value, promptText: promptText)
        return "Disambiguazione presentata all'utente: \(safeChoices.map(\.name).joined(separator: ", "))."
    }

    // MARK: - proposeOpportunity (Phase 3 — create automation rule from chat)

    private func applyTriggerFallbacks(
        text: String,
        triggerType: inout String,
        scheduleKind: inout String?,
        offsetMinutes: inout Int,
        triggerTime: inout String?,
        sensorType: inout String?,
        sensorRoom: inout String?,
        sensorAccessoryName: inout String?,
        sensorThreshold: inout Double?,
        sensorDirection: inout String?,
        presenceKind: inout String?,
        presenceUserScope: inout String?
    ) {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if normalized.contains("esco di casa") || normalized.contains("quando esco") || normalized.contains("leave home") || normalized.contains("leaves home") {
            triggerType = "presence"
            presenceKind = "everyExit"
            presenceUserScope = "currentUser"
        } else if normalized.contains("arrivo a casa") || normalized.contains("quando arrivo") || normalized.contains("arrive home") || normalized.contains("arrives home") {
            triggerType = "presence"
            presenceKind = "everyEntry"
            presenceUserScope = "currentUser"
        } else if normalized.contains("tramonto") || normalized.contains("sunset") {
            triggerType = "calendar"
            scheduleKind = "sunset"
            offsetMinutes = inferredEventOffsetMinutes(from: normalized) ?? offsetMinutes
        } else if normalized.contains("alba") || normalized.contains("sunrise") {
            triggerType = "calendar"
            scheduleKind = "sunrise"
            offsetMinutes = inferredEventOffsetMinutes(from: normalized) ?? offsetMinutes
        } else if normalized.contains("ogni") || normalized.contains(" alle ") || normalized.contains(" al mattino") || normalized.contains(" la mattina") {
            if triggerType == "inApp" {
                triggerType = "calendar"
            }
            if triggerTime == nil, normalized.contains("mattin") {
                triggerTime = "08:00"
            }
        }

        let mentionsSensorTrigger = normalized.contains("quando")
            || normalized.contains(" se ")
            || normalized.contains("supera")
            || normalized.contains("superiore")
            || normalized.contains("sotto")
            || normalized.contains("inferiore")

        guard mentionsSensorTrigger else { return }

        if triggerType == "inApp" {
            triggerType = "characteristic"
        }

        if sensorType == nil {
            if normalized.contains("pm2.5") || normalized.contains("pm 2.5") || normalized.contains("pm25") {
                sensorType = "pm25"
            } else if normalized.contains("pm10") || normalized.contains("pm 10") {
                sensorType = "pm10"
            } else if normalized.contains("polveri sottili") || normalized.contains("particolato") || normalized.contains("particulate") {
                sensorType = normalized.contains("10") ? "pm10" : "pm25"
            } else if normalized.contains("co2") || normalized.contains("co₂") || normalized.contains("carbon dioxide") || normalized.contains("anidride carbonica") {
                sensorType = "carbonDioxide"
            } else if normalized.contains("temperatura") || normalized.contains("temperature") || normalized.contains("°") {
                sensorType = "temperature"
            } else if normalized.contains("umidita") || normalized.contains("humidity") {
                sensorType = "humidity"
            } else if normalized.contains("porta") || normalized.contains("finestra") || normalized.contains("door") || normalized.contains("window") {
                sensorType = "contact"
            } else if normalized.contains("movimento") || normalized.contains("motion") {
                sensorType = "motion"
            } else if normalized.contains("presenza") || normalized.contains("presence") || normalized.contains("occupancy") {
                sensorType = "occupancy"
            } else if normalized.contains("fumo") || normalized.contains("smoke") {
                sensorType = "smoke"
            } else if normalized.contains("perdita") || normalized.contains("leak") || normalized.contains("acqua") {
                sensorType = "leak"
            }
        }

        if sensorRoom == nil || sensorRoom?.isEmpty == true {
            sensorRoom = inferredRoomName(from: normalized)
        }

        if sensorAccessoryName == nil || sensorAccessoryName?.isEmpty == true {
            sensorAccessoryName = inferredSensorAccessoryName(from: normalized, sensorType: sensorType)
        }

        if sensorThreshold == nil, let type = sensorType, !isBooleanSensorType(type) {
            sensorThreshold = firstThresholdNumber(in: normalized, sensorType: type)
        }

        if sensorDirection == nil {
            if normalized.contains("sotto") || normalized.contains("inferiore") || normalized.contains("below") {
                sensorDirection = "below"
            } else if normalized.contains("chiusa") || normalized.contains("chiuso") || normalized.contains("closed") {
                sensorDirection = "closed"
            } else if normalized.contains("aperta") || normalized.contains("aperto") || normalized.contains("open") {
                sensorDirection = "open"
            } else if normalized.contains("spento") || normalized.contains("inattiv") || normalized.contains("inactive") {
                sensorDirection = "inactive"
            } else {
                sensorDirection = "above"
            }
        }
    }

    private func inferredEventOffsetMinutes(from text: String) -> Int? {
        guard let number = firstNumber(in: text) else { return nil }
        let minutes = Int(number.rounded())
        if text.contains("prima") || text.contains("before") {
            return -minutes
        }
        if text.contains("dopo") || text.contains("after") {
            return minutes
        }
        return nil
    }

    private func firstNumber(in text: String) -> Double? {
        let pattern = #"[-+]?\d+(?:[\.,]\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return Double(text[matchRange].replacingOccurrences(of: ",", with: "."))
    }

    private func firstThresholdNumber(in text: String, sensorType: String) -> Double? {
        var cleaned = text
        switch sensorType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "carbondioxide":
            cleaned = cleaned
                .replacingOccurrences(of: "co2", with: " ")
                .replacingOccurrences(of: "co₂", with: " ")
        case "pm25":
            cleaned = cleaned
                .replacingOccurrences(of: "pm2.5", with: " ")
                .replacingOccurrences(of: "pm 2.5", with: " ")
                .replacingOccurrences(of: "pm25", with: " ")
        case "pm10":
            cleaned = cleaned
                .replacingOccurrences(of: "pm10", with: " ")
                .replacingOccurrences(of: "pm 10", with: " ")
        default:
            break
        }
        return firstNumber(in: cleaned)
    }

    private func normalizedSensorType(_ raw: String) -> String {
        let normalized = raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalized {
        case "co2", "co₂", "carbon dioxide", "anidride carbonica":
            return "carbonDioxide"
        case "voc", "volatile organic compounds", "composti organici volatili":
            return "vocDensity"
        case "pm2.5", "pm 2.5", "pm25", "particolato fine":
            return "pm25"
        case "pm10", "pm 10", "particolato grossolano":
            return "pm10"
        case "lux", "luce", "luminosita", "light":
            return "lightSensor"
        default:
            return raw
        }
    }

    private func inferredRoomName(from text: String) -> String? {
        let rooms = homeKit.currentHome?.rooms.map(\.name) ?? []
        return rooms.first { room in
            text.localizedCaseInsensitiveContains(room)
        }
    }

    private func inferredSensorAccessoryName(from text: String, sensorType: String?) -> String? {
        let normalizedType = sensorType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType == "contact" || normalizedType == "contactsensor" else { return nil }

        if text.contains("finestra") || text.contains("window") {
            return text.contains("mansarda") ? "finestra" : "finestra"
        }
        if text.contains("porta") || text.contains("door") {
            return "porta"
        }
        return nil
    }

    private func isBooleanSensorType(_ sensorType: String) -> Bool {
        [
            "contact", "contactsensor", "door", "doorstate", "window",
            "motion", "motionsensor", "movement", "occupancy", "presence",
            "smoke", "leak", "water"
        ].contains(sensorType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func proposeOpportunity(input: [String: Any]) -> String {
        func doubleFromRaw(_ raw: Any?) -> Double? {
            guard let raw else { return nil }
            if let value = raw as? Double { return value }
            if let value = raw as? Int { return Double(value) }
            if let value = raw as? NSNumber { return value.doubleValue }
            if let value = raw as? String { return Double(value.replacingOccurrences(of: ",", with: ".")) }
            return nil
        }

        guard let label       = input["label"]           as? String,
              let naturalLang = input["naturalLanguage"] as? String else {
            return "Parametri mancanti: label e naturalLanguage sono obbligatori."
        }

        let sceneName      = input["sceneName"] as? String
        let accessoryIDStr = input["accessoryID"] as? String ?? ""
        let action         = input["action"] as? String ?? "scene"
        let rawActions     = input["actions"] as? [[String: Any]] ?? []
        let hasNativeActions = !rawActions.isEmpty
        let parsedActions: [(accessoryID: String, action: String, value: Double?, value2: Double?)]
        if hasNativeActions {
            parsedActions = rawActions.compactMap { item in
                guard let id = item["accessoryID"] as? String,
                      let action = item["action"] as? String else {
                    return nil
                }
                return (id, action, doubleFromRaw(item["value"]), doubleFromRaw(item["value2"]))
            }
            guard parsedActions.count == rawActions.count else {
                return "Parametri non validi: ogni elemento di actions deve includere accessoryID e action."
            }
        } else {
            parsedActions = []
        }

        // Validate: either sceneName, actions[], or accessoryID+action must be provided.
        if let sn = sceneName, !sn.isEmpty {
            guard !hasNativeActions else {
                return "Parametri non validi: usa sceneName oppure actions, non entrambi."
            }
            // Scene-based: no accessory validation needed
        } else if hasNativeActions {
            for item in parsedActions {
                guard UUID(uuidString: item.accessoryID) != nil,
                      let accessory = homeKit.allAccessories.first(where: { $0.uniqueIdentifier.uuidString == item.accessoryID }) else {
                    return "Accessorio non trovato con ID '\(item.accessoryID)'. Usa listAccessories per ottenere gli UUID corretti."
                }
                guard supportsAutomationAction(item.action, accessory: accessory) else {
                    return "Automazione non creata: azione '\(item.action)' non consentita o non supportata per '\(accessory.name)'."
                }
            }
        } else {
            guard !accessoryIDStr.isEmpty, action != "scene" else {
                return "Parametri mancanti: fornisci sceneName, actions oppure accessoryID + action."
            }
            guard UUID(uuidString: accessoryIDStr) != nil,
                  let accessory = homeKit.allAccessories.first(where: { $0.uniqueIdentifier.uuidString == accessoryIDStr }) else {
                return "Accessorio non trovato con ID '\(accessoryIDStr)'. Usa listAccessories per ottenere gli UUID corretti."
            }
            guard supportsAutomationAction(action, accessory: accessory) else {
                return "Automazione non creata: azione '\(action)' non consentita o non supportata per '\(accessory.name)'."
            }
        }

        func stringValue(_ key: String) -> String? {
            guard let raw = input[key] else { return nil }
            if let value = raw as? String { return value }
            if let value = raw as? NSNumber { return value.stringValue }
            return nil
        }

        func doubleValue(_ key: String) -> Double? {
            doubleFromRaw(input[key])
        }

        func intValue(_ key: String) -> Int? {
            guard let raw = input[key] else { return nil }
            if let value = raw as? Int { return value }
            if let value = raw as? Double { return Int(value) }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value) }
            return nil
        }

        var triggerType     = stringValue("triggerType") ?? "inApp"
        var scheduleKind    = stringValue("triggerScheduleKind")
        var offsetMinutes   = intValue("triggerOffsetMinutes") ?? 0
        var triggerTime     = input["triggerTime"] as? String
        let triggerWeekdays = input["triggerWeekdays"] as? String
        var sensorType      = stringValue("triggerSensorType")
        var sensorRoom      = stringValue("triggerSensorRoom")
        var sensorAccessoryName = stringValue("triggerSensorAccessoryName")
        var sensorThreshold = doubleValue("triggerThreshold")
        var sensorDirection = stringValue("triggerDirection")
        var presenceKind    = stringValue("triggerPresenceKind")
        var presenceScope   = stringValue("triggerPresenceUserScope")
        let value           = doubleValue("value")
        let value2          = doubleValue("value2")
        sensorType = sensorType.map(normalizedSensorType)

        applyTriggerFallbacks(
            text: "\(label) \(naturalLang)",
            triggerType: &triggerType,
            scheduleKind: &scheduleKind,
            offsetMinutes: &offsetMinutes,
            triggerTime: &triggerTime,
            sensorType: &sensorType,
            sensorRoom: &sensorRoom,
            sensorAccessoryName: &sensorAccessoryName,
            sensorThreshold: &sensorThreshold,
            sensorDirection: &sensorDirection,
            presenceKind: &presenceKind,
            presenceUserScope: &presenceScope
        )

        // Validazione: calendar senza ora non è schedulabile
        let usesSignificantEvent = ["sunrise", "sunset", "alba", "tramonto"].contains(
            scheduleKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        )
        if triggerType == "calendar", !usesSignificantEvent, (triggerTime?.isEmpty ?? true) {
            return "Per un'automazione a orario serve triggerTime in formato HH:mm. Chiedi all'utente a che ora."
        }
        // Validazione: characteristic senza sensore non è valutabile
        if triggerType == "characteristic" {
            guard let sensorType, !sensorType.isEmpty, let sensorRoom, !sensorRoom.isEmpty else {
                return "Per trigger=characteristic servono almeno triggerSensorType e triggerSensorRoom. Chiama readSensor o getSecurityState prima per confermare il sensore."
            }

            let booleanSensorTypes = [
                "contact", "contactsensor", "door", "doorstate", "window",
                "motion", "motionsensor", "movement", "occupancy", "presence",
                "smoke", "leak", "water"
            ]
            let isBooleanSensor = booleanSensorTypes.contains(sensorType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            if !isBooleanSensor, sensorThreshold == nil {
                return "Per trigger=characteristic su sensori numerici serve triggerThreshold. Chiama readSensor prima per confermare il sensore e leggere le soglie."
            }
        }

        // B2 — intra-session semantic dedup
        let valueKey = value.map { String($0) } ?? ""
        let value2Key = value2.map { String($0) } ?? ""
        let thresholdKey = sensorThreshold.map { String($0) } ?? ""
        let presenceKindKey = presenceKind ?? ""
        let presenceScopeKey = presenceScope ?? ""
        let semanticKey: String
        if let sn = sceneName, !sn.isEmpty {
            semanticKey = [
                "scene",
                sn.lowercased(),
                triggerType,
                triggerTime ?? "",
                triggerWeekdays ?? "",
                sensorType ?? "",
                sensorRoom ?? "",
                sensorAccessoryName ?? "",
                thresholdKey,
                sensorDirection ?? "",
                scheduleKind ?? "",
                String(offsetMinutes),
                presenceKindKey,
                presenceScopeKey
            ].joined(separator: ":")
        } else if hasNativeActions {
            let actionKey = parsedActions
                .map { item -> String in
                    let value = item.value.map { String($0) } ?? ""
                    let value2 = item.value2.map { String($0) } ?? ""
                    return "\(item.accessoryID):\(item.action):\(value):\(value2)"
                }
                .joined(separator: "|")
            semanticKey = [
                actionKey,
                triggerType,
                triggerTime ?? "",
                triggerWeekdays ?? "",
                sensorType ?? "",
                sensorRoom ?? "",
                sensorAccessoryName ?? "",
                thresholdKey,
                sensorDirection ?? "",
                scheduleKind ?? "",
                String(offsetMinutes),
                presenceKindKey,
                presenceScopeKey
            ].joined(separator: ":")
        } else {
            semanticKey = [
                accessoryIDStr,
                action,
                valueKey,
                value2Key,
                triggerType,
                triggerTime ?? "",
                triggerWeekdays ?? "",
                sensorType ?? "",
                sensorRoom ?? "",
                sensorAccessoryName ?? "",
                thresholdKey,
                sensorDirection ?? "",
                scheduleKind ?? "",
                String(offsetMinutes),
                presenceKindKey,
                presenceScopeKey
            ].joined(separator: ":")
        }
        if proposedSemanticKeys.contains(semanticKey) {
            return "Opportunità per questa azione già proposta in questa sessione."
        }
        proposedSemanticKeys.insert(semanticKey)
        scenesService.refresh()
        let capabilities = homeKit.currentHome.map {
            AutomationCapabilityCatalog.capabilities(in: $0)
        } ?? []

        let primaryAccessoryID = hasNativeActions ? (parsedActions.first?.accessoryID ?? accessoryIDStr) : accessoryIDStr
        let primaryAction = hasNativeActions ? (parsedActions.first?.action ?? action) : action
        let primaryValue = hasNativeActions ? parsedActions.first?.value ?? value : value
        let primaryValue2 = hasNativeActions ? parsedActions.first?.value2 ?? value2 : value2

        var proposal = AutomationProposalMapper.chatbotProposal(
            label: label,
            naturalLanguage: naturalLang,
            accessoryID: primaryAccessoryID,
            action: primaryAction,
            value: primaryValue,
            value2: primaryValue2,
            triggerType: triggerType,
            triggerTime: triggerTime,
            triggerWeekdaysRaw: triggerWeekdays,
            triggerSensorType: sensorType,
            triggerSensorRoom: sensorRoom,
            triggerSensorAccessoryName: sensorAccessoryName,
            triggerThreshold: sensorThreshold,
            triggerDirection: sensorDirection,
            sceneName: sceneName,
            triggerScheduleKind: scheduleKind,
            triggerOffsetMinutes: offsetMinutes,
            triggerPresenceKind: presenceKind,
            triggerPresenceUserScope: presenceScope,
            semanticKey: semanticKey,
            capabilities: capabilities,
            scenes: scenesService.scenes
        )
        if hasNativeActions {
            let nativeActions = parsedActions.compactMap {
                AutomationProposalMapper.chatbotAction(
                    accessoryID: $0.accessoryID,
                    action: $0.action,
                    value: $0.value,
                    value2: $0.value2
                )
            }
            guard nativeActions.count == parsedActions.count else {
                return "Proposta non creata: una o più azioni non sono convertibili nel nuovo Automation Builder."
            }
            proposal.actions = nativeActions
        }

        lastActionPayload = .reviewAutomation(proposal: proposal)
        return "Proposta '\(label)' creata. Il bottone aprirà il nuovo Automation Builder."
    }

    // MARK: - getOutdoor

    private func getOutdoor(input: [String: Any]) -> String {
        guard let w = weatherKit.currentWeather else {
            let lat = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey)
            let lon = UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey)
            if lat == 0 && lon == 0 {
                return "Posizione casa non configurata. Vai in Impostazioni → Posizione Casa."
            }
            return "Dati meteo non ancora disponibili. Riprova tra qualche istante."
        }

        var lines: [String] = [
            "Temperatura esterna: \(String(format: "%.1f", w.outdoorTemperature))°C",
            "Percepita: \(String(format: "%.1f", w.apparentTemperature))°C",
            "Umidità: \(Int(w.outdoorHumidity * 100))%",
            "Condizioni: \(w.condition)",
            "Vento: \(String(format: "%.0f", w.windSpeedKmh)) km/h",
            "UV: \(w.uvIndex)"
        ]

        if let tmr = weatherKit.tomorrowForecast {
            lines.append("Domani: \(String(format: "%.0f", tmr.minTemperature))–\(String(format: "%.0f", tmr.maxTemperature))°C, \(tmr.condition), pioggia \(Int(tmr.precipitationProbability * 100))%")
        }

        return lines.joined(separator: "\n")
    }
    
    // MARK: - createScene

    private func createScene(input: [String: Any]) async -> String {
        guard let name = input["name"] as? String, !name.isEmpty,
              let actionsRaw = input["actions"] as? [[String: Any]], !actionsRaw.isEmpty else {
            return "Parametri mancanti: name e actions sono obbligatori."
        }
        guard let home = homeKit.currentHome else {
            return "Casa HomeKit non disponibile."
        }

        let onUUID         = "00000025-0000-1000-8000-0026bb765291"
        let activeUUID     = "000000b0-0000-1000-8000-0026bb765291"
        let brightnessUUID = "00000008-0000-1000-8000-0026bb765291"
        let colorTempUUID  = "000000ce-0000-1000-8000-0026bb765291"
        let positionUUID   = "0000007c-0000-1000-8000-0026bb765291"
        let targetTempUUID = "00000035-0000-1000-8000-0026bb765291"
        let rotSpeedUUID   = "00000029-0000-1000-8000-0026bb765291"

        struct PendingAction {
            let characteristic: HMCharacteristic
            let value: NSCopying & NSObjectProtocol
        }

        var pending: [PendingAction] = []
        var skipped: [String] = []

        for actionDict in actionsRaw {
            guard let idStr  = actionDict["accessoryID"] as? String,
                  let action = actionDict["action"] as? String else { continue }

            guard let uuid      = UUID(uuidString: idStr),
                  let accessory = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) else {
                skipped.append(idStr)
                continue
            }
            guard supportsAction(action, accessory: accessory) else {
                skipped.append(accessory.name)
                continue
            }

            let allChars = accessory.services.flatMap(\.characteristics)
            func ch(_ u: String) -> HMCharacteristic? {
                allChars.first { $0.characteristicType.lowercased() == u }
            }

            let value = actionDict["value"] as? Double

            switch action {
            case "on":
                if let c = ch(onUUID) ?? ch(activeUUID) {
                    pending.append(PendingAction(characteristic: c, value: 1 as NSNumber))
                }
                if let v = value, let b = ch(brightnessUUID) {
                    pending.append(PendingAction(characteristic: b, value: Int(v * 100) as NSNumber))
                }
            case "off":
                if let c = ch(onUUID) ?? ch(activeUUID) {
                    pending.append(PendingAction(characteristic: c, value: 0 as NSNumber))
                }
            case "dim":
                if let c = ch(onUUID) {
                    pending.append(PendingAction(characteristic: c, value: 1 as NSNumber))
                }
                if let b = ch(brightnessUUID) {
                    pending.append(PendingAction(characteristic: b, value: Int((value ?? 0.5) * 100) as NSNumber))
                }
            case "setColorTemp":
                if let c = ch(onUUID) ?? ch(activeUUID) {
                    pending.append(PendingAction(characteristic: c, value: 1 as NSNumber))
                }
                if let ct = ch(colorTempUUID), let kelvin = value, kelvin > 0 {
                    // HomeKit usa Mired (mirek) = 1.000.000 / Kelvin
                    let mired = max(50, min(1000, Int(1_000_000 / kelvin)))
                    pending.append(PendingAction(characteristic: ct, value: mired as NSNumber))
                }
            case "open":
                if let c = ch(positionUUID) {
                    let rawPosition = WindowCoveringPositionMapper.rawTarget(
                        forActionType: action,
                        accessoryID: accessory.uniqueIdentifier
                    ) ?? 100
                    pending.append(PendingAction(characteristic: c, value: rawPosition as NSNumber))
                }
            case "close":
                if let c = ch(positionUUID) {
                    let rawPosition = WindowCoveringPositionMapper.rawTarget(
                        forActionType: action,
                        accessoryID: accessory.uniqueIdentifier
                    ) ?? 0
                    pending.append(PendingAction(characteristic: c, value: rawPosition as NSNumber))
                }
            case "setTemp":
                if let c = ch(targetTempUUID), let v = value {
                    pending.append(PendingAction(characteristic: c, value: v as NSNumber))
                }
            case "setSpeed":
                if let c = ch(rotSpeedUUID), let v = value {
                    pending.append(PendingAction(characteristic: c, value: Int(v * 100) as NSNumber))
                }
            case "setMode":
                // TargetHeaterCoolerState (AC): 000000b2 — 0=Auto, 1=Heat, 2=Cool
                // TargetHeatingCoolingState (Thermostat/TRV): 00000033 — 0=Off, 1=Heat, 2=Cool, 3=Auto
                // TargetAirPurifierState (Purifier): 000000a8 — 0=Manual, 1=Auto
                // TargetHumidifierDehumidifierState: 000000b4 — 0=Auto, 1=Humidify, 2=Dehumidify
                let hcModeUUID    = "000000b2-0000-1000-8000-0026bb765291"
                let thermoModeUUID = "00000033-0000-1000-8000-0026bb765291"
                let apModeUUID    = "000000a8-0000-1000-8000-0026bb765291"
                let humidifierModeUUID = "000000b4-0000-1000-8000-0026bb765291"
                let intMode = Int(value ?? 0)
                if let modeChar = ch(hcModeUUID) {
                    // AC (HeaterCooler): activate first, then set target mode
                    if let ac = ch(activeUUID) {
                        pending.append(PendingAction(characteristic: ac, value: 1 as NSNumber))
                    }
                    pending.append(PendingAction(characteristic: modeChar, value: intMode as NSNumber))
                } else if let modeChar = ch(thermoModeUUID) {
                    // Thermostat / TRV: on + target heating-cooling state
                    if let on = ch(onUUID) ?? ch(activeUUID) {
                        pending.append(PendingAction(characteristic: on, value: 1 as NSNumber))
                    }
                    pending.append(PendingAction(characteristic: modeChar, value: intMode as NSNumber))
                } else if let apChar = ch(apModeUUID) {
                    // Air purifier: TargetAirPurifierState
                    pending.append(PendingAction(characteristic: apChar, value: intMode as NSNumber))
                } else if let humidifierChar = ch(humidifierModeUUID) {
                    if let active = ch(activeUUID) {
                        pending.append(PendingAction(characteristic: active, value: 1 as NSNumber))
                    }
                    pending.append(PendingAction(characteristic: humidifierChar, value: intMode as NSNumber))
                }
            default:
                break
            }
        }

        guard !pending.isEmpty else {
            return "Nessuna azione valida per la scena: controlla che gli accessori supportino le capabilities richieste."
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            home.addActionSet(withName: name) { actionSet, error in
                guard error == nil, let actionSet else {
                    continuation.resume(returning: "❌ Creazione scena fallita: \(error?.localizedDescription ?? "errore sconosciuto")")
                    return
                }

                func addNext(_ index: Int) {
                    guard index < pending.count else {
                        let skipNote = skipped.isEmpty ? "" : " (\(skipped.count) accessori non trovati ignorati)"
                        continuation.resume(returning: "✅ Scena '\(name)' creata con \(pending.count) azioni\(skipNote). È visibile nella sezione Scene dell'app e in Apple Home.")
                        return
                    }
                    let pa = pending[index]
                    let writeAction = HMCharacteristicWriteAction(characteristic: pa.characteristic,
                                                                  targetValue: pa.value)
                    actionSet.addAction(writeAction) { _ in
                        addNext(index + 1)
                    }
                }
                addNext(0)
            }
        }
    }

    // MARK: - listScenes

    private func listScenes(input: [String: Any]) -> String {
        scenesService.refresh()
        let custom = scenesService.customScenes
        guard !custom.isEmpty else {
            return "Nessuna scena personalizzata trovata in HomeKit. Puoi crearne una con createScene."
        }

        let query = (input["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }?.lowercased()
        let filtered = query.map { q in custom.filter { $0.name.lowercased().contains(q) } } ?? custom

        if filtered.isEmpty {
            let all = custom.map(\.name).joined(separator: ", ")
            return "Nessuna scena corrisponde al filtro '\(query ?? "")'. Scene disponibili: \(all)"
        }

        let lines = filtered.map { scene -> String in
            let summaries = scene.actionSummaries
            guard !summaries.isEmpty else {
                return "• \(scene.name): (nessuna azione configurata)"
            }
            let actions = summaries
                .map { "\($0.accessoryName) (\($0.roomName)): \($0.description)" }
                .joined(separator: "; ")
            return "• \(scene.name): \(actions)"
        }

        return "Scene HomeKit personalizzate (\(filtered.count)):\n" + lines.joined(separator: "\n")
    }

    // MARK: - getLightingStatus

    private func getLightingStatus(input: [String: Any]) -> String {
        return smartLightingEngine.statusSummary
    }

    // MARK: - configureLighting

    private func configureLighting(input: [String: Any]) -> String {
        guard let roomName = input["roomName"] as? String, !roomName.isEmpty else {
            return "Parametro mancante: roomName è obbligatorio."
        }

        let existing = smartLightingEngine.profiles.first {
            $0.roomName.lowercased() == roomName.lowercased()
        }
        var profile = existing ?? LightingProfile(roomName: roomName)

        if let v = input["isEnabled"] as? Bool        { profile.isEnabled = v }
        if let v = input["sceneDawn"] as? String      { profile.sceneDawn       = v.isEmpty ? nil : v }
        if let v = input["sceneMorning"] as? String   { profile.sceneMorning    = v.isEmpty ? nil : v }
        if let v = input["scenePreSunset"] as? String { profile.scenePreSunset  = v.isEmpty ? nil : v }
        if let v = input["sceneSunset"] as? String    { profile.sceneSunset     = v.isEmpty ? nil : v }
        if let v = input["sceneEvening"] as? String   { profile.sceneEvening    = v.isEmpty ? nil : v }
        if let v = input["sceneNight"] as? String     { profile.sceneNight      = v.isEmpty ? nil : v }
        if let v = input["luxBypassThreshold"] as? Double { profile.luxBypassThreshold = v }
        if let v = input["luxSensorRoomName"] as? String { profile.luxSensorRoomName = v.isEmpty ? nil : v }
        if let v = input["luxOffSceneName"] as? String { profile.luxOffSceneName = v.isEmpty ? nil : v }
        if let v = input["nightHour"] as? Int         { profile.nightHour = v }
        if let v = input["sleepHour"] as? Int         { profile.sleepHour = v }
        else if (input["sleepHour"] as? NSNull) != nil { profile.sleepHour = nil }
        if let v = input["wakeHour"] as? Int          { profile.wakeHour = v }
        else if (input["wakeHour"] as? NSNull) != nil { profile.wakeHour = nil }

        smartLightingEngine.addOrUpdateProfile(profile)
        let verb = existing == nil ? "creato" : "aggiornato"
        return "✅ Profilo Smart Lighting per '\(profile.roomName)' \(verb).\n\(profile.summary)"
    }

    /// Risoluzione condivisa per riferimento (riusa la stessa logica di listAccessories).
    private func resolveTargets(room: String?, type: String?) -> [HMAccessory] {
        let roomNeedle = room?.lowercased()
        let candidateRooms = accessoriesVM.rooms.filter { r in
            guard let n = roomNeedle, !n.isEmpty else { return true }
            return r.roomName.lowercased() == n || r.roomName.lowercased().contains(n)
        }
        var accs = candidateRooms.flatMap { $0.accessories }
        if let t = type?.lowercased(), !t.isEmpty {
            accs = accs.filter { accessoryMatchesType($0, t) }
        }
        return accs
    }

    private func accessoryMatchesType(_ acc: HMAccessory, _ type: String) -> Bool {
        let lightbulb  = "00000043-0000-1000-8000-0026bb765291"
        let outlet     = "00000047-0000-1000-8000-0026bb765291"
        let switchSvc  = "00000049-0000-1000-8000-0026bb765291"
        let fanV2      = "000000b7-0000-1000-8000-0026bb765291"
        let fanV1      = "00000040-0000-1000-8000-0026bb765291"
        let cover      = "0000008c-0000-1000-8000-0026bb765291"
        let thermostat = "0000004a-0000-1000-8000-0026bb765291"
        let airPurif   = "000000bb-0000-1000-8000-0026bb765291"
        let humidifier = "000000bd-0000-1000-8000-0026bb765291"
        let services   = Set(acc.services.map { $0.serviceType.lowercased() })
        switch type {
        case "luci", "luce", "light", "lights":          return services.contains(lightbulb)
        case "prese", "presa", "outlet", "outlets":      return services.contains(outlet)
        case "interruttore", "interruttori", "switch", "switches":
                                                          return services.contains(switchSvc)
        case "ventilatore", "ventilatori", "fan", "fans":
                                                          return services.contains(fanV2) || services.contains(fanV1)
        case "tende", "tapparelle", "blind", "blinds", "cover":
                                                          return services.contains(cover)
        case "clima", "climate", "termostato", "termostati", "thermostat", "thermostats":
                                                          return services.contains(thermostat)
        case "purificatore", "purificatori", "airpurifier", "airpurifiers", "air purifier", "air purifiers":
                                                          return services.contains(airPurif)
        case "umidificatore", "umidificatori", "humidifier", "humidifiers", "diffusore", "diffusori", "diffuser", "diffusers":
                                                          return services.contains(humidifier)
        default:                                          return true
        }
    }
}
