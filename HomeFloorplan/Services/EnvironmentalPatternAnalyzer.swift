import Foundation
import SwiftData

// MARK: - EnvironmentalRecurrencePattern

/// A recurring environmental exceedance event detected across multiple weeks of history.
/// Codable for UserDefaults persistence — no SwiftData migration needed.
struct EnvironmentalRecurrencePattern: Codable, Identifiable {

    var id:                 UUID
    var roomName:           String
    var sensorTypeRaw:      String
    /// Calendar weekday (1 = Sunday … 7 = Saturday).
    var weekday:            Int
    /// Hour of day (0–23) when the peak typically occurs.
    var hourOfDay:          Int
    /// Total DailySensorSummary records contributing to this pattern.
    var sampleCount:        Int
    /// How many of those days the sensor exceeded the seasonal warning threshold.
    var aboveWarningCount:  Int
    /// Mean peak value across all matching days.
    var meanPeakValue:      Double
    var lastUpdatedAt:      Date
    /// Season this pattern belongs to (CalendarSeason rawValue).
    /// Empty string means legacy data collected before Sprint 31 (treat as all-season).
    var seasonRaw:          String

    var sensorType: SensorServiceType? { SensorServiceType(rawValue: sensorTypeRaw) }

    var exceedanceRate: Double {
        sampleCount > 0 ? Double(aboveWarningCount) / Double(sampleCount) : 0
    }

    /// Confidence: saturates at 1.0 after 8 matching observations.
    var confidence: Double { min(1.0, Double(sampleCount) / 8.0) }

    // MARK: - CodingKeys

    enum CodingKeys: String, CodingKey {
        case id, roomName, sensorTypeRaw, weekday, hourOfDay
        case sampleCount, aboveWarningCount, meanPeakValue, lastUpdatedAt
        case seasonRaw
    }

    // MARK: - Inits

    init(
        id:                UUID,
        roomName:          String,
        sensorTypeRaw:     String,
        weekday:           Int,
        hourOfDay:         Int,
        sampleCount:       Int,
        aboveWarningCount: Int,
        meanPeakValue:     Double,
        lastUpdatedAt:     Date,
        seasonRaw:         String = ""
    ) {
        self.id                = id
        self.roomName          = roomName
        self.sensorTypeRaw     = sensorTypeRaw
        self.weekday           = weekday
        self.hourOfDay         = hourOfDay
        self.sampleCount       = sampleCount
        self.aboveWarningCount = aboveWarningCount
        self.meanPeakValue     = meanPeakValue
        self.lastUpdatedAt     = lastUpdatedAt
        self.seasonRaw         = seasonRaw
    }

    /// Backward-compatible decoder: `seasonRaw` defaults to "" when missing
    /// (records written before Sprint 31 don't contain this key).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                = try c.decode(UUID.self,   forKey: .id)
        roomName          = try c.decode(String.self, forKey: .roomName)
        sensorTypeRaw     = try c.decode(String.self, forKey: .sensorTypeRaw)
        weekday           = try c.decode(Int.self,    forKey: .weekday)
        hourOfDay         = try c.decode(Int.self,    forKey: .hourOfDay)
        sampleCount       = try c.decode(Int.self,    forKey: .sampleCount)
        aboveWarningCount = try c.decode(Int.self,    forKey: .aboveWarningCount)
        meanPeakValue     = try c.decode(Double.self, forKey: .meanPeakValue)
        lastUpdatedAt     = try c.decode(Date.self,   forKey: .lastUpdatedAt)
        seasonRaw         = (try? c.decodeIfPresent(String.self, forKey: .seasonRaw)) ?? ""
    }
}

// MARK: - EnvironmentalPatternAnalyzer

/// Scans DailySensorSummary history to find recurring environmental exceedances
/// grouped by (room, sensor type, weekday, hour-of-peak, season). Stores results in UserDefaults.
/// Intended to run once daily from the DataLifecycle background task.
enum EnvironmentalPatternAnalyzer {

    static let patternsKey = "env.recurrence.patterns.v1"

