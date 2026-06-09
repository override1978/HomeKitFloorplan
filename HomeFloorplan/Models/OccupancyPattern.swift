import Foundation

// MARK: - OccupancyPattern

/// Per-weekday arrival pattern learned from AccessoryEvent history.
/// Stored as running statistics (mean / variance via Welford-like sums) to allow
/// incremental updates without retaining the full sample set.
struct OccupancyPattern: Codable, Identifiable {

    /// Calendar weekday (1 = Sunday … 7 = Saturday).
    let weekday: Int

    /// Number of observed home-arrival events for this weekday.
    var sampleCount: Int

    /// Running sum of arrival minutes-of-day (0–1439), for mean computation.
    var sumMinuteOfDay: Double

    /// Running sum of squared minutes-of-day, for variance computation.
    var sumSquaredMinutes: Double

    var id: Int { weekday }

    // MARK: - Computed stats

    /// Mean arrival time as minutes-of-day (0–1439).
    var meanMinuteOfDay: Double {
        sampleCount > 0 ? sumMinuteOfDay / Double(sampleCount) : 0
    }

    /// Standard deviation of arrival time in minutes.
    var stdDevMinutes: Double {
        guard sampleCount > 1 else { return 0 }
        let mean = meanMinuteOfDay
        let variance = (sumSquaredMinutes / Double(sampleCount)) - (mean * mean)
        return sqrt(max(0, variance))
    }

    /// Confidence in [0, 1]; saturates at 1.0 after 14 observations.
    var confidence: Double { min(1.0, Double(sampleCount) / 14.0) }

    /// Human-readable mean arrival time (e.g. "18:30").
    var formattedMeanTime: String {
        let h = Int(meanMinuteOfDay) / 60
        let m = Int(meanMinuteOfDay) % 60
        return String(format: "%02d:%02d", h, m)
    }

    // MARK: - Mutation

    mutating func record(minuteOfDay: Double) {
        sampleCount       += 1
        sumMinuteOfDay    += minuteOfDay
        sumSquaredMinutes += minuteOfDay * minuteOfDay
    }
}
