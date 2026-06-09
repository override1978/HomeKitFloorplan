import Foundation
import SwiftData

// MARK: - BaselineLevel

/// Indicates which data source backed the computed baseline for a room + sensor type.
enum BaselineLevel {
    /// ≥5 days of personal DailySensorSummary records — most accurate.
    case personal
    /// Fewer than 5 days of personal data; seasonal norms used as fallback.
    case seasonal
    /// No baseline could be computed (new user, unknown sensor type).
    case none
}

// MARK: - BaselineResult

struct BaselineResult {
    /// Per-sensor-type baseline statistics.
    let byType: [String: (avg: Double, stdDev: Double)]
    /// Data source used to compute this baseline.
    let level: BaselineLevel

    static let empty = BaselineResult(byType: [:], level: .none)
}

// MARK: - BaselineProvider

/// Computes a 14-day sensor baseline per room from DailySensorSummary aggregates.
///
/// Replaces the inline `computeBaseline` full-scan of raw SensorReading records,
/// reducing SwiftData I/O from O(7d × readings/day) to O(14 summary records).
///
/// Cold-start cascade (22.C):
///   Level 1 — personal: ≥5 days of DailySensorSummary available
///   Level 2 — seasonal: <5 days personal → European continental indoor norms
///   Level 3 — none:     sensor type unknown, no fallback exists
///
/// Results are cached in-memory for 30 minutes to avoid repeated reads across
/// the 15-minute analysis cycles.
final class BaselineProvider {

    // MARK: - Cache

    private struct CacheEntry {
        let result: BaselineResult
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    private static let cacheTTL: TimeInterval        = 30 * 60
    private static let lookbackDays                  = 14
    private static let minDaysForPersonalBaseline    = 5

    // MARK: - Public

    /// Returns the baseline for the given room and sensor types.
    /// Reads from cache if valid; otherwise queries SwiftData.
    func baseline(
        for roomName: String,
        serviceTypes: [String],
        context: ModelContext
    ) -> BaselineResult {
        let now = Date()
        let cacheKey = "\(roomName)|\(serviceTypes.sorted().joined(separator: ","))"
        if let entry = cache[cacheKey], entry.expiresAt > now {
            return entry.result
        }
        let result = compute(roomName: roomName, serviceTypes: serviceTypes, context: context)
        cache[cacheKey] = CacheEntry(result: result, expiresAt: now.addingTimeInterval(Self.cacheTTL))
        return result
    }

    /// Evicts cached entries for a room (call after lifecycle aggregation for that room).
    func invalidateCache(for roomName: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(roomName)|") }
    }

    // MARK: - Private

    private func compute(
        roomName: String,
        serviceTypes: [String],
        context: ModelContext
    ) -> BaselineResult {
        let cutoff = Date().addingTimeInterval(-Double(Self.lookbackDays) * 86400)

        let descriptor = FetchDescriptor<DailySensorSummary>(
            predicate: #Predicate<DailySensorSummary> {
                $0.roomName == roomName && $0.date >= cutoff && !$0.isOutlierDay
            }
        )
        let summaries = (try? context.fetch(descriptor)) ?? []

        var byType: [String: (avg: Double, stdDev: Double)] = [:]
        var maxValidDays = 0

        for typeRaw in serviceTypes {
            let forType = summaries.filter { $0.serviceTypeRaw == typeRaw }
            if forType.count > maxValidDays { maxValidDays = forType.count }
            guard forType.count >= Self.minDaysForPersonalBaseline else { continue }

            // Mean of daily averages (winsorized: outlier days already excluded via predicate).
            let dailyAvgs = forType.map(\.average)
            let mean      = dailyAvgs.reduce(0, +) / Double(dailyAvgs.count)
            let variance  = dailyAvgs.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(dailyAvgs.count)
            byType[typeRaw] = (avg: mean, stdDev: max(sqrt(variance), 0.1))
        }

        if maxValidDays >= Self.minDaysForPersonalBaseline {
            return BaselineResult(byType: byType, level: .personal)
        }

        // Cold-start fallback: supplement missing types with seasonal norms.
        let season = CalendarSeason.current
        for typeRaw in serviceTypes where byType[typeRaw] == nil {
            if let norm = SeasonalBaseline.value(for: typeRaw, season: season) {
                byType[typeRaw] = norm
            }
        }

        return BaselineResult(byType: byType, level: byType.isEmpty ? .none : .seasonal)
    }
}

// MARK: - SeasonalBaseline

/// Typical indoor sensor values by season (European continental climate).
/// Used as a cold-start fallback when personal data is insufficient.
private enum SeasonalBaseline {

    static func value(for typeRaw: String, season: CalendarSeason) -> (avg: Double, stdDev: Double)? {
        switch (typeRaw, season) {
        case ("temperature", .winter): return (avg: 20.0, stdDev: 2.0)
        case ("temperature", .spring): return (avg: 21.5, stdDev: 2.5)
        case ("temperature", .summer): return (avg: 24.5, stdDev: 3.0)
        case ("temperature", .autumn): return (avg: 21.0, stdDev: 2.5)
        case ("humidity",    .winter): return (avg: 40.0, stdDev: 10.0)
        case ("humidity",    .spring): return (avg: 50.0, stdDev: 10.0)
        case ("humidity",    .summer): return (avg: 60.0, stdDev: 12.0)
        case ("humidity",    .autumn): return (avg: 52.0, stdDev: 10.0)
        case ("carbonDioxide", _):     return (avg: 650.0, stdDev: 150.0)
        case ("airQuality",    _):     return (avg: 1.5,   stdDev: 0.5)
        default: return nil
        }
    }
}