    /// Minimum fraction of matching days that exceeded the threshold to surface a pattern.
    private static let minExceedanceRate: Double = 0.60
    /// Minimum samples before a pattern is considered reliable.
    private static let minSamples: Int = 3
    /// Lookback window in days.
    private static let lookbackDays: Int = 56  // 8 weeks

    // MARK: - Analysis

    /// Fetches DailySensorSummary records, groups them by (room, sensor, weekday, hour, season),
    /// and persists detected patterns. Season-aware grouping (Sprint 31.5) prevents summer
    /// heat patterns from inflating winter baselines.
    static func analyze(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(lookbackDays) * 24 * 3600)
        let descriptor = FetchDescriptor<DailySensorSummary>(
            predicate: #Predicate { $0.date >= cutoff }
        )
        let summaries = (try? context.fetch(descriptor)) ?? []
        guard summaries.count >= 3 else { return }

        let cal    = Calendar.current
        let season = CalendarSeason.current

        // Group by (roomName, serviceTypeRaw, weekday, hourOfPeak, season)
        var groups: [String: [DailySensorSummary]] = [:]
        for s in summaries {
            let weekday    = cal.component(.weekday, from: s.date)
            let hour       = cal.component(.hour, from: s.peakAt)
            let seasonStr  = CalendarSeason.season(for: s.date).rawValue
            let key        = "\(s.roomName)|\(s.serviceTypeRaw)|\(weekday)|\(hour)|\(seasonStr)"
            groups[key, default: []].append(s)
        }

        var patterns: [EnvironmentalRecurrencePattern] = []
        for (keyStr, group) in groups {
            guard group.count >= minSamples else { continue }

            let parts = keyStr.split(separator: "|", maxSplits: 4)
            guard parts.count == 5,
                  let weekday = Int(parts[2]),
                  let hour    = Int(parts[3]),
                  let sType   = SensorServiceType(rawValue: String(parts[1]))
            else { continue }

            let threshold = SeasonalBaselineProvider.warningThreshold(for: sType, season: season)
            let aboveCount = group.filter { $0.peakValue >= threshold }.count
            let rate = Double(aboveCount) / Double(group.count)
            guard rate >= minExceedanceRate else { continue }

            let meanPeak  = group.map(\.peakValue).reduce(0, +) / Double(group.count)
            let seasonStr = String(parts[4])

            patterns.append(EnvironmentalRecurrencePattern(
                id:                UUID(),
                roomName:          String(parts[0]),
                sensorTypeRaw:     String(parts[1]),
                weekday:           weekday,
                hourOfDay:         hour,
                sampleCount:       group.count,
                aboveWarningCount: aboveCount,
                meanPeakValue:     meanPeak,
                lastUpdatedAt:     Date(),
                seasonRaw:         seasonStr
            ))
        }

        VersionedStore<[EnvironmentalRecurrencePattern]>(key: Self.patternsKey, version: 1).save(patterns)
    }

    // MARK: - Load

    /// Loads persisted patterns, preferring those for the current season.
    /// Falls back to legacy patterns (seasonRaw == "") when no seasonal data exists yet.
    static func loadPatterns() -> [EnvironmentalRecurrencePattern] {
        let decoded = VersionedStore<[EnvironmentalRecurrencePattern]>(key: patternsKey, version: 1).load() ?? []
        guard !decoded.isEmpty else { return [] }

        let currentSeason = CalendarSeason.current.rawValue
        let seasonal = decoded.filter { $0.seasonRaw == currentSeason }
        return seasonal.isEmpty ? decoded.filter { $0.seasonRaw.isEmpty } : seasonal
    }
}

// MARK: - CalendarSeason extension

private extension CalendarSeason {
    /// Returns the season for a given date (used during pattern analysis to bucket historical records).
    static func season(for date: Date) -> CalendarSeason {
        let month = Calendar.current.component(.month, from: date)
        switch month {
        case 3...5:  return .spring
        case 6...8:  return .summer
        case 9...11: return .autumn
        default:     return .winter
        }
    }
}
