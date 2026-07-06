import Foundation
import HomeKit
import SwiftData

@MainActor
enum HomeInsightAnomalyPipeline {
    struct Configuration {
        var sensorReadingLimit: Int = 160
        var accessoryEventLimit: Int = 500
        var dailySummaryLimit: Int = 80
        var accessorySummaryLimit: Int = 80
        var minimumSeverity: HomeInsightSeverity = .medium
        var minimumConfidence: Double = 0.65
        /// Gate ridotto per gli insight operativi (luci/prese/contatti da HomeStateInterval):
        /// il detector assegna loro 0.55–0.75, quindi il gate standard 0.65 li eliminerebbe quasi tutti.
        var operationalMinimumConfidence: Double = 0.5
    }

    static func detect(
        modelContainer: ModelContainer,
        homeKitService: HomeKitService? = nil,
        adapters: [UUID: any AccessoryAdapter]? = nil,
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        // Mappa adapter condivisa: passata da runCycle (costruita una volta per ciclo)
        // o ricostruita qui per i chiamanti standalone (debug view, test).
        let adapters = adapters ?? homeKitService.map(AccessoryAdapterFactory.adapterMap) ?? [:]
        let configuration = configuration ?? Configuration()
        let context = modelContainer.mainContext
        let sensorReadings = fetchSensorReadings(context: context, limit: configuration.sensorReadingLimit)
        let accessoryEvents = fetchAccessoryEvents(context: context, limit: configuration.accessoryEventLimit)
        let dailySummaries = fetchDailySensorSummaries(context: context, limit: configuration.dailySummaryLimit)
        let accessorySummaries = fetchAccessoryUsageSummaries(context: context, limit: configuration.accessorySummaryLimit)
        let thresholds = fetchSensorAlertThresholds(context: context)
        let operationalPolicy = OperationalIntelligencePolicy.load()

        let signals = (sensorReadings.map(HomeSignalEventMapper.map) + liveSensorSignals(from: homeKitService, adapters: adapters))
            .filter { !operationalPolicy.isRoomIgnored($0.roomName) }
        let intervals = operationalPolicy.isEnabled
            ? operationalIntervals(
                from: accessoryEvents,
                homeKitService: homeKitService,
                adapters: adapters,
                policy: operationalPolicy
            )
            : []
        let baselines = HomeBaselineEngine.buildMergedBaselines(
            dailySensorSummaries: dailySummaries,
            accessoryUsageSummaries: accessorySummaries,
            sensorReadings: sensorReadings,
            accessoryEvents: accessoryEvents
        )

        return HomeAnomalyDetector.detect(
            signals: signals,
            baselines: baselines,
            thresholds: thresholds,
            stateIntervals: intervals,
            configuration: HomeAnomalyDetector.Configuration(
                minimumOpenContactDuration: operationalPolicy.minimumContactDuration,
                elevatedOpenContactDuration: operationalPolicy.elevatedContactDuration,
                escalatesOpenContactsAtNight: operationalPolicy.escalatesAtNight,
                nightStartHour: operationalPolicy.nightStartHour,
                nightEndHour: operationalPolicy.nightEndHour,
                minimumLongRunningPowerDuration: operationalPolicy.minimumPowerDuration
            )
        )
        .filter { insight in
            guard insight.kind == .anomaly else { return false }
            if isOperationalIntervalInsight(insight) {
                return insight.confidence >= configuration.operationalMinimumConfidence
            }
            return insight.severity >= configuration.minimumSeverity
                && insight.confidence >= configuration.minimumConfidence
        }
    }

    private static func adapter(
        for accessory: HMAccessory,
        in adapters: [UUID: any AccessoryAdapter],
        homeKit: HomeKitService
    ) -> any AccessoryAdapter {
        adapters[accessory.uniqueIdentifier] ?? AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
    }

