import Foundation
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
        configuration: Configuration? = nil
    ) -> [HomeInsight] {
        let configuration = configuration ?? Configuration()
        let context = modelContainer.mainContext
        let sensorReadings = fetchSensorReadings(context: context, limit: configuration.sensorReadingLimit)
        let accessoryEvents = fetchAccessoryEvents(context: context, limit: configuration.accessoryEventLimit)
        let dailySummaries = fetchDailySensorSummaries(context: context, limit: configuration.dailySummaryLimit)
        let accessorySummaries = fetchAccessoryUsageSummaries(context: context, limit: configuration.accessorySummaryLimit)
        let thresholds = fetchSensorAlertThresholds(context: context)

        let signals = sensorReadings.map(HomeSignalEventMapper.map)
        let intervals = HomeStateIntervalBuilder.build(from: accessoryEvents)
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
}
