import Foundation
import HomeKit
import SwiftData
import Observation

// MARK: - AmbientalAIService

/// Analizza i dati ambientali delle stanze e genera insight AI contestuali.
/// Complementa i warning manuali (basati su soglie) con pattern temporali e
/// anomalie storiche che le soglie fisse non possono rilevare.
///
/// Frequenza: chiamato ogni 15 minuti per stanza (solo se app attiva).
/// Graceful degradation: se AI non configurata, `insights` rimane vuoto senza errori.
@Observable
@MainActor
final class AmbientalAIService {

    // MARK: - State

    /// Insight attivi (non dismessi, non scaduti) per tutte le stanze.
    var insights: [AmbientalAIInsight] = []
    var isAnalyzing: Bool = false
    var lastAnalyzed: Date?

    // MARK: - Private

    private let aiSettings: AISettings
    private let modelContainer: ModelContainer
    private let homeKit: HomeKitService
    /// Intervallo minimo tra analisi per la stessa stanza (15 min).
    private var lastAnalysisByRoom: [String: Date] = [:]
    private let minInterval: TimeInterval = 15 * 60

    // MARK: - Init

    init(aiSettings: AISettings, modelContainer: ModelContainer, homeKit: HomeKitService) {
        self.aiSettings = aiSettings
        self.modelContainer = modelContainer
        self.homeKit = homeKit
    }

    // MARK: - Public API

    /// Analizza tutte le stanze fornite e aggiunge insight per quelle che ne hanno bisogno.
    /// Rispetta l'intervallo minimo di 15 minuti per stanza.
    func analyzeRooms(_ rooms: [RoomEnvironmentData]) async {
        guard aiSettings.isOperational, aiSettings.anomalyDetectionEnabled else { return }

        isAnalyzing = true
        defer { isAnalyzing = false }

        // Rimuovi insight scaduti prima di procedere
        insights = insights.filter { $0.isVisible }

        for room in rooms {
            let now = Date()
            if let last = lastAnalysisByRoom[room.roomName],
               now.timeIntervalSince(last) < minInterval { continue }

            let readings = loadHistory(for: room)
            guard !readings.isEmpty else { continue }

            await analyzeRoom(room, readings: readings)
            lastAnalysisByRoom[room.roomName] = now
        }

        lastAnalyzed = Date()
    }

    /// Dismette un insight specifico.
    func dismiss(_ insight: AmbientalAIInsight) {
        if let idx = insights.firstIndex(where: { $0.id == insight.id }) {
            insights[idx].isDismissed = true
        }
    }

    /// Restituisce gli insight visibili per una stanza specifica.
    func visibleInsights(for roomName: String) -> [AmbientalAIInsight] {
        insights.filter { $0.roomName == roomName && $0.isVisible }
    }

    /// True se la stanza ha almeno un insight AI visibile.
    func hasActiveInsight(for roomName: String) -> Bool {
        insights.contains { $0.roomName == roomName && $0.isVisible }
    }

    // MARK: - Room Analysis

    private func analyzeRoom(_ room: RoomEnvironmentData, readings: [SensorReading]) async {
        let payload = buildPayload(room: room, readings: readings)

        let systemPrompt = buildSystemPrompt()

        do {
            let service = AIService(settings: aiSettings)
            let response = try await service.sendPrompt(
                systemPrompt: systemPrompt,
                userPrompt: payload
            )
            if let insight = parseInsight(response: response, roomName: room.roomName) {
                // Rimuovi eventuale insight precedente per la stessa stanza
                insights.removeAll { $0.roomName == room.roomName }
                insights.append(insight)
            }
        } catch {
            // Graceful degradation: non mostrare errori all'utente
        }
    }

    // MARK: - System Prompt Builder

