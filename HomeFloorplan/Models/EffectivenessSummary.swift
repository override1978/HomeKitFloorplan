import Foundation
import SwiftData

// MARK: - EffectivenessSummary

/// Permanent monthly aggregate of ActionEffectivenessEvent records per AI intent.
///
/// Created by DataLifecycleService from closed calendar months before raw
/// ActionEffectivenessEvent records expire at 90 days. Preserves the home's
/// AI effectiveness history indefinitely for long-term ranking and confidence scoring.
///
/// Raw → Aggregate pipeline:
///   ActionEffectivenessEvent (90-day raw)  →  EffectivenessSummary (permanent)
@Model
final class EffectivenessSummary {

    /// Primary key.
    var id: UUID

    /// First day of the represented calendar month at midnight.
    var monthStart: Date

    /// ActionIntent.rawValue: "coolRoom", "heatRoom", "reduceHumidity", etc.
    var intentRaw: String

    /// Count of events with outcome == "executed".
    var executedCount: Int

    /// Count of events with outcome == "dismissed".
    var dismissedCount: Int

    /// Count of events with outcome == "expired".
    var expiredCount: Int

    /// Count of events where effectivenessScore was measured (non-nil).
    var measuredCount: Int

    /// Mean effectivenessScore across measured events (0.0–1.0). Zero if measuredCount == 0.
    var avgEffectivenessScore: Double

    /// measuredCount / max(executedCount, 1) — indicates how often outcomes were measured.
    var confidence: Double

    init(
        id: UUID = UUID(),
        monthStart: Date,
        intentRaw: String,
        executedCount: Int,
        dismissedCount: Int,
        expiredCount: Int,
        measuredCount: Int,
        avgEffectivenessScore: Double,
        confidence: Double
    ) {
        self.id                    = id
        self.monthStart            = monthStart
        self.intentRaw             = intentRaw
        self.executedCount         = executedCount
        self.dismissedCount        = dismissedCount
        self.expiredCount          = expiredCount
        self.measuredCount         = measuredCount
        self.avgEffectivenessScore = avgEffectivenessScore
        self.confidence            = confidence
    }

    /// Total interactions (executed + dismissed + expired).
    var totalInteractions: Int { executedCount + dismissedCount + expiredCount }

    /// Execution rate: executedCount / max(totalInteractions, 1).
    var executionRate: Double {
        totalInteractions > 0 ? Double(executedCount) / Double(totalInteractions) : 0
    }
}
