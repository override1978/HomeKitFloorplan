import Foundation
import HomeKit
import SwiftData

@MainActor
enum HomeIncoherenceDetector {
    struct Configuration {
        var sensorReadingLimit: Int = 120
        /// Salita minima (trend a 90 min) perché la CO2 sia "in salita". I LIVELLI
        /// assoluti non stanno qui: derivano dalla soglia warning Ambiente dell'utente
        /// (per stanza se configurata) via `co2Bounds(forWarning:)`.
        var co2RisePPM: Double = 180
        var temperatureRiseCelsius: Double = 0.5
        var trendWindow: TimeInterval = 90 * 60
        /// Lux oltre i quali la luce artificiale è considerata superflua.
        /// Alto di proposito: le sole luci artificiali raramente superano i 500 lux,
        /// così il sensore che misura anche il loro contributo non auto-innesca l'incoerenza.
        var daylightLuxThreshold: Double = 500
        /// Fascia diurna in cui valutare l'incoerenza luci+luminosità: fuori da
        /// questa finestra i lux misurati sono prodotti dalle luci stesse.
        var daylightStartHour: Int = 8
        var daylightEndHour: Int = 18
        /// Età massima della lettura lux considerata rappresentativa.
        var luxReadingMaxAge: TimeInterval = 30 * 60
    }

    static func detect(
        modelContainer: ModelContainer,
        homeKitService: HomeKitService?,
        adapters: [UUID: any AccessoryAdapter]? = nil,
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        guard let homeKitService else { return [] }

        // Mappa adapter condivisa da runCycle, o ricostruita per i chiamanti standalone.
        let adapters = adapters ?? AccessoryAdapterFactory.adapterMap(homeKit: homeKitService)

        let policy = OperationalIntelligencePolicy.load()
        var effectiveConfiguration = configuration ?? Configuration()
        if configuration == nil {
            // Soglie regolabili dall'utente (Impostazioni → Intelligence operativa).
            effectiveConfiguration.daylightLuxThreshold = policy.daylightLuxThreshold
            effectiveConfiguration.daylightStartHour = policy.daylightStartHour
            effectiveConfiguration.daylightEndHour = policy.daylightEndHour
            effectiveConfiguration.temperatureRiseCelsius = policy.coolingIneffectiveDeltaCelsius
            effectiveConfiguration.co2RisePPM = policy.co2RiseThresholdPPM
        }
        let configuration = effectiveConfiguration
        let context = modelContainer.mainContext
        let readings = fetchSensorReadings(context: context, limit: configuration.sensorReadingLimit)
            .filter { !policy.isRoomIgnored($0.roomName) }
        // Stanze tecniche escluse da tutti i check di incoerenza.
        let accessories = homeKitService.allAccessories
            .filter { !policy.isRoomIgnored($0.room?.name) }
        let eventOpenContactIDs = activeOpenContactIDs(context: context)
        let liveStates = accessories.map { accessory in
            LiveAccessoryState(
                accessory: accessory,
                adapter: adapters[accessory.uniqueIdentifier]
                    ?? AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKitService),
                zoneName: homeKitService.zoneName(for: accessory),
                eventSaysOpenContact: eventOpenContactIDs.contains(accessory.uniqueIdentifier.uuidString)
            )
        }

        let daylightIncoherences = policy.daylightWasteEnabled
            ? lightsOnWithDaylight(states: liveStates, readings: readings, configuration: configuration)
            : []