    private func buildSystemPrompt() -> String {
        let cal = Calendar.current
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let month = cal.component(.month, from: now)

        // Fascia oraria
        let timeOfDay: String
        switch hour {
        case 6..<12:  timeOfDay = "mattina (\(hour):00)"
        case 12..<14: timeOfDay = "mezzogiorno (\(hour):00)"
        case 14..<19: timeOfDay = "pomeriggio (\(hour):00)"
        case 19..<23: timeOfDay = "sera (\(hour):00)"
        default:      timeOfDay = "notte (\(hour):00)"
        }

        // Stagione (emisfero nord)
        let season: String
        switch month {
        case 12, 1, 2: season = "inverno"
        case 3, 4, 5:  season = "primavera"
        case 6, 7, 8:  season = "estate"
        default:        season = "autunno"
        }

        return """
        Sei un assistente domotico integrato in un'app per la casa. \
        Ora: \(timeOfDay), stagione: \(season). \
        Analizza i dati di una stanza e, SE noti qualcosa di insolito rispetto alla storia recente, \
        comunicalo in modo naturale e diretto — come farebbe un amico che conosce bene la casa. \

        TONO DEL MESSAGGIO (fondamentale): \
        - Scrivi UNA sola frase breve in italiano colloquiale, massimo 12 parole. \
        - NON usare termini tecnici: niente "baseline", "normalizzare", "trend storico", "rilevato". \
        - NON includere numeri né confronti espliciti (non scrivere "72% invece della media di 65%"). \
        - NON aggiungere spiegazioni dopo la virgola ("...è rimasta su per tutta la sera" → troppo). \
        - NON spiegare l'azione — ci sono già i pulsanti per quello. \
        - Esempi di tono CORRETTO: \
          "L'umidità in cucina è un po' alta stasera." \
          "Fa ancora un po' caldo in mansarda." \
          "L'aria nel soggiorno è un po' pesante stasera." \
          "CO₂ leggermente alta in camera." \
          "Sul balcone l'umidità è salita parecchio." \
        - Esempi di tono SBAGLIATO (da evitare): \
          "L'umidità è al 72%, superiore alla media storica del 65%." \
          "Fa un po' caldo in mansarda, la temperatura è rimasta alta tutta la sera." \
          "Al balcone l'umidità è salita." \
          "Suggerirei di attivare la ventilazione per normalizzare." \

        ARTICOLI E PREPOSIZIONI con i nomi delle stanze — regola italiana: \
        - Stanze con articolo determinativo femminile: "in cucina", "in camera", "in mansarda", \
          "in lavanderia", "sul balcone", "sul terrazzo", "in bagno". \
        - Stanze con articolo maschile: "nel soggiorno", "nello studio", "nel garage", \
          "nell'ingresso", "nel corridoio". \
        - Se non sei sicuro → usa "nella stanza [nome]" come fallback sicuro. \

        NON ripetere warning già coperti dalle soglie manuali (thresholds) nel payload. \
        Se tutto è nella norma → hasInsight=false. Sii selettivo: meglio nessun insight che uno banale. \

        AZIONI — due tipi possibili: \

        1. TIPO "suggest" — controlla un accessorio HomeKit: \
           Usa SOLO accessori presenti in "controllableAccessories". \
           - NON suggerire luci, cappe aspiranti, o accessori non ambientali. \
           - umidità alta → purificatore (setMode Auto) o deumidificatore. \
           - temperatura alta in estate → climatizzatore cool (setMode=2) o ventilatore. \
           - temperatura bassa in inverno → climatizzatore heat (setMode=1) o valvola. \
           - qualità aria bassa / CO2 alta → purificatore Auto. \
           - Valvole (category=valve): solo in inverno. \
           - Di sera/notte non suggerire apertura tende o veneziane. \
           - Se l'accessorio è già attivo (currentState) → non suggerirlo. \

        2. TIPO "tip" — consiglio manuale fisico, SENZA accessorio: \
           Usalo quando non c'è un accessorio adatto MA c'è un'azione manuale utile. \
           Esempi: "Apri la finestra", "Arieggia la stanza", "Abbassa la tapparella", \
           "Apri un po' la finestra", "Fai girare un po' d'aria". \
           Per i tip: accessoryID, accessoryActionType e accessoryValue devono essere omessi (null). \

        Puoi combinare tip e suggest nella stessa nextActions (es. un suggest + un tip come alternativa). \
        Se non esiste né un accessorio pertinente né un tip utile → nextActions: []. \

        Rispondi SOLO con JSON valido (nessun testo, nessun markdown):
        {"hasInsight":true,"message":"una frase breve colloquiale","severity":"info"|"warning"|"anomaly",\
        "nextActions":[\
          {"label":"max 22 char","actionType":"suggest","accessoryID":"UUID reale",\
           "accessoryActionType":"on"|"off"|"setMode"|"setSpeed"|"setTemp","accessoryValue":0.5},\
          {"label":"Apri la finestra","actionType":"tip"}\
        ]}
        accessoryID deve essere un UUID reale da controllableAccessories, mai inventato.
        """
    }