    private static func fetchSensorReadings(context: ModelContext, limit: Int) -> [SensorReading] {
        var descriptor = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchAccessoryEvents(context: ModelContext, limit: Int) -> [AccessoryEvent] {
        var descriptor = FetchDescriptor<AccessoryEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchDailySensorSummaries(context: ModelContext, limit: Int) -> [DailySensorSummary] {
        var descriptor = FetchDescriptor<DailySensorSummary>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchAccessoryUsageSummaries(context: ModelContext, limit: Int) -> [AccessoryUsageSummary] {
        var descriptor = FetchDescriptor<AccessoryUsageSummary>(
            sortBy: [SortDescriptor(\.weekStartDate, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchSensorAlertThresholds(context: ModelContext) -> [SensorAlertThreshold] {
        let descriptor = FetchDescriptor<SensorAlertThreshold>()
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func liveSensorSignals(
        from homeKitService: HomeKitService?,
        adapters: [UUID: any AccessoryAdapter]
    ) -> [HomeSignalEvent] {
        guard let homeKitService else { return [] }

        return homeKitService.allAccessories.flatMap { accessory -> [HomeSignalEvent] in
            let adapter = adapter(for: accessory, in: adapters, homeKit: homeKitService)
            guard let readable = adapter as? any EnvironmentReadable else { return [] }

            let roomName = accessory.room?.name
            let now = Date()
            return [
                liveSignal(
                    type: .temperature,
                    value: readable.environmentTemperature,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveSignal(
                    type: .humidity,
                    value: readable.environmentHumidity,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveSignal(
                    type: .carbonDioxide,
                    value: readable.environmentCO2,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveSignal(
                    type: .pm25,
                    value: readable.environmentPM25,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveSignal(
                    type: .pm10,
                    value: readable.environmentPM10,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveSignal(
                    type: .vocDensity,
                    value: readable.environmentVOC,
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                ),
                liveSignal(
                    type: .lightSensor,
                    value: readable.environmentLightLevel.map(Double.init),
                    accessory: accessory,
                    roomName: roomName,
                    timestamp: now
                )
            ].compactMap { $0 }
        }
    }

    private static func liveSignal(
        type: SensorServiceType,
        value: Double?,
        accessory: HMAccessory,
        roomName: String?,
        timestamp: Date
    ) -> HomeSignalEvent? {
        guard let value else { return nil }
        return HomeSignalEvent(
            id: UUID(),
            sourceKind: .homeKit,
            entityKind: .sensor,
            entityID: accessory.uniqueIdentifier.uuidString,
            entityName: type.displayName,
            roomName: roomName,
            signalType: signalType(for: type),
            value: .double(value),
            timestamp: timestamp,
            rawSourceType: "HomeKitLiveSensor",
            rawSourceID: "\(accessory.uniqueIdentifier.uuidString)|\(type.rawValue)"
        )
    }

    private static func signalType(for type: SensorServiceType) -> HomeSignalType {
        switch type {
        case .temperature, .outdoorTemperature:
            return .temperature
        case .humidity, .outdoorHumidity:
            return .humidity
        case .airQuality:
            return .airQuality
        case .carbonMonoxide:
            return .carbonMonoxide
        case .carbonDioxide:
            return .carbonDioxide
        case .smoke:
            return .smoke
        case .vocDensity:
            return .vocDensity
        case .pm25:
            return .pm25
        case .pm10:
            return .pm10
        case .lightSensor:
            return .lightLevel
        }
    }

    private static func filterIntervalsAgainstLiveState(
        _ intervals: [HomeStateInterval],
        homeKitService: HomeKitService?,
        adapters: [UUID: any AccessoryAdapter],
        policy: OperationalIntelligencePolicy
    ) -> [HomeStateInterval] {
        guard let homeKitService else {
            // Senza live state la modalità climatica reale non è verificabile: gli eventi
            // termostato sono etichettati "heating" a prescindere dal mode (anche in cooling),
            // quindi gli intervalli "heating" attivi vanno scartati per evitare falsi allarmi estivi.
            return intervals.filter {
                !($0.isActive && $0.stateRaw == "heating") && !policy.isRoomIgnored($0.roomName)
            }
        }

        let liveStateByAccessoryID = Dictionary(
            uniqueKeysWithValues: homeKitService.allAccessories.map { accessory -> (String, LiveIntervalState) in
                let adapter = adapter(for: accessory, in: adapters, homeKit: homeKitService)
                // Accessorio non raggiungibile: la cache HomeKit può dire ancora "acceso"
                // per un dispositivo spento da ore. Lo stato va marcato come non confermabile,
                // non letto dalla cache stantia.
                let state: LiveIntervalState = adapter.isReachable
                    ? liveIntervalState(for: adapter)
                    : .unreachable
                return (accessory.uniqueIdentifier.uuidString, state)
            }
        )

        return intervals.filter { interval in
            if let entityID = interval.entityID,
               policy.ignoredAccessoryIDs.contains(entityID) {
                return false
            }
            if policy.isRoomIgnored(interval.roomName) {
                return false
            }
            guard interval.isActive,
                  let entityID = interval.entityID,
                  let liveState = liveStateByAccessoryID[entityID] else {
                return true
            }
            return liveState.matches(interval)
        }
    }

    private static func operationalIntervals(
        from accessoryEvents: [AccessoryEvent],
        homeKitService: HomeKitService?,
        adapters: [UUID: any AccessoryAdapter],
        policy: OperationalIntelligencePolicy
    ) -> [HomeStateInterval] {
        let eventIntervals = HomeStateIntervalBuilder.build(from: accessoryEvents)
        let liveIntervals = liveOperationalIntervals(
            from: homeKitService,
            adapters: adapters,
            existingIntervals: eventIntervals,
            recentEvents: accessoryEvents,
            policy: policy
        )

        return filterIntervalsAgainstLiveState(
            eventIntervals + liveIntervals,
            homeKitService: homeKitService,
            adapters: adapters,
            policy: policy
        )
    }

    private static func liveOperationalIntervals(
        from homeKitService: HomeKitService?,
        adapters: [UUID: any AccessoryAdapter],
        existingIntervals: [HomeStateInterval],
        recentEvents: [AccessoryEvent],
        policy: OperationalIntelligencePolicy
    ) -> [HomeStateInterval] {
        guard let homeKitService else { return [] }

        let existingActiveKeys = Set(existingIntervals.filter(\.isActive).compactMap(intervalIdentity))
        let now = Date()
        var observedStateKeys = existingActiveKeys

        let liveIntervals = homeKitService.allAccessories.compactMap { accessory -> HomeStateInterval? in
            let entityID = accessory.uniqueIdentifier.uuidString
            guard !policy.ignoredAccessoryIDs.contains(entityID),
                  !policy.isRoomIgnored(accessory.room?.name) else { return nil }

            let adapter = adapter(for: accessory, in: adapters, homeKit: homeKitService)
            guard adapter.isReachable else { return nil }

            let liveState = liveIntervalState(for: adapter)
            guard let draft = liveIntervalDraft(
                accessory: accessory,
                liveState: liveState,
                policy: policy
            ) else { return nil }

            let key = intervalIdentity(entityID: entityID, signalType: draft.signalType, stateRaw: draft.stateRaw)
            observedStateKeys.insert(key)
            guard !existingActiveKeys.contains(key) else { return nil }

            return HomeStateInterval(
                entityID: entityID,
                entityName: accessory.name,
                roomID: accessory.room?.uniqueIdentifier.uuidString,
                roomName: accessory.room?.name,
                signalType: draft.signalType,
                stateRaw: draft.stateRaw,
                deviceRoleRaw: draft.deviceRoleRaw,
                startedAt: inferredLiveStartDate(
                    accessoryID: accessory.uniqueIdentifier,
                    signalType: draft.signalType,
                    stateRaw: draft.stateRaw,
                    recentEvents: recentEvents,
                    now: now
                ),
                endedAt: nil,
                confidence: 0.65
            )
        }

        // Gli stati non più osservati escono dallo store: il timer riparte alla prossima attivazione.
        LiveStateFirstSeenStore.prune(activeKeys: observedStateKeys)
        return liveIntervals
    }

    private struct LiveIntervalDraft {
        let signalType: HomeSignalType
        let stateRaw: String
        var deviceRoleRaw: String? = nil
    }

    private static func liveIntervalDraft(
        accessory: HMAccessory,
        liveState: LiveIntervalState,
        policy: OperationalIntelligencePolicy
    ) -> LiveIntervalDraft? {
        switch liveState {
        case .contact(let isOpen):
            guard isOpen else { return nil }
            return LiveIntervalDraft(
                signalType: .contact,
                stateRaw: "open"
            )
        case .generic(let isOn):
            guard isOn, let role = operationalPowerRole(for: accessory) else { return nil }
            return LiveIntervalDraft(
                signalType: .power,
                stateRaw: "on",
                deviceRoleRaw: role.rawRole
            )
        case .climate, .unknown, .unreachable:
            return nil
        }
    }

    private enum OperationalPowerRole {
        case light
        case outlet
        case generic

        var rawRole: String? {
            switch self {
            case .light: return "light"
            case .outlet: return "outlet"
            case .generic: return nil
            }
        }
    }

    /// Ruolo operativo structure-first: il nome accessorio resta solo come
    /// fallback nel detector.
    private static func operationalPowerRole(for accessory: HMAccessory) -> OperationalPowerRole? {
        // Servizio Lightbulb = luce sempre, anche on/off senza dimmer
        // (il categorizer richiede Brightness e le classificherebbe switch).
        if accessory.services.contains(where: { $0.serviceType == HMServiceTypeLightbulb }) {
            return .light
        }
        if accessory.category.categoryType == HMAccessoryCategoryTypeOutlet {
            return .outlet
        }

        switch AccessoryCategorizer.categorize(accessory) {
        case "colorLight", "dimmableLight":
            return .light
        case "outlet":
            return .outlet
        case "switch", "onOff":
            return .generic
        default:
            return nil
        }
    }

    private static func inferredLiveStartDate(
        accessoryID: UUID,
        signalType: HomeSignalType,
        stateRaw: String,
        recentEvents: [AccessoryEvent],
        now: Date
    ) -> Date {
        if let latestMatchingEvent = recentEvents
            .filter({
                $0.accessoryID == accessoryID &&
                signalTypeForEvent($0) == signalType &&
                eventStartsState($0, signalType: signalType, stateRaw: stateRaw)
            })
            .max(by: { $0.timestamp < $1.timestamp }) {
            return latestMatchingEvent.timestamp
        }

        // Nessun evento di start registrato: ancora la durata alla prima osservazione live persistita,
        // così l'anomalia scatta solo dopo che la durata minima è trascorsa davvero
        // (il vecchio fallback now-minimumDuration la faceva scattare per costruzione al primo ciclo).
        let key = intervalIdentity(entityID: accessoryID.uuidString, signalType: signalType, stateRaw: stateRaw)
        return LiveStateFirstSeenStore.firstSeen(for: key, now: now)
    }

    private static func signalTypeForEvent(_ event: AccessoryEvent) -> HomeSignalType {
        HomeSignalEventMapper.map(event).signalType
    }

    private static func eventStartsState(
        _ event: AccessoryEvent,
        signalType: HomeSignalType,
        stateRaw: String
    ) -> Bool {
        switch signalType {
        case .contact:
            return stateRaw == "open" && !event.state
        case .power, .active:
            return (stateRaw == "on" || stateRaw == "active") && event.state
        default:
            return false
        }
    }

    private static func intervalIdentity(_ interval: HomeStateInterval) -> String? {
        guard let entityID = interval.entityID else { return nil }
        return intervalIdentity(entityID: entityID, signalType: interval.signalType, stateRaw: interval.stateRaw)
    }

    private static func intervalIdentity(
        entityID: String,
        signalType: HomeSignalType,
        stateRaw: String
    ) -> String {
        "\(entityID)|\(signalType.rawValue)|\(stateRaw)"
    }

    private static func liveIntervalState(for adapter: any AccessoryAdapter) -> LiveIntervalState {
        if let sensor = adapter as? SensorAdapter {
            // contactDetected nil = valore non ancora letto (cache HomeKit fredda: avvio/BGTask).
            // "Sconosciuto" NON è "chiuso": non deve invalidare gli intervalli ricostruiti dagli eventi.
            guard let contactDetected = sensor.contactDetected else { return .unknown }
            return .contact(isOpen: contactDetected)
        }

        if let thermostat = adapter as? ThermostatAdapter {
            return .climate(
                isOn: thermostat.isOn,
                currentMode: thermostat.currentMode,
                currentOperation: thermostat.heaterCoolerState
            )
        }

        if let thermostat = adapter as? LegacyThermostatAdapter {
            return .climate(
                isOn: thermostat.isOn,
                currentMode: thermostat.currentMode,
                currentOperation: thermostat.heaterCoolerState
            )
        }

        return .generic(isOn: adapter.isOn)
    }

    private static func isOperationalIntervalInsight(_ insight: HomeInsight) -> Bool {
        guard insight.sourceRecordType == String(describing: HomeStateInterval.self) else {
            return false
        }

        switch insight.category {
        case .lighting, .deviceHealth, .maintenance, .security, .presence:
            return true
        case .environment, .weather, .habits, .automation, .system:
            return false
        }
    }

    private enum LiveIntervalState {
        case generic(isOn: Bool)
        case contact(isOpen: Bool)
        case climate(isOn: Bool, currentMode: HeaterCoolerMode, currentOperation: Int)
        /// Lo stato live non è determinabile (valore non in cache): non contraddice lo storico eventi.
        case unknown
        /// Accessorio non raggiungibile: uno stato "acceso" non è confermabile.
        case unreachable

        func matches(_ interval: HomeStateInterval) -> Bool {
            switch self {
            case .unknown:
                return true
            case .unreachable:
                // Meglio nessuna anomalia che una falsa "presa/valvola accesa" basata
                // su cache stantia. I contatti a batteria dormono tra gli eventi:
                // per loro lo storico resta la fonte di verità.
                switch interval.signalType {
                case .power, .active, .motion:
                    return false
                default:
                    return true
                }
            case .generic(let isOn):
                switch interval.signalType {
                case .power, .active, .motion:
                    // "heating" richiede conferma positiva dallo stato climatico live:
                    // un adapter generico non può darla (il dispositivo potrebbe essere in cooling).
                    if interval.stateRaw == "heating" { return false }
                    return isOn
                case .contact:
                    // L'adapter non espone lo stato contatto: impossibile contraddire l'evento storico.
                    return true
                default:
                    return true
                }
            case .contact(let isOpen):
                guard interval.signalType == .contact else { return true }
                return interval.stateRaw == "open" && isOpen
            case .climate(let isOn, let currentMode, let currentOperation):
                guard isOn else { return false }
                guard interval.stateRaw == "heating" else { return true }
                if currentOperation == 3 || currentMode == .cool {
                    return false
                }
                if currentOperation == 2 || currentMode == .heat {
                    return true
                }
                return false
            }
        }
    }
}

// MARK: - LiveStateFirstSeenStore

/// Persiste la prima osservazione live di uno stato operativo (luce accesa, contatto aperto)
/// per gli accessori senza evento di start nello storico. Serve come ancora temporale:
/// senza, gli intervalli inferiti supererebbero la durata minima per costruzione al primo ciclo.
@MainActor
private enum LiveStateFirstSeenStore {
    private static let storageKey = "homeInsightPipeline.liveStateFirstSeen.v1"

    static func firstSeen(for key: String, now: Date) -> Date {
        var map = load()
        if let existing = map[key] { return existing }
        map[key] = now
        save(map)
        return now
    }

    /// Rimuove le chiavi non più attive: quando lo stato termina, il timer riparte da zero
    /// alla successiva attivazione (comportamento conservativo anche su flapping di reachability).
    static func prune(activeKeys: Set<String>) {
        let map = load()
        let pruned = map.filter { activeKeys.contains($0.key) }
        guard pruned.count != map.count else { return }
        save(pruned)
    }

    private static func load() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let map = try? JSONDecoder().decode([String: Date].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func save(_ map: [String: Date]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