        return hvacWindowOpen(states: liveStates, zonesByRoomUUID: floorplanZones(context: context))
            + co2RisingWithoutVentilation(
                states: liveStates,
                readings: readings,
                co2Thresholds: fetchCO2Thresholds(context: context),
                configuration: configuration
            )
            + coolingWhileTemperatureRises(states: liveStates, readings: readings, configuration: configuration)
            + daylightIncoherences
    }

    private static func fetchCO2Thresholds(context: ModelContext) -> [SensorAlertThreshold] {
        let co2Raw = SensorServiceType.carbonDioxide.rawValue
        let descriptor = FetchDescriptor<SensorAlertThreshold>(
            predicate: #Predicate { $0.serviceTypeRaw == co2Raw && $0.isEnabled }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Livelli assoluti CO2 derivati dalla soglia warning Ambiente: UNA manopola
    /// (quella che l'utente già conosce) guida allarmi E incoerenze in modo coerente.
    /// Con la warning default (1000 ppm) riproduce esattamente i vecchi valori
    /// hardcoded: minimo 900, escalation high 1200.
    static func co2Bounds(forWarning warning: Double) -> (minimum: Double, high: Double) {
        (minimum: warning * 0.9, high: warning * 1.2)
    }

    /// Soglia warning CO2 per la stanza: preferenza per-stanza → globale → default di tipo.
    private static func co2Warning(
        forRoomKey roomKey: String,
        thresholds: [SensorAlertThreshold]
    ) -> Double {
        if let roomSpecific = thresholds.first(where: {
            $0.roomName.map(normalizedHomeIncoherenceRoomKey) == roomKey
        }) {
            return roomSpecific.warningValue
        }
        if let global = thresholds.first(where: { $0.roomName == nil }) {
            return global.warningValue
        }
        return SensorServiceType.carbonDioxide.defaultWarning
    }

    // MARK: - Luci accese con luce naturale sufficiente

    private static func lightsOnWithDaylight(
        states: [LiveAccessoryState],
        readings: [SensorReading],
        configuration: Configuration
    ) -> [HomeInsight] {
        let hour = Calendar.current.component(.hour, from: Date())
        let luxByRoom = roomLux(states: states, readings: readings, configuration: configuration)
        let lightsOnByRoom = Dictionary(
            grouping: states.filter { $0.isLightOn && $0.roomKey != nil },
            by: { $0.roomKey ?? "home" }
        )

        return lightsOnByRoom.compactMap { roomKey, lights -> HomeInsight? in
            guard let lux = luxByRoom[roomKey],
                  isDaylightWasteCandidate(lux: lux, hour: hour, configuration: configuration),
                  let light = lights.first else {
                return nil
            }

            let roomName = light.roomName ?? roomKey
            return HomeInsight(
                kind: .incoherence,
                category: .lighting,
                signalType: .power,
                severity: .low,
                title: String(localized: "homeInsight.incoherence.lightsDaylight.title", defaultValue: "Lights on in a bright room"),
                message: localizedFormat(
                    key: "homeInsight.incoherence.lightsDaylight.message",
                    defaultValue: "%@: %@ is on while the room already measures %lld lux.",
                    roomName,
                    light.name,
                    Int(lux)
                ),
                whyExplanation: String(localized: "homeInsight.incoherence.lightsDaylight.why", defaultValue: "Measured brightness exceeds the daylight threshold during daytime hours — artificial light is likely unnecessary."),
                recommendation: String(localized: "homeInsight.incoherence.lightsDaylight.recommendation", defaultValue: "Turn off or dim the lights."),
                sourceEntityID: light.id,
                sourceEntityName: light.name,
                roomName: light.roomName,
                confidence: 0.7,
                score: HomeInsightScore(relevance: 0.7, confidence: 0.7, urgency: 0.35, actionability: 0.9, novelty: 0.55),
                dedupeKey: "incoherence|lightsOnDaylight|\(roomKey)",
                suggestedActionJSON: encodedTurnOffAction(
                    accessoryID: light.id,
                    accessoryName: light.name,
                    label: String(localized: "homeInsight.incoherence.action.turnOffLight", defaultValue: "Turn off the light")
                ),
                sourceRecordType: String(describing: HomeIncoherenceDetector.self),
                sourceRecordID: light.id,
                syncPolicy: .localOnly
            )
        }
    }

    /// Vero se la coppia (lux, ora) giustifica l'incoerenza "luce artificiale superflua".
    /// Estratta pura per i test: la finestra oraria evita l'auto-innesco serale,
    /// quando i lux misurati provengono dalle luci stesse.
    static func isDaylightWasteCandidate(lux: Double, hour: Int, configuration: Configuration = Configuration()) -> Bool {
        guard hour >= configuration.daylightStartHour && hour < configuration.daylightEndHour else { return false }
        return lux >= configuration.daylightLuxThreshold
    }

    /// Lux per stanza: preferisce il valore live del sensore, con fallback
    /// sulla lettura persistita più recente entro `luxReadingMaxAge`.
    private static func roomLux(
        states: [LiveAccessoryState],
        readings: [SensorReading],
        configuration: Configuration
    ) -> [String: Double] {
        var luxByRoom: [String: Double] = [:]

        let cutoff = Date().addingTimeInterval(-configuration.luxReadingMaxAge)
        let recentLux = readings
            .filter { $0.serviceTypeRaw == SensorServiceType.lightSensor.rawValue && $0.timestamp >= cutoff }
            .sorted { $0.timestamp > $1.timestamp }
        for reading in recentLux {
            let key = normalizedRoomKey(reading.roomName)
            if luxByRoom[key] == nil { luxByRoom[key] = reading.value }
        }

        for state in states {
            guard let roomKey = state.roomKey, let lux = state.lightLevelLux else { continue }
            luxByRoom[roomKey] = lux
        }

        return luxByRoom
    }

    /// Mappa stanza → planimetrie che la contengono (via Floorplan.linkedRooms).
    /// È la nozione di "zona" usata per limitare le incoerenze cross-stanza:
    /// un clima al piano terra non deve accoppiarsi con una finestra in mansarda.
    private static func floorplanZones(context: ModelContext) -> [UUID: Set<UUID>] {
        let floorplans = (try? context.fetch(FetchDescriptor<Floorplan>())) ?? []
        var zones: [UUID: Set<UUID>] = [:]
        for floorplan in floorplans {
            for room in floorplan.linkedRooms {
                zones[room.hmRoomUUID, default: []].insert(floorplan.id)
            }
        }
        return zones
    }

    private static func fetchSensorReadings(context: ModelContext, limit: Int) -> [SensorReading] {
        var descriptor = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Contatti attualmente aperti secondo lo storico eventi. Integra la lettura live:
    /// con cache HomeKit fredda (avvio/BGTask) `contactDetected` è nil e da solo
    /// farebbe risultare tutto chiuso.
    private static func activeOpenContactIDs(context: ModelContext) -> Set<String> {
        var descriptor = FetchDescriptor<AccessoryEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 300
        let events = (try? context.fetch(descriptor)) ?? []
        return Set(
            HomeStateIntervalBuilder.build(from: events)
                .filter { $0.isActive && $0.signalType == .contact && $0.stateRaw == "open" }
                .compactMap(\.entityID)
        )
    }

    private static func hvacWindowOpen(
        states: [LiveAccessoryState],
        zonesByRoomUUID: [UUID: Set<UUID>]
    ) -> [HomeInsight] {
        let openContacts = states.filter(\.isOpenContact)
        let openContactsByRoom = Dictionary(
            grouping: openContacts.filter { $0.roomKey != nil },
            by: { $0.roomKey ?? "home" }
        )
        let activeClimate = states.filter(\.isClimateActive)

        return activeClimate.compactMap { climate -> HomeInsight? in
            // 1) Match nella stessa stanza: massima confidenza, qualsiasi contatto.
            if let roomKey = climate.roomKey,
               let contact = openContactsByRoom[roomKey]?.first {
                return hvacWindowOpenInsight(climate: climate, contact: contact, sameRoomKey: roomKey)
            }

            // 2) Fallback fuori stanza: mai attraverso piani/zone diverse.
            //    La zona viene dalle HMZone se configurate, altrimenti dalle planimetrie
            //    (stanze linkate allo stesso Floorplan = stessa zona).
            if let contact = openContacts.first(where: {
                $0.isWindowLikeContact &&
                $0.roomKey != climate.roomKey &&
                isCrossRoomClimateContactCandidate(
                    climate: climate,
                    contact: $0,
                    zonesByRoomUUID: zonesByRoomUUID
                )
            }) {
                return hvacWindowOpenInsight(climate: climate, contact: contact, sameRoomKey: nil)
            }

            return nil
        }
    }

    private static func isCrossRoomClimateContactCandidate(
        climate: LiveAccessoryState,
        contact: LiveAccessoryState,
        zonesByRoomUUID: [UUID: Set<UUID>]
    ) -> Bool {
        // 1) Zone HomeKit esplicite: vincolano quando entrambe note.
        if let climateZone = climate.zoneKey, let contactZone = contact.zoneKey {
            return climateZone == contactZone
        }

        // 2) Zone da planimetria: le due stanze devono condividere almeno un Floorplan.
        if let climateRoom = climate.roomUUID,
           let contactRoom = contact.roomUUID,
           let climateZones = zonesByRoomUUID[climateRoom],
           let contactZones = zonesByRoomUUID[contactRoom] {
            return !climateZones.isDisjoint(with: contactZones)
        }

        // 3) Nessuna informazione di zona per la coppia: solo un clima senza stanza
        //    (impianto centrale) giustifica ancora il fallback a livello casa.
        //    Con stanze note ma zone ignote meglio tacere che accoppiare piani diversi.
        return climate.roomKey == nil && climate.zoneKey == nil
    }

    private static func hvacWindowOpenInsight(
        climate: LiveAccessoryState,
        contact: LiveAccessoryState,
        sameRoomKey: String?
    ) -> HomeInsight {
        // Titolo specifico per modalità: "termostato su caldo" e "su freddo" sono
        // incoerenze diverse agli occhi dell'utente.
        let title: String
        if climate.isHeating {
            title = String(localized: "homeInsight.incoherence.heatingWindowOpen.title", defaultValue: "Heating on with window open")
        } else if climate.isCooling {
            title = String(localized: "homeInsight.incoherence.coolingWindowOpen.title", defaultValue: "Cooling on with window open")
        } else {
            title = String(localized: "homeInsight.incoherence.hvacWindowOpen.title", defaultValue: "Climate on with window open")
        }

        let roomName = climate.roomName ?? contact.roomName
        let message: String
        let why: String
        let severity: HomeInsightSeverity
        let confidence: Double
        let dedupeKey: String

        if let sameRoomKey {
            message = localizedFormat(
                key: "homeInsight.incoherence.hvacWindowOpen.message",
                defaultValue: "%@: %@ is active while %@ is open.",
                roomName ?? "Home",
                climate.name,
                contact.name
            )
            why = String(localized: "homeInsight.incoherence.hvacWindowOpen.why", defaultValue: "Climate and an open contact are active in the same room.")
            severity = .high
            confidence = 0.9
            dedupeKey = "incoherence|hvacWindowOpen|\(sameRoomKey)"
        } else {
            message = localizedFormat(
                key: "homeInsight.incoherence.hvacWindowOpenHome.message",
                defaultValue: "%@ is active while %@ (%@) is open.",
                climate.name,
                contact.name,
                contact.roomName ?? String(localized: "homeInsight.incoherence.hvacWindowOpenHome.unknownRoom", defaultValue: "another room")
            )
            why = String(localized: "homeInsight.incoherence.hvacWindowOpenHome.why", defaultValue: "Climate is running while a door or window is open elsewhere in the home.")
            severity = .medium
            confidence = 0.75
            dedupeKey = "incoherence|hvacWindowOpenHome|\(climate.id)"
        }

        return HomeInsight(
            kind: .incoherence,
            category: .environment,
            signalType: .active,
            severity: severity,
            title: title,
            message: message,
            whyExplanation: why,
            recommendation: String(localized: "homeInsight.incoherence.hvacWindowOpen.recommendation", defaultValue: "Turn off climate or close the window."),
            sourceEntityID: climate.id,
            sourceEntityName: climate.name,
            relatedEntityID: contact.id,
            relatedEntityName: contact.name,
            relatedRecordType: String(describing: HMAccessory.self),
            relatedRecordID: contact.id,
            roomName: roomName,
            confidence: confidence,
            score: HomeInsightScore(
                relevance: sameRoomKey != nil ? 0.9 : 0.8,
                confidence: confidence,
                urgency: sameRoomKey != nil ? 0.85 : 0.7,
                actionability: 0.85,
                novelty: 0.6
            ),
            dedupeKey: dedupeKey,
            suggestedActionJSON: encodedTurnOffAction(
                accessoryID: climate.id,
                accessoryName: climate.name,
                label: climate.isHeatOnlyClimate
                    ? String(localized: "homeInsight.incoherence.action.turnOffValve", defaultValue: "Turn off the valve")
                    : String(localized: "homeInsight.incoherence.action.turnOffClimate", defaultValue: "Turn off climate")
            ),
            sourceRecordType: String(describing: HomeIncoherenceDetector.self),
            sourceRecordID: climate.id,
            syncPolicy: .localOnly
        )
    }

    /// Azione correttiva one-tap serializzata in `HomeInsight.suggestedActionJSON`
    /// (delega all'encoder condiviso con HomeAnomalyDetector).
    private static func encodedTurnOffAction(
        accessoryID: String,
        accessoryName: String,
        label: String
    ) -> String? {
        InsightCorrectiveAction.turnOffJSON(
            accessoryID: accessoryID,
            accessoryName: accessoryName,
            label: label
        )
    }

    private static func co2RisingWithoutVentilation(
        states: [LiveAccessoryState],
        readings: [SensorReading],
        co2Thresholds: [SensorAlertThreshold],
        configuration: Configuration
    ) -> [HomeInsight] {
        let grouped = Dictionary(grouping: readings.filter { $0.serviceTypeRaw == SensorServiceType.carbonDioxide.rawValue }) {
            normalizedRoomKey($0.roomName)
        }

        return grouped.compactMap { roomKey, values -> HomeInsight? in
            let bounds = co2Bounds(forWarning: co2Warning(forRoomKey: roomKey, thresholds: co2Thresholds))
            guard let trend = trend(values: values, window: configuration.trendWindow),
                  trend.latest >= bounds.minimum,
                  trend.delta >= configuration.co2RisePPM,
                  !hasVentilationEvidence(roomKey: roomKey, states: states) else {
                return nil
            }

            let roomName = values.first?.roomName
            return HomeInsight(
                kind: .incoherence,
                category: .environment,
                signalType: .carbonDioxide,
                severity: trend.latest >= bounds.high ? .high : .medium,
                title: String(localized: "homeInsight.incoherence.co2NoVentilation.title", defaultValue: "CO2 rising without ventilation"),
                message: localizedFormat(
                    key: "homeInsight.incoherence.co2NoVentilation.message",
                    defaultValue: "%@: CO2 is %lld ppm, up %lld ppm recently.",
                    roomName ?? "Home",
                    Int(trend.latest),
                    Int(trend.delta)
                ),
                whyExplanation: String(localized: "homeInsight.incoherence.co2NoVentilation.why", defaultValue: "CO2 is rising and no open window, fan, or purifier is active in the room."),
                recommendation: String(localized: "homeInsight.incoherence.co2NoVentilation.recommendation", defaultValue: "Start air exchange or open a window."),
                sourceEntityID: roomKey,
                sourceEntityName: roomName,
                roomName: roomName,
                confidence: 0.78,
                score: HomeInsightScore(relevance: 0.85, confidence: 0.78, urgency: 0.72, actionability: 0.65, novelty: 0.55),
                dedupeKey: "incoherence|co2NoVentilation|\(roomKey)",
                sourceRecordType: String(describing: HomeIncoherenceDetector.self),
                sourceRecordID: roomKey,
                syncPolicy: .localOnly
            )
        }
    }

    private static func coolingWhileTemperatureRises(
        states: [LiveAccessoryState],
        readings: [SensorReading],
        configuration: Configuration
    ) -> [HomeInsight] {
        states.filter(\.isCooling).compactMap { climate -> HomeInsight? in
            guard let roomKey = climate.roomKey else { return nil }
            let roomReadings = readings.filter {
                $0.serviceTypeRaw == SensorServiceType.temperature.rawValue &&
                normalizedRoomKey($0.roomName) == roomKey
            }
            guard let trend = trend(values: roomReadings, window: configuration.trendWindow),
                  trend.delta >= configuration.temperatureRiseCelsius else {
                return nil
            }

            return HomeInsight(
                kind: .incoherence,
                category: .environment,
                signalType: .temperature,
                severity: .medium,
                title: String(localized: "homeInsight.incoherence.coolingTempRising.title", defaultValue: "Ineffective cooling"),
                message: localizedFormat(
                    key: "homeInsight.incoherence.coolingTempRising.message",
                    defaultValue: "%@: %@ is cooling but temperature rose by %.1f°C.",
                    climate.roomName ?? "Home",
                    climate.name,
                    trend.delta
                ),
                whyExplanation: String(localized: "homeInsight.incoherence.coolingTempRising.why", defaultValue: "Climate is set to cool but the room temperature trend is rising."),
                recommendation: String(localized: "homeInsight.incoherence.coolingTempRising.recommendation", defaultValue: "Check windows, sun exposure, and climate settings."),
                sourceEntityID: climate.id,
                sourceEntityName: climate.name,
                roomName: climate.roomName,
                confidence: 0.72,
                score: HomeInsightScore(relevance: 0.75, confidence: 0.72, urgency: 0.6, actionability: 0.55, novelty: 0.55),
                dedupeKey: "incoherence|coolingButTempRising|\(climate.id)",
                sourceRecordType: String(describing: HomeIncoherenceDetector.self),
                sourceRecordID: climate.id,
                syncPolicy: .localOnly
            )
        }
    }

    private static func hasVentilationEvidence(roomKey: String, states: [LiveAccessoryState]) -> Bool {
        states.contains { state in
            state.roomKey == roomKey && (state.isOpenContact || state.isVentilationActive)
        }
    }

    private static func trend(values: [SensorReading], window: TimeInterval) -> (latest: Double, delta: Double)? {
        let sorted = values.sorted { $0.timestamp > $1.timestamp }
        guard let latest = sorted.first else { return nil }
        let cutoff = latest.timestamp.addingTimeInterval(-window)
        guard let baseline = sorted.last(where: { $0.timestamp >= cutoff }) else { return nil }
        return (latest.value, latest.value - baseline.value)
    }

    private static func normalizedRoomKey(_ value: String?) -> String {
        normalizedHomeIncoherenceRoomKey(value)
    }
}

private struct LiveAccessoryState {
    let id: String
    let name: String
    let roomUUID: UUID?
    let roomName: String?
    let roomKey: String?
    let zoneName: String?
    let zoneKey: String?
    let isClimateActive: Bool
    let isCooling: Bool
    let isHeating: Bool
    /// Valvola termostatica o simile: può solo scaldare o stare spenta.
    /// Attiva = richiesta calore, mai raffrescamento (a differenza di un clima).
    let isHeatOnlyClimate: Bool
    let isOpenContact: Bool
    let isWindowLikeContact: Bool
    let isVentilationActive: Bool
    let isLightOn: Bool
    let lightLevelLux: Double?

    @MainActor
    init(accessory: HMAccessory, adapter: any AccessoryAdapter, zoneName: String?, eventSaysOpenContact: Bool) {
        id = accessory.uniqueIdentifier.uuidString
        name = accessory.name
        roomUUID = accessory.room?.uniqueIdentifier
        let accessoryRoomName = accessory.room?.name
        roomName = accessoryRoomName
        roomKey = accessoryRoomName.map(normalizedHomeIncoherenceRoomKey)
        self.zoneName = zoneName
        zoneKey = zoneName.map(normalizedHomeIncoherenceRoomKey)

        // Le valvole termostatiche (TRV) possono solo scaldare o stare spente:
        // alcuni firmware riportano mode/state incoerenti, quindi il ruolo va
        // dedotto dal nome (stessi token del climateRole nel detector anomalie).
        let heatOnly = ["valvola", "valve", "trv", "termostatica", "thermostatic"].contains {
            "\(accessory.name) \(accessoryRoomName ?? "")"
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
                .contains($0)
        }
        isHeatOnlyClimate = heatOnly

        if let thermostat = adapter as? ThermostatAdapter {
            isClimateActive = thermostat.isOn
            isCooling = !heatOnly && thermostat.isOn && (thermostat.currentMode == .cool || thermostat.heaterCoolerState == 3)
            isHeating = thermostat.isOn && (heatOnly || thermostat.currentMode == .heat || thermostat.heaterCoolerState == 2)
        } else if let thermostat = adapter as? LegacyThermostatAdapter {
            isClimateActive = thermostat.isOn
            isCooling = !heatOnly && thermostat.isOn && (thermostat.currentMode == .cool || thermostat.heaterCoolerState == 3)
            isHeating = thermostat.isOn && (heatOnly || thermostat.currentMode == .heat || thermostat.heaterCoolerState == 2)
        } else {
            isClimateActive = false
            isCooling = false
            isHeating = false
        }

        if let sensor = adapter as? SensorAdapter {
            // Live vince quando disponibile; nil = valore non in cache → usa lo storico eventi.
            isOpenContact = sensor.contactDetected ?? eventSaysOpenContact
        } else {
            isOpenContact = eventSaysOpenContact
        }

        let normalizedName = "\(accessory.name) \(accessoryRoomName ?? "")"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        isWindowLikeContact = ["finestra", "window", "porta", "door", "balcone", "ingresso", "entrance"]
            .contains { normalizedName.contains($0) }

        isVentilationActive = (adapter is FanAdapter || adapter is AirPurifierAdapter) && adapter.isOn

        // Ruolo luce dal categorizer (structure-first, come per gli intervalli operativi).
        switch AccessoryCategorizer.categorize(accessory) {
        case "colorLight", "dimmableLight":
            isLightOn = adapter.isOn
        default:
            isLightOn = false
        }

        lightLevelLux = (adapter as? any EnvironmentReadable)?.environmentLightLevel.map(Double.init)
    }
}

private func normalizedHomeIncoherenceRoomKey(_ value: String?) -> String {
    (value ?? "home")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func localizedFormat(key: String, defaultValue: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: defaultValue, table: nil)
    return String(format: format, locale: .current, arguments: arguments)
}