    // MARK: - Payload Builder

    private func buildPayload(room: RoomEnvironmentData, readings: [SensorReading]) -> String {
        var currentValues: [String: Double] = [:]
        for sensor in room.sensors {
            currentValues[sensor.serviceType.rawValue] = sensor.currentValue
        }

        // Suddividi le letture nelle ultime 12 ore in fasce da 4h
        let now = Date()
        let periodRanges: [(String, TimeInterval, TimeInterval)] = [
            ("00:00-04:00", -12 * 3600, -8 * 3600),
            ("04:00-08:00", -8  * 3600, -4 * 3600),
            ("08:00-12:00", -4  * 3600,  0),
        ]

        var periods: [[String: Any]] = []
        for (label, startOffset, endOffset) in periodRanges {
            let start = now.addingTimeInterval(startOffset)
            let end   = now.addingTimeInterval(endOffset)
            let slice = readings.filter { $0.timestamp >= start && $0.timestamp <= end }
            guard !slice.isEmpty else { continue }

            var periodData: [String: Any] = ["range": label]
            // Per ogni tipo di sensore presente nella stanza
            for sensor in room.sensors {
                let typeReadings = slice.filter { $0.serviceTypeRaw == sensor.serviceType.rawValue }
                guard !typeReadings.isEmpty else { continue }
                let values = typeReadings.map(\.value)
                let avg = values.reduce(0, +) / Double(values.count)
                let max = values.max() ?? avg
                let key = sensor.serviceType.rawValue
                periodData["avg\(key.capitalized)"] = Double(round(avg * 10) / 10)
                periodData["max\(key.capitalized)"] = Double(round(max * 10) / 10)
            }
            periods.append(periodData)
        }

        // Baseline 7 giorni (dai dati storici SwiftData)
        var baseline: [String: Any] = [:]
        for sensor in room.sensors {
            let allForType = readings.filter { $0.serviceTypeRaw == sensor.serviceType.rawValue }
            guard allForType.count > 5 else { continue }
            let values = allForType.map(\.value)
            let avg = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + pow($1 - avg, 2) } / Double(values.count)
            baseline["avg\(sensor.serviceType.rawValue.capitalized)"] = Double(round(avg * 10) / 10)
            baseline["stdDev\(sensor.serviceType.rawValue.capitalized)"] = Double(round(sqrt(variance) * 10) / 10)
        }

        // Soglie attuali
        var thresholds: [String: Double] = [:]
        for sensor in room.sensors {
            thresholds["\(sensor.serviceType.rawValue)Warning"] = sensor.warningThreshold
            thresholds["\(sensor.serviceType.rawValue)Critical"] = sensor.dangerThreshold
        }

        // Lista completa degli accessori controllabili nella stanza
        let controllableAccessories = buildControllableAccessories(for: room.roomName)

        // Ora locale per contestualizzare il payload
        let cal2 = Calendar.current
        let nowHour = cal2.component(.hour, from: now)
        let nowMin  = cal2.component(.minute, from: now)
        let localTime = String(format: "%02d:%02d", nowHour, nowMin)

        let payloadDict: [String: Any] = [
            "room":                    room.roomName,
            "localTime":               localTime,
            "currentValues":           currentValues,
            "periods":                 periods,
            "baseline7d":              baseline,
            "thresholds":              thresholds,
            "controllableAccessories": controllableAccessories,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"room\": \"\(room.roomName)\"}" }

