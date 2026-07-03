import Foundation
import HomeKit
import SwiftData

@MainActor
enum HomeIncoherenceDetector {
    struct Configuration {
        var sensorReadingLimit: Int = 120
        var co2RisePPM: Double = 180
        var co2MinimumPPM: Double = 900
        var temperatureRiseCelsius: Double = 0.5
        var trendWindow: TimeInterval = 90 * 60
    }

    static func detect(
        modelContainer: ModelContainer,
        homeKitService: HomeKitService?,
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        guard let homeKitService else { return [] }

        let configuration = configuration ?? Configuration()
        let context = modelContainer.mainContext
        let readings = fetchSensorReadings(context: context, limit: configuration.sensorReadingLimit)
        let accessories = homeKitService.allAccessories
        let liveStates = accessories.map { accessory in
            LiveAccessoryState(accessory: accessory, adapter: AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKitService))
        }

        return hvacWindowOpen(states: liveStates)
            + co2RisingWithoutVentilation(states: liveStates, readings: readings, configuration: configuration)
            + coolingWhileTemperatureRises(states: liveStates, readings: readings, configuration: configuration)
    }

    private static func fetchSensorReadings(context: ModelContext, limit: Int) -> [SensorReading] {
        var descriptor = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func hvacWindowOpen(states: [LiveAccessoryState]) -> [HomeInsight] {
        let openContactsByRoom = Dictionary(
            grouping: states.filter { $0.isOpenContact && $0.roomKey != nil },
            by: { $0.roomKey ?? "home" }
        )
        let activeClimate = states.filter(\.isClimateActive)

        return activeClimate.compactMap { climate -> HomeInsight? in
            guard let roomKey = climate.roomKey,
                  let contact = openContactsByRoom[roomKey]?.first else {
                return nil
            }

            let roomName = climate.roomName ?? contact.roomName
            return HomeInsight(
                kind: .incoherence,
                category: .environment,
                severity: .high,
                title: String(localized: "homeInsight.incoherence.hvacWindowOpen.title", defaultValue: "Climate on with window open"),
                message: localizedFormat(
                    key: "homeInsight.incoherence.hvacWindowOpen.message",
                    defaultValue: "%@: %@ is active while %@ is open.",
                    roomName ?? "Home",
                    climate.name,
                    contact.name
                ),
                whyExplanation: String(localized: "homeInsight.incoherence.hvacWindowOpen.why", defaultValue: "Climate and an open contact are active in the same room."),
                recommendation: String(localized: "homeInsight.incoherence.hvacWindowOpen.recommendation", defaultValue: "Turn off climate or close the window."),
                sourceEntityID: climate.id,
                sourceEntityName: climate.name,
                relatedEntityID: contact.id,
                relatedEntityName: contact.name,
                relatedRecordType: String(describing: HMAccessory.self),
                relatedRecordID: contact.id,
                roomName: roomName,
                confidence: 0.9,
                score: HomeInsightScore(relevance: 0.9, confidence: 0.9, urgency: 0.85, actionability: 0.85, novelty: 0.6),
                dedupeKey: "incoherence|hvacWindowOpen|\(roomKey)",
                sourceRecordType: String(describing: HomeIncoherenceDetector.self),
                sourceRecordID: climate.id,
                syncPolicy: .localOnly
            )
        }
    }

    private static func co2RisingWithoutVentilation(
        states: [LiveAccessoryState],
        readings: [SensorReading],
        configuration: Configuration
    ) -> [HomeInsight] {
        let grouped = Dictionary(grouping: readings.filter { $0.serviceTypeRaw == SensorServiceType.carbonDioxide.rawValue }) {
            normalizedRoomKey($0.roomName)
        }

        return grouped.compactMap { roomKey, values -> HomeInsight? in
            guard let trend = trend(values: values, window: configuration.trendWindow),
                  trend.latest >= configuration.co2MinimumPPM,
                  trend.delta >= configuration.co2RisePPM,
                  !hasVentilationEvidence(roomKey: roomKey, states: states) else {
                return nil
            }

            let roomName = values.first?.roomName
            return HomeInsight(
                kind: .incoherence,
                category: .environment,
                severity: trend.latest >= 1200 ? .high : .medium,
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
    let roomName: String?
    let roomKey: String?
    let isClimateActive: Bool
    let isCooling: Bool
    let isOpenContact: Bool
    let isVentilationActive: Bool

    @MainActor
    init(accessory: HMAccessory, adapter: any AccessoryAdapter) {
        id = accessory.uniqueIdentifier.uuidString
        name = accessory.name
        let accessoryRoomName = accessory.room?.name
        roomName = accessoryRoomName
        roomKey = accessoryRoomName.map(normalizedHomeIncoherenceRoomKey)

        if let thermostat = adapter as? ThermostatAdapter {
            isClimateActive = thermostat.isOn
            isCooling = thermostat.isOn && (thermostat.currentMode == .cool || thermostat.heaterCoolerState == 3)
        } else if let thermostat = adapter as? LegacyThermostatAdapter {
            isClimateActive = thermostat.isOn
            isCooling = thermostat.isOn && (thermostat.currentMode == .cool || thermostat.heaterCoolerState == 3)
        } else {
            isClimateActive = false
            isCooling = false
        }

        if let sensor = adapter as? SensorAdapter {
            isOpenContact = sensor.contactDetected == true
        } else {
            isOpenContact = false
        }

        isVentilationActive = (adapter is FanAdapter || adapter is AirPurifierAdapter) && adapter.isOn
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
