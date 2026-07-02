import Foundation
import SwiftData

// MARK: - PatternStatus

enum PatternStatus: String, Codable {
    case pending   = "pending"    // in attesa di decisione utente
    case approved  = "approved"   // trasformata in regola
    case dismissed = "dismissed"  // ignorata dall'utente
}

// MARK: - PatternType

enum PatternType: String, Codable {
    case accessory = "accessory"  // pattern su un singolo accessorio HomeKit
    case scene     = "scene"      // pattern sull'attivazione di una scena HomeKit
}

// MARK: - HabitPattern

/// Pattern di abitudine rilevato dall'AI sullo storico degli eventi.
/// Stored in SwiftData for backup and future CloudKit sync.
@Model
final class HabitPattern {

    @Attribute(.unique) var id: UUID
    var patternTypeRaw: String      // PatternType.rawValue
    var accessoryName: String
    var accessoryID: UUID
    var sceneName: String?
    var roomName: String
    var patternDescription: String
    var detectedAt: Date
    var confidence: Double
    var suggestedRuleJSON: String
    var statusRaw: String           // PatternStatus.rawValue
    var modifiedAt: Date

    // MARK: - Enum Wrappers

    var patternType: PatternType {
        get { PatternType(rawValue: patternTypeRaw) ?? .accessory }
        set { patternTypeRaw = newValue.rawValue }
    }

    var status: PatternStatus {
        get { PatternStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    // MARK: - Designated Init

    init(
        id: UUID,
        patternTypeRaw: String,
        accessoryName: String,
        accessoryID: UUID,
        sceneName: String?,
        roomName: String,
        patternDescription: String,
        detectedAt: Date,
        confidence: Double,
        suggestedRuleJSON: String,
        statusRaw: String
    ) {
        self.id                 = id
        self.patternTypeRaw     = patternTypeRaw
        self.accessoryName      = accessoryName
        self.accessoryID        = accessoryID
        self.sceneName          = sceneName
        self.roomName           = roomName
        self.patternDescription = patternDescription
        self.detectedAt         = detectedAt
        self.confidence         = confidence
        self.suggestedRuleJSON  = suggestedRuleJSON
        self.statusRaw          = statusRaw
        self.modifiedAt         = .now
    }
}

// MARK: - Convenience Init

extension HabitPattern {
    /// Factory-style convenience init matching the old struct initialiser signature.
    convenience init(
        id: UUID = UUID(),
        patternType: PatternType = .accessory,
        accessoryName: String,
        accessoryID: UUID,
        sceneName: String? = nil,
        roomName: String,
        description: String,
        detectedAt: Date = Date(),
        confidence: Double,
        suggestedRuleJSON: String,
        status: PatternStatus = .pending
    ) {
        self.init(
            id:                 id,
            patternTypeRaw:     patternType.rawValue,
            accessoryName:      accessoryName,
            accessoryID:        accessoryID,
            sceneName:          sceneName,
            roomName:           roomName,
            patternDescription: description,
            detectedAt:         detectedAt,
            confidence:         confidence,
            suggestedRuleJSON:  suggestedRuleJSON,
            statusRaw:          status.rawValue
        )
    }
}

// MARK: - Computed UI helpers

extension HabitPattern {
    /// Titolo da mostrare in UI: nome scena o nome accessorio.
    var displayTitle: String {
        sceneName ?? accessoryName
    }

    /// SF Symbol appropriato per il tipo di pattern.
    var sfSymbol: String {
        patternType == .scene ? "play.circle.fill" : "lightbulb.fill"
    }

    /// Confidenza formattata come percentuale intera (es. "87%").
    var confidenceLabel: String {
        "\(Int(confidence * 100))%"
    }
}