        return str
    }

    // MARK: - Controllable Accessories Builder

    /// Costruisce la lista degli accessori controllabili in una stanza per il payload AI.
    /// Esclude i sensori read-only. Include uuid, name, category, capabilities, currentState.
    private func buildControllableAccessories(for roomName: String) -> [[String: Any]] {
        let accessories = homeKit.allAccessories.filter { $0.room?.name == roomName }
        var result: [[String: Any]] = []

        for accessory in accessories {
            let (category, capabilities, currentState) = describeAccessory(accessory)
            guard !capabilities.isEmpty else { continue }  // salta sensori read-only

            var entry: [String: Any] = [
                "uuid":         accessory.uniqueIdentifier.uuidString,
                "name":         accessory.name,
                "category":     category,
                "capabilities": capabilities,
            ]
            if let state = currentState {
                entry["currentState"] = state
            }
            result.append(entry)
        }
        return result
    }

    /// Determina categoria, capabilities e stato corrente di un accessorio.
    /// Restituisce (category, capabilities, currentState?).
    /// capabilities è vuoto per accessori read-only (sensori puri).
    private func describeAccessory(_ accessory: HMAccessory) -> (String, [String: Any], [String: Any]?) {
        let services = accessory.services

        func charValue(_ type: String) -> Any? {
            services.flatMap(\.characteristics).first { $0.characteristicType == type }?.value
        }
        func hasChar(_ type: String) -> Bool {
            services.flatMap(\.characteristics).contains { $0.characteristicType == type }
        }

        // ── Purificatore d'aria ──────────────────────────────────────────
        let purifierServiceType = "000000BB-0000-1000-8000-0026BB765291"
        if services.contains(where: { $0.serviceType == purifierServiceType }) {
            var caps: [String: Any] = [
                "on":  "accendi (Active=1)",
                "off": "spegni (Active=0)",
            ]
            if hasChar(HMCharacteristicTypeRotationSpeed) {
                caps["setSpeed"] = "velocità ventola 0-100"
            }
            // TargetAirPurifierState
            if hasChar("000000A8-0000-1000-8000-0026BB765291") {
                caps["setMode"] = "0=Manuale, 1=Auto"
            }
            var state: [String: Any] = [:]
            if let v = charValue(HMCharacteristicTypeActive) as? Int       { state["active"] = v }
            if let v = charValue(HMCharacteristicTypeRotationSpeed) as? Double { state["speed"] = Int(v) }
            return ("airPurifier", caps, state.isEmpty ? nil : state)
        }

        // ── Termostato HeaterCooler ──────────────────────────────────────
        let heaterCoolerType = "000000BC-0000-1000-8000-0026BB765291"
        let thermostatType   = "0000004A-0000-1000-8000-0026BB765291"
        if services.contains(where: { $0.serviceType == heaterCoolerType || $0.serviceType == thermostatType }) {
            var caps: [String: Any] = [
                "on":  "attiva (Active=1)",
                "off": "spegni (Active=0)",
            ]
            // TargetHeaterCoolerState
            if hasChar("000000B2-0000-1000-8000-0026BB765291") {
                caps["setMode"] = "0=Auto, 1=Caldo, 2=Freddo"
            }
            if hasChar(HMCharacteristicTypeTargetTemperature) {
                caps["setTemp"] = "temperatura target °C"
            }
            var state: [String: Any] = [:]
            if let v = charValue(HMCharacteristicTypeActive) as? Int              { state["active"] = v }
            if let v = charValue(HMCharacteristicTypeCurrentTemperature) as? Double { state["currentTemp"] = v }
            if let v = charValue(HMCharacteristicTypeTargetTemperature) as? Double  { state["targetTemp"] = v }
            if let v = charValue("000000B2-0000-1000-8000-0026BB765291") as? Int   { state["mode"] = v }
            return ("thermostat", caps, state.isEmpty ? nil : state)
        }

        // ── Valvola (TRV) ────────────────────────────────────────────────
        let valveType = "00000081-0000-1000-8000-0026BB765291"
        if services.contains(where: { $0.serviceType == valveType }) {
            let caps: [String: Any] = [
                "on":  "apri valvola (Active=1)",
                "off": "chiudi valvola (Active=0)",
            ]
            var state: [String: Any] = [:]
            if let v = charValue(HMCharacteristicTypeActive) as? Int { state["active"] = v }
            return ("valve", caps, state.isEmpty ? nil : state)
        }

        // ── Luce dimmerabile ─────────────────────────────────────────────
        if hasChar(HMCharacteristicTypeBrightness) {
            let caps: [String: Any] = [
                "on":  "accendi",
                "off": "spegni",
                "dim": "luminosità 0.0-1.0",
            ]
            var state: [String: Any] = [:]
            if let v = charValue(HMCharacteristicTypePowerState) as? Bool { state["on"] = v }
            if let v = charValue(HMCharacteristicTypeBrightness) as? Int  { state["brightness"] = v }
            return ("dimmableLight", caps, state.isEmpty ? nil : state)
        }

        // ── Tenda / Tapparella ───────────────────────────────────────────
        if hasChar(HMCharacteristicTypeCurrentPosition) && hasChar(HMCharacteristicTypeTargetPosition) {
            let caps: [String: Any] = [
                "open":  "apri completamente (100%)",
                "close": "chiudi completamente (0%)",
                "dim":   "posizione parziale 0.0-1.0",
            ]
            var state: [String: Any] = [:]
            if let v = charValue(HMCharacteristicTypeCurrentPosition) as? Int { state["position"] = v }
            return ("windowCovering", caps, state.isEmpty ? nil : state)
        }

        // ── On/Off generico ──────────────────────────────────────────────
        if hasChar(HMCharacteristicTypePowerState) || hasChar(HMCharacteristicTypeActive) {
            // Escludi se tutti i servizi sono read-only
            let allReadOnly = services.flatMap(\.characteristics).allSatisfy {
                $0.properties.contains(HMCharacteristicPropertyReadable) &&
                !$0.properties.contains(HMCharacteristicPropertyWritable)
            }
            guard !allReadOnly else { return ("sensor", [:], nil) }

            let caps: [String: Any] = ["on": "accendi/attiva", "off": "spegni/disattiva"]
            var state: [String: Any] = [:]
            if let v = charValue(HMCharacteristicTypePowerState) as? Bool { state["on"] = v }
            else if let v = charValue(HMCharacteristicTypeActive) as? Int { state["active"] = v }

            // Distingui la categoria tramite HMAccessoryCategory (String costante)
            let catName: String
            switch accessory.category.categoryType {
            case HMAccessoryCategoryTypeFan:            catName = "fan"
            case HMAccessoryCategoryTypeOutlet:         catName = "outlet"
            case HMAccessoryCategoryTypeSwitch:         catName = "switch"
            case HMAccessoryCategoryTypeAirConditioner: catName = "airConditioner"
            default:                                    catName = "onOff"
            }
            return (catName, caps, state.isEmpty ? nil : state)
        }

        // Read-only puro: nessuna capability → verrà escluso dal payload
        return ("sensor", [:], nil)
    }

    // MARK: - Response Parser

    private func parseInsight(response: String, roomName: String) -> AmbientalAIInsight? {
        // Cerca il JSON nella risposta (può esserci testo prima/dopo)
        let cleaned = extractJSON(from: response)
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hasInsight = json["hasInsight"] as? Bool,
              hasInsight,
              let message = json["message"] as? String,
              !message.isEmpty,
              let severityRaw = json["severity"] as? String,
              let severity = InsightSeverity(rawValue: severityRaw)
        else { return nil }

        // Parsing nextActions (opzionali)
        var nextActions: [AINextAction] = []
        if let actionsArray = json["nextActions"] as? [[String: Any]] {
            for item in actionsArray.prefix(3) {
                guard let label = item["label"] as? String,
                      let actionType = item["actionType"] as? String
                else { continue }
                let action = AINextAction(
                    label: label,
                    actionType: actionType,
                    accessoryID: item["accessoryID"] as? String,
                    accessoryActionType: item["accessoryActionType"] as? String,
                    accessoryValue: item["accessoryValue"] as? Double,
                    ruleJSON: item["ruleJSON"] as? String
                )
                nextActions.append(action)
            }
        }

        // Filtro hard-coded: rimuovi azioni "open" su window covering di sera/notte (19:00-07:00)
        let currentHour = Calendar.current.component(.hour, from: Date())
        let isEveningOrNight = currentHour >= 19 || currentHour < 7
        if isEveningOrNight {
            nextActions.removeAll {
                $0.accessoryActionType == "open" || $0.accessoryActionType == "close"
            }
        }

        return AmbientalAIInsight(
            roomName: roomName,
            message: message,
            severity: severity,
            nextActions: nextActions
        )
    }

    private func extractJSON(from string: String) -> String {
        // Trova il primo { e l'ultimo }
        guard let start = string.firstIndex(of: "{"),
              let end = string.lastIndex(of: "}")
        else { return string }
        return String(string[start...end])
    }

    // MARK: - Data Loading

    private func loadHistory(for room: RoomEnvironmentData) -> [SensorReading] {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        let roomName = room.roomName

        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate {
                $0.roomName == roomName && $0.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
