import Foundation
import SwiftData
import Observation

// MARK: - ArrivalPrediction

struct ArrivalPrediction {
    let weekday:          Int
    let estimatedArrival: Date
    let confidenceLabel:  String
    let meanMinuteOfDay:  Double
    let stdDevMinutes:    Double
}

// MARK: - OccupancyPredictionService

/// Learns home-arrival and departure times from AccessoryEvent history.
///
/// Detection algorithm:
///   1. Fetch AccessoryEvents for the last 60 days, sorted chronologically.
///   2. A gap ≥ 3 h between consecutive events signals an absence period.
///   3. The first event after a gap → arrival signal for that weekday.
///   4. The last event before a gap → departure signal for that weekday.
///   5. Per-weekday running mean + std-dev maintained for both directions.
///   6. Prediction: nearest upcoming weekday whose arrival pattern fits within 15–45 min.
///
/// This service never acts autonomously — it only exposes predictions so that
/// ProactiveIntelligenceService can surface HVAC warm-up and automation suggestions.
@Observable
@MainActor
final class OccupancyPredictionService {

    // MARK: - State

    var patterns:          [OccupancyPattern] = []
    var departurePatterns: [OccupancyPattern] = []
    var nextArrival:       ArrivalPrediction?
    var lastAnalyzedAt:    Date?
    /// Timestamp of the most recent event in the analyzed window. Nil until first analysis.
    private(set) var lastSeenAt: Date?

    /// Active family profile for scoped persistence. Nil = global (all users).
    var activeProfileID: UUID?

    // MARK: - Constants

    /// Minimum inactivity gap to signal a home absence (3 h).
    private static let arrivalGapSeconds: Double = 3 * 3600
    /// Minimum samples required before a pattern is used for prediction.
    private static let minSamples = 3
    /// Minimum confidence to surface a prediction.
    private static let minConfidence: Double = 0.30
    /// Earliest lead time to show a warm-up suggestion (minutes).
    private static let minLeadMinutes: Double = 15
    /// Latest lead time — beyond this the suggestion is premature (minutes).
    private static let maxLeadMinutes: Double = 45
    /// Days of event history to analyze.
    private static let lookbackDays: Int = 60

    // MARK: - Persistence Keys (profile-scoped)

    private var patternsKey: String {
        activeProfileID.map { "occupancy.patterns.v1.\($0.uuidString)" }
            ?? "occupancy.patterns.v1"
    }
    private var departurePatternsKey: String {
        activeProfileID.map { "occupancy.departurePatterns.v1.\($0.uuidString)" }
            ?? "occupancy.departurePatterns.v1"
    }
    private var lastAnalysisKey: String {
        activeProfileID.map { "occupancy.lastAnalyzedAt.\($0.uuidString)" }
            ?? "occupancy.lastAnalyzedAt"
    }
    private var lastSeenKey: String {
        activeProfileID.map { "occupancy.lastSeenAt.\($0.uuidString)" }
            ?? "occupancy.lastSeenAt"
    }

    // MARK: - Init

    init() { loadPersistedPatterns() }

    // MARK: - Computed

    /// True when no accessory activity has been detected in the last 3 hours.
    /// Only meaningful during waking hours — ContextResolver guards nighttime hours separately.
    var isLikelyAway: Bool {
        guard let last = lastSeenAt else { return false }
        return Date().timeIntervalSince(last) > Self.arrivalGapSeconds
    }

    // MARK: - Public API

    /// Builds/updates per-weekday arrival and departure patterns from the AccessoryEvent store.
    /// Should be called from the daily DataLifecycle background task.
    func analyzeHistory(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(Self.lookbackDays) * 24 * 3600)
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        let events = (try? context.fetch(descriptor)) ?? []
        guard events.count >= 2 else { return }

        // Record most-recent activity timestamp for isLikelyAway
        lastSeenAt = events.last?.timestamp
        UserDefaults.standard.set(lastSeenAt, forKey: lastSeenKey)

        let cal = Calendar.current
        var arrivals:   [Int: OccupancyPattern] = [:]
        var departures: [Int: OccupancyPattern] = [:]

