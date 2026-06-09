import Foundation
import SwiftData

// MARK: - StorageHealthMonitor

/// Developer-only diagnostic tool for the Home Knowledge Retention Engine.
///
/// Reports row counts, estimated storage, growth trends, and lifecycle cycle state.
/// Not visible to end users. Intended for debug builds and CI validation.
///
/// Usage:
/// ```swift
/// let snapshot = StorageHealthMonitor.takeSnapshot(container: sharedModelContainer)
/// dprint(snapshot.summary)
/// ```
struct StorageHealthMonitor {

    // MARK: - Snapshot

    struct Snapshot {

        let capturedAt: Date

        // MARK: Raw telemetry counts (time-bounded, auto-pruned)
        let sensorReadingCount:          Int
        let accessoryEventCount:         Int
        let activityEventCount:          Int
        let actionEffectivenessCount:    Int
        let persistedInsightCount:       Int
        let sensorAlertEventCount:       Int

        // MARK: Aggregated knowledge counts (permanent)
        let dailySensorSummaryCount:     Int
        let accessoryUsageSummaryCount:  Int
        let effectivenessSummaryCount:   Int

        // MARK: Config / reference counts (permanent, small)
        let roomAnalysisStateCount:      Int
        let ruleCount:                   Int
        let floorplanCount:              Int

        // MARK: UserDefaults (not SwiftData)
        let habitPatternCount:           Int

        // MARK: Lifecycle metadata
        let lastLifecycleCycleDate:      Date?

        // MARK: - Computed

        /// Total raw telemetry rows (time-bounded data that will eventually be pruned).
        var totalRawRows: Int {
            sensorReadingCount + accessoryEventCount + activityEventCount +
            actionEffectivenessCount + persistedInsightCount + sensorAlertEventCount
        }

        /// Total aggregated knowledge rows (permanent).
        var totalKnowledgeRows: Int {
            dailySensorSummaryCount + accessoryUsageSummaryCount + effectivenessSummaryCount
        }

        /// Total SwiftData rows across all models.
        var totalRows: Int {
            totalRawRows + totalKnowledgeRows + roomAnalysisStateCount + ruleCount + floorplanCount
        }

        /// Rough database size estimate. Assumes 150 bytes per row average.
        var estimatedDatabaseKB: Int { totalRows * 150 / 1024 }

        /// How long ago the last lifecycle cycle ran. Nil if never.
        var cycleAgeHours: Double? {
            lastLifecycleCycleDate.map { Date().timeIntervalSince($0) / 3600 }
        }

        /// True if the lifecycle engine has not run in more than 48 hours.
        var isCycleOverdue: Bool {
            guard let age = cycleAgeHours else { return true }
            return age > 48
        }

        // MARK: Retention projections

        /// Projected monthly growth of raw rows (typical home usage).
        var projectedMonthlyRawGrowth: Int {
            // SensorReading: ~12/hour × 720 hours = 8640 (capped at 30-day retention)
            // AccessoryEvent: ~50/day × 30 = 1500 (capped at 30-day retention)
            // ActionEffectiveness: ~10/day × 90 = 900 (capped at 90-day retention)
            // ActivityEvent: ~30/day (capped at 500 records)
            // Combined steady-state: ~3500 raw rows/month
            3_500
        }

        /// Projected annual growth of knowledge rows (permanent summaries added per year).
        var projectedAnnualKnowledgeGrowth: Int {
            // DailySensorSummary: 365 days × 5 types × 5 rooms = 9125/yr
            // AccessoryUsageSummary: 52 weeks × 10 accessories = 520/yr
            // EffectivenessSummary: 12 months × 8 intents = 96/yr
            9_741
        }

        // MARK: - Summary string

        var summary: String {
            let df = DateFormatter()
            df.dateStyle = .short
            df.timeStyle = .short
            let lastRun = lastLifecycleCycleDate.map { df.string(from: $0) } ?? "never"
            let overdue = isCycleOverdue ? " ⚠️ OVERDUE" : ""

            return """
            ┌─ StorageHealthMonitor ──────────────────────────────
            │  Captured at:       \(df.string(from: capturedAt))
            │
            │  RAW TELEMETRY (pruned automatically):
            │    SensorReading:           \(sensorReadingCount)
            │    AccessoryEvent:          \(accessoryEventCount)
            │    ActivityEvent:           \(activityEventCount)
            │    ActionEffectiveness:     \(actionEffectivenessCount)
            │    PersistedInsight:        \(persistedInsightCount)
            │    SensorAlertEvent:        \(sensorAlertEventCount)
            │    ─────────────────────── \(totalRawRows) total raw rows
            │
            │  KNOWLEDGE (permanent aggregates):
            │    DailySensorSummary:      \(dailySensorSummaryCount)
            │    AccessoryUsageSummary:   \(accessoryUsageSummaryCount)
            │    EffectivenessSummary:    \(effectivenessSummaryCount)
            │    ─────────────────────── \(totalKnowledgeRows) total knowledge rows
            │
            │  CONFIG (permanent, small):
            │    Rules:                  \(ruleCount)
            │    Floorplans:             \(floorplanCount)
            │    RoomAnalysisState:      \(roomAnalysisStateCount)
            │    HabitPatterns (UD):     \(habitPatternCount)
            │
            │  TOTALS:
            │    All SwiftData rows:     \(totalRows)
            │    Est. database size:     ~\(estimatedDatabaseKB) KB
            │
            │  LIFECYCLE:
            │    Last cycle:             \(lastRun)\(overdue)
            │    Projected annual Δ:     +\(projectedAnnualKnowledgeGrowth) knowledge rows/yr
            └─────────────────────────────────────────────────────
            """
        }
    }

    // MARK: - Snapshot Factory

    /// Captures a point-in-time snapshot of database health.
    ///
    /// - Parameter container: The shared `ModelContainer`.
    /// - Returns: A fully populated `Snapshot`. All SwiftData errors are swallowed (returns 0).
    @MainActor
    static func takeSnapshot(container: ModelContainer) -> Snapshot {
        let ctx = ModelContext(container)

        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? ctx.fetchCount(FetchDescriptor<T>())) ?? 0
        }

        let habitCount: Int = {
            guard let data = UserDefaults.standard.data(forKey: "habitPatterns.persisted"),
                  let patterns = try? JSONDecoder().decode([HabitPattern].self, from: data)
            else { return 0 }
            return patterns.count
        }()

        return Snapshot(
            capturedAt: Date(),
            sensorReadingCount:         count(SensorReading.self),
            accessoryEventCount:        count(AccessoryEvent.self),
            activityEventCount:         count(ActivityEvent.self),
            actionEffectivenessCount:   count(ActionEffectivenessEvent.self),
            persistedInsightCount:      count(PersistedInsight.self),
            sensorAlertEventCount:      count(SensorAlertEvent.self),
            dailySensorSummaryCount:    count(DailySensorSummary.self),
            accessoryUsageSummaryCount: count(AccessoryUsageSummary.self),
            effectivenessSummaryCount:  count(EffectivenessSummary.self),
            roomAnalysisStateCount:     count(RoomAnalysisState.self),
            ruleCount:                  count(Rule.self),
            floorplanCount:             count(Floorplan.self),
            habitPatternCount:          habitCount,
            lastLifecycleCycleDate:     UserDefaults.standard.object(
                forKey: "dataLifecycle.lastCycleDate") as? Date
        )
    }
}
