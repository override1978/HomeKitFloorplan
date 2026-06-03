import Foundation

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
/// Può descrivere un comportamento su un accessorio o sull'attivazione di una scena.
/// L'utente può approvarlo (crea una Rule) o ignorarlo.
struct HabitPattern: Identifiable, Codable {
    var id: UUID
    /// Tipo di pattern: accessorio o scena.
    let patternType: PatternType
    /// Nome dell'accessorio (valido quando patternType == .accessory).
    let accessoryName: String
    /// UUID dell'accessorio (valido quando patternType == .accessory; UUID casuale per le scene).
    let accessoryID: UUID
    /// Nome della scena (valido quando patternType == .scene).
    let sceneName: String?
    let roomName: String
    /// Descrizione leggibile generata dall'AI (es. "Luci soggiorno abbassate al 30% ogni sera").
    let description: String
    let detectedAt: Date
    /// Confidenza 0.0–1.0 calcolata dall'AI.
    let confidence: Double
    /// JSON della regola pre-generata dall'AI, parsato da RuleEngineService.
    let suggestedRuleJSON: String
    var status: PatternStatus

    init(
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
        self.id = id
        self.patternType = patternType
        self.accessoryName = accessoryName
        self.accessoryID = accessoryID
        self.sceneName = sceneName
        self.roomName = roomName
        self.description = description
        self.detectedAt = detectedAt
        self.confidence = confidence
        self.suggestedRuleJSON = suggestedRuleJSON
        self.status = status
    }

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
