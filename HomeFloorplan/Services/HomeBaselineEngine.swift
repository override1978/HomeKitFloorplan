import Foundation

@MainActor
enum HomeBaselineEngine {
    static func buildMergedBaselines(
        dailySensorSummaries: [DailySensorSummary],
        accessoryUsageSummaries: [AccessoryUsageSummary],
        sensorReadings: [SensorReading],
        accessoryEvents: [AccessoryEvent],
        now: Date = Date(),
        liveWindowDays: Int = 14,
        persistedLimit: Int = 40,
        outputLimit: Int = 80
    ) -> [HomeBaseline] {
        let persistedSensorBaselines = dailySensorSummaries.prefix(persistedLimit).map(HomeBaselineMapper.map)
        let persistedAccessoryBaselines = accessoryUsageSummaries.prefix(persistedLimit).map(HomeBaselineMapper.map)
        let liveBaselines = buildLivePreviewBaselines(
            sensorReadings: sensorReadings,
            accessoryEvents: accessoryEvents,
            now: now,
            windowDays: liveWindowDays
        )

        return Array((persistedSensorBaselines + persistedAccessoryBaselines + liveBaselines).sorted {
            sortDate(for: $0) > sortDate(for: $1)
        }.prefix(outputLimit))
    }

    static func buildLivePreviewBaselines(
        sensorReadings: [SensorReading],
        accessoryEvents: [AccessoryEvent],
        now: Date = Date(),
        windowDays: Int = 14
    ) -> [HomeBaseline] {
        let startDate = Calendar.current.date(byAdding: .day, value: -windowDays, to: now) ?? now
        return buildLiveSensorBaselines(sensorReadings, startDate: startDate, windowDays: windowDays)
            + buildLiveAccessoryBaselines(accessoryEvents, startDate: startDate, windowDays: windowDays)
    }

    private static func buildLiveSensorBaselines(
        _ readings: [SensorReading],
        startDate: Date,
        windowDays: Int
    ) -> [HomeBaseline] {
        let recentReadings = readings.filter { $0.timestamp >= startDate }
        let grouped = Dictionary(grouping: recentReadings) { reading in
            "\(reading.roomName)|\(reading.serviceTypeRaw)"
        }

        return grouped.compactMap { _, readings in
            guard let first = readings.first else { return nil }
            let values = readings.map(\.value)
            let timestamps = readings.map(\.timestamp)
            let count = values.count

            return HomeBaseline(
                roomName: first.roomName,
                signalType: HomeSignalEventMapper.map(first).signalType,
                baselineKind: .range,
                windowRaw: "preview-\(windowDays)d",
                mean: average(values),
                standardDeviation: standardDeviation(values),
                p90: percentile(values, rank: 0.90),
                p95: percentile(values, rank: 0.95),
                sampleCount: count,
                firstSampleAt: timestamps.min(),
                lastSampleAt: timestamps.max(),
                confidence: sensorConfidence(sampleCount: count),
                contextKey: "preview.raw.sensor"
            )
        }
    }

    private static func buildLiveAccessoryBaselines(
        _ events: [AccessoryEvent],
        startDate: Date,
        windowDays: Int
    ) -> [HomeBaseline] {
        let recentEvents = events.filter { $0.timestamp >= startDate }
        let grouped = Dictionary(grouping: recentEvents) { event in
            "\(event.accessoryID.uuidString)|\(event.eventType)"
        }

        return grouped.compactMap { _, events in
            guard let first = events.first else { return nil }
            let timestamps = events.map(\.timestamp)
            let onCount = events.filter(\.state).count

            return HomeBaseline(
                entityID: first.accessoryID.uuidString,
                entityName: first.accessoryName,
                roomName: first.roomName,
                signalType: HomeSignalEventMapper.map(first).signalType,
                baselineKind: .frequency,
                windowRaw: "preview-\(windowDays)d",
                mean: Double(onCount),
                standardDeviation: nil,
                p90: nil,
                p95: nil,
                sampleCount: events.count,
                firstSampleAt: timestamps.min(),
                lastSampleAt: timestamps.max(),
                confidence: accessoryConfidence(sampleCount: events.count),
                contextKey: "preview.raw.accessory"
            )
        }
    }

    private static func sortDate(for baseline: HomeBaseline) -> Date {
        baseline.lastSampleAt ?? baseline.firstSampleAt ?? .distantPast
    }

    private static func sensorConfidence(sampleCount: Int) -> Double {
        min(1.0, Double(sampleCount) / 24.0)
    }

    private static func accessoryConfidence(sampleCount: Int) -> Double {
        min(1.0, Double(sampleCount) / 14.0)
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double? {
        guard let mean = average(values), values.count > 1 else { return nil }
        let variance = values.reduce(0) { partial, value in
            partial + pow(value - mean, 2)
        } / Double(values.count)
        return sqrt(variance)
    }

    private static func percentile(_ values: [Double], rank: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let boundedRank = min(max(rank, 0), 1)
        let index = Int((Double(sorted.count - 1) * boundedRank).rounded())
        return sorted[index]
    }
}
