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
    }

    static func detect(
        modelContainer: ModelContainer,
        homeKitService: HomeKitService? = nil,
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        let configuration = configuration ?? Configuration()
        let context = modelContainer.mainContext
        let sensorReadings = fetchSensorReadings(context: context, limit: configuration.sensorReadingLimit)
        let accessoryEvents = fetchAccessoryEvents(context: context, limit: configuration.accessoryEventLimit)
        let dailySummaries = fetchDailySensorSummaries(context: context, limit: configuration.dailySummaryLimit)
        let accessorySummaries = fetchAccessoryUsageSummaries(context: context, limit: configuration.accessorySummaryLimit)
        let thresholds = fetchSensorAlertThresholds(context: context)

        let signals = sensorReadings.map(HomeSignalEventMapper.map) + liveSensorSignals(from: homeKitService)
        let intervals = filterIntervalsAgainstLiveState(
            HomeStateIntervalBuilder.build(from: accessoryEvents),
            homeKitService: homeKitService
        )
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
            stateIntervals: intervals
        )
        .filter { insight in
            insight.kind == .anomaly
                && insight.severity >= configuration.minimumSeverity
                && insight.confidence >= configuration.minimumConfidence
        }
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

    private static func liveSensorSignals(from homeKitService: HomeKitService?) -> [HomeSignalEvent] {
        guard let homeKitService else { return [] }

        return homeKitService.allAccessories.flatMap { accessory -> [HomeSignalEvent] in
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKitService)
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
        homeKitService: HomeKitService?
    ) -> [HomeStateInterval] {
        guard let homeKitService else { return intervals }

        let liveActiveByAccessoryID = Dictionary(
            uniqueKeysWithValues: homeKitService.allAccessories.map { accessory in
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKitService)
                return (accessory.uniqueIdentifier.uuidString, adapter.isOn)
            }
        )

        return intervals.filter { interval in
            guard interval.isActive,
                  let entityID = interval.entityID,
                  let isLiveActive = liveActiveByAccessoryID[entityID] else {
                return true
            }
            return isLiveActive
        }
    }
}
