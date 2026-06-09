import Foundation
import SwiftData

// MARK: - InsightPersistedStatus

enum InsightPersistedStatus: String {
    case active    = "active"
    case dismissed = "dismissed"
    case expired   = "expired"
    case executed  = "executed"
}

// MARK: - PersistedInsight

/// SwiftData record for an AI-generated environmental insight.
///
/// Bridges the in-memory AmbientalAIInsight (UI/resolver layer) with persistent
/// storage so insights survive view destruction, navigation, and app relaunch.
///
/// nextActions are serialised as JSON so they can be reconstructed without
/// requiring a live HomeKit session (accessories may be offline at read time).
@Model
final class PersistedInsight {
    #Index<PersistedInsight>([\.generatedAt], [\.roomName])

    var id: UUID
    var roomName: String
    var generatedAt: Date
    /// Expiry timestamp = generatedAt + 2 h (mirrors AmbientalAIInsight.isExpired).
    var expiresAt: Date
    var message: String
    /// InsightSeverity.rawValue — "info" | "warning" | "anomaly"
    var severityRaw: String
    /// Resolved ActionIntent raw values, e.g. ["coolRoom", "reduceHumidity"]
    var intentsRaw: [String]
    /// JSON-encoded [AINextAction] for lossless round-trip without HomeKit.
    var nextActionsJSON: String
    /// InsightPersistedStatus.rawValue
    var statusRaw: String

    // Sprint 16 — Semantic AI fields (optional, nil for pre-16 records)

    /// IntelligenceLevel.rawValue — "observation" | "pattern" | "prediction" | "recommendation"
    var intelligenceLevelRaw: String?
    /// Stable English snake_case semantic pattern key for deduplication (Part 8).
    var patternKey: String?
    /// Brief explanation of why this insight was generated (Part 11).
    var whyExplanation: String?
    /// AI confidence 0.0–1.0.
    var confidenceScore: Double?

    // Sprint 16A — Accessory attribution (optional, nil for pre-16A records)

    /// UUID string of the primary accessory that triggered this insight.
    var sourceAccessoryID: String?
    /// Display name of the triggering accessory.
    var sourceAccessoryName: String?
    /// SensorServiceType.rawValue of the triggering sensor.
    var sourceServiceType: String?

    // Sprint 24A — Prompt versioning (optional, nil for pre-24A records)

    /// AIPromptVersion constant used when generating this insight.
    /// DataLifecycleService expires insights with a different version than current.
    var promptVersion: String?

    init(
        id: UUID = UUID(),
        roomName: String,
        generatedAt: Date,
        expiresAt: Date,
        message: String,
        severityRaw: String,
        intentsRaw: [String],
        nextActionsJSON: String,
        statusRaw: String = InsightPersistedStatus.active.rawValue,
        intelligenceLevelRaw: String? = nil,
        patternKey: String? = nil,
        whyExplanation: String? = nil,
        confidenceScore: Double? = nil,
        sourceAccessoryID: String? = nil,
        sourceAccessoryName: String? = nil,
        sourceServiceType: String? = nil,
        promptVersion: String? = nil
    ) {
        self.id = id
        self.roomName = roomName
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.message = message
        self.severityRaw = severityRaw
        self.intentsRaw = intentsRaw
        self.nextActionsJSON = nextActionsJSON
        self.statusRaw = statusRaw
        self.intelligenceLevelRaw = intelligenceLevelRaw
        self.patternKey = patternKey
        self.whyExplanation = whyExplanation
        self.confidenceScore = confidenceScore
        self.sourceAccessoryID = sourceAccessoryID
        self.sourceAccessoryName = sourceAccessoryName
        self.sourceServiceType = sourceServiceType
        self.promptVersion = promptVersion
    }

    // MARK: - Factory

    /// Build a PersistedInsight from the in-memory insight produced by AmbientalAIService.
    static func from(_ insight: AmbientalAIInsight) -> PersistedInsight {
        let actionsJSON: String
        if let data = try? JSONEncoder().encode(insight.nextActions),
           let str = String(data: data, encoding: .utf8) {
            actionsJSON = str
        } else {
            actionsJSON = "[]"
        }
        return PersistedInsight(
            id: insight.id,
            roomName: insight.roomName,
            generatedAt: insight.generatedAt,
            expiresAt: insight.generatedAt.addingTimeInterval(2 * 3600),
            message: insight.message,
            severityRaw: insight.severity.rawValue,
            intentsRaw: insight.resolvedIntents,
            nextActionsJSON: actionsJSON,
            intelligenceLevelRaw: insight.intelligenceLevel.rawValue,
            patternKey: insight.patternKey,
            whyExplanation: insight.whyExplanation,
            confidenceScore: insight.confidence,
            sourceAccessoryID: insight.sourceAccessoryID,
            sourceAccessoryName: insight.sourceAccessoryName,
            sourceServiceType: insight.sourceServiceType,
            promptVersion: insight.promptVersion
        )
    }

    // MARK: - Reconstruction

    /// Reconstruct the in-memory insight for the UI layer.
    /// Returns nil only if severityRaw is somehow corrupt.
    func toAmbientalAIInsight() -> AmbientalAIInsight? {
        guard let severity = InsightSeverity(rawValue: severityRaw) else { return nil }
        let nextActions = nextActionsJSON.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode([AINextAction].self, from: $0) } ?? []
        let level = intelligenceLevelRaw.flatMap { IntelligenceLevel(rawValue: $0) } ?? .observation
        return AmbientalAIInsight(
            id: id,
            roomName: roomName,
            message: message,
            severity: severity,
            intelligenceLevel: level,
            patternKey: patternKey,
            whyExplanation: whyExplanation,
            confidence: confidenceScore ?? 0.7,
            generatedAt: generatedAt,
            isDismissed: statusRaw == InsightPersistedStatus.dismissed.rawValue,
            nextActions: nextActions,
            resolvedIntents: intentsRaw,
            sourceAccessoryID: sourceAccessoryID,
            sourceAccessoryName: sourceAccessoryName,
            sourceServiceType: sourceServiceType,
            promptVersion: promptVersion
        )
    }
}
