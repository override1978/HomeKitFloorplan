import Foundation
import SwiftData

// MARK: - RoomAnalysisState

/// Persists the semantic state that was last successfully analyzed by the AI for a given room.
/// One row per room. Used to skip redundant LLM calls when the environmental meaning hasn't changed.
///
/// The semantic fingerprint encodes urgency levels, anomaly flags and room type — NOT raw sensor
/// values — so minor numeric fluctuations never re-trigger the AI.
@Model
final class RoomAnalysisState {

    /// HomeKit room name — natural key (one record per room).
    var roomName: String
    /// Timestamp of the last completed AI analysis.
    var lastAnalysisDate: Date
    /// Deterministic string encoding the semantic state at last analysis.
    /// Format: "sensorType:urgency:isAnomaly:anomalyDirection|...|rt:roomType"
    var semanticFingerprint: String
    /// Sorted resolved intent strings from the last generated insight (e.g. ["coolRoom"]).
    /// Empty if the last LLM call returned no insight.
    var lastIntentSet: [String]
    /// InsightSeverity.rawValue of the last generated insight. "none" if no insight was produced.
    var lastSeverityRaw: String
    /// ID of the last generated environmental insight. Nil if no insight was generated.
    /// Historical records may point to PersistedInsight; current flows mirror into PersistedHomeInsight.
    var lastInsightID: UUID?

    init(
        roomName: String,
        lastAnalysisDate: Date = Date(),
        semanticFingerprint: String,
        lastIntentSet: [String] = [],
        lastSeverityRaw: String = "none",
        lastInsightID: UUID? = nil
    ) {
        self.roomName            = roomName
        self.lastAnalysisDate    = lastAnalysisDate
        self.semanticFingerprint = semanticFingerprint
        self.lastIntentSet       = lastIntentSet
        self.lastSeverityRaw     = lastSeverityRaw
        self.lastInsightID       = lastInsightID
    }
}