        for i in 1 ..< events.count {
            let gap = events[i].timestamp.timeIntervalSince(events[i - 1].timestamp)
            guard gap >= Self.arrivalGapSeconds else { continue }

            // Arrival: first event after the gap
            let arrComps  = cal.dateComponents([.hour, .minute], from: events[i].timestamp)
            let arrMinute = Double((arrComps.hour ?? 0) * 60 + (arrComps.minute ?? 0))
            let arrWday   = events[i].weekday
            if arrivals[arrWday] == nil {
                arrivals[arrWday] = OccupancyPattern(
                    weekday: arrWday, sampleCount: 0,
                    sumMinuteOfDay: 0, sumSquaredMinutes: 0
                )
            }
            arrivals[arrWday]!.record(minuteOfDay: arrMinute)

            // Departure: last event before the gap
            let depComps  = cal.dateComponents([.hour, .minute], from: events[i - 1].timestamp)
            let depMinute = Double((depComps.hour ?? 0) * 60 + (depComps.minute ?? 0))
            let depWday   = events[i - 1].weekday
            if departures[depWday] == nil {
                departures[depWday] = OccupancyPattern(
                    weekday: depWday, sampleCount: 0,
                    sumMinuteOfDay: 0, sumSquaredMinutes: 0
                )
            }
            departures[depWday]!.record(minuteOfDay: depMinute)
        }

        patterns          = Array(arrivals.values).sorted   { $0.weekday < $1.weekday }
        departurePatterns = Array(departures.values).sorted { $0.weekday < $1.weekday }
        lastAnalyzedAt    = Date()
        persistPatterns()
        UserDefaults.standard.set(lastAnalyzedAt, forKey: lastAnalysisKey)
        updateNextArrival()
    }

    /// Recomputes `nextArrival` from persisted patterns. Safe to call at any time.
    func updateNextArrival() {
        nextArrival = computeNextArrival()
    }

    /// Returns true when the predicted arrival is within the warm-up window and the user is away.
    func shouldSuggestHVACWarmUp(presenceState: PresenceState) -> Bool {
        guard presenceState == .away, let pred = nextArrival else { return false }
        let minutes = pred.estimatedArrival.timeIntervalSinceNow / 60
        return minutes >= Self.minLeadMinutes && minutes <= Self.maxLeadMinutes
    }

    // MARK: - Profile Switching

    /// Persists the current profile's data, loads the new profile's persisted data, then recomputes.
    func switchProfile(to profileID: UUID?) {
        persistPatterns()
        activeProfileID   = profileID
        patterns          = []
        departurePatterns = []
        nextArrival       = nil
        lastAnalyzedAt    = nil
        lastSeenAt        = nil
        loadPersistedPatterns()
    }

    // MARK: - Prediction Logic

    private func computeNextArrival() -> ArrivalPrediction? {
        let now = Date()
        let cal = Calendar.current
        let nowMinute = Double(
            cal.component(.hour,   from: now) * 60 +
            cal.component(.minute, from: now)
        )
        let eligible = patterns.filter {
            $0.sampleCount >= Self.minSamples && $0.confidence >= Self.minConfidence
        }
        guard !eligible.isEmpty else { return nil }

        for dayOffset in 0 ... 6 {
            guard let candidate = cal.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            let weekday = cal.component(.weekday, from: candidate)
            guard let pattern = eligible.first(where: { $0.weekday == weekday }) else { continue }

            let arrivalMinute = pattern.meanMinuteOfDay
            if dayOffset == 0 && arrivalMinute - nowMinute < Self.minLeadMinutes { continue }

            let h = Int(arrivalMinute) / 60
            let m = Int(arrivalMinute) % 60
            guard let arrivalDate = cal.date(bySettingHour: h, minute: m, second: 0,
                                             of: candidate) else { continue }

            return ArrivalPrediction(
                weekday:          weekday,
                estimatedArrival: arrivalDate,
                confidenceLabel:  confidenceLabel(pattern.confidence),
                meanMinuteOfDay:  pattern.meanMinuteOfDay,
                stdDevMinutes:    pattern.stdDevMinutes
            )
        }
        return nil
    }

    // MARK: - Persistence

    private func persistPatterns() {
        VersionedStore<[OccupancyPattern]>(key: patternsKey, version: 1).save(patterns)
        VersionedStore<[OccupancyPattern]>(key: departurePatternsKey, version: 1).save(departurePatterns)
    }

    private func loadPersistedPatterns() {
        patterns          = VersionedStore<[OccupancyPattern]>(key: patternsKey, version: 1).load()          ?? []
        departurePatterns = VersionedStore<[OccupancyPattern]>(key: departurePatternsKey, version: 1).load() ?? []
        lastAnalyzedAt = UserDefaults.standard.object(forKey: lastAnalysisKey) as? Date
        lastSeenAt     = UserDefaults.standard.object(forKey: lastSeenKey) as? Date
        updateNextArrival()
    }

    // MARK: - Helpers

    private func confidenceLabel(_ confidence: Double) -> String {
        switch confidence {
        case 0.80...: return String(localized: "occupancy.confidence.high",   defaultValue: "High")
        case 0.50...: return String(localized: "occupancy.confidence.medium", defaultValue: "Medium")
        default:      return String(localized: "occupancy.confidence.low",    defaultValue: "Low")
        }
    }
}
