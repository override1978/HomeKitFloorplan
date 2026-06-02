import Foundation

// MARK: - PatternStatus

enum PatternStatus: String, Codable {
    case pending   = "pending"    // in attesa di decisione utente
    case approved  = "approved"   // trasformata in regola
    case dismissed = "dismissed"  // ignorata dall'utente
}

// MARK: - HabitPattern

/// Pattern di abitudine rilevato dall'AI sullo storico degli eventi accessori.
/// L'utente può approvarlo (crea una Rule) o ignorarlo.
struct HabitPattern: Identifiable, Codable {
    var id: UUID
    let accessoryName: String
    let accessoryID: UUID
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
        accessoryName: String,
        accessoryID: UUID,
        roomName: String,
        description: String,
        detectedAt: Date = Date(),
        confidence: Double,
        suggestedRuleJSON: String,
        status: PatternStatus = .pending
    ) {
        self.id = id
        self.accessoryName = accessoryName
        self.accessoryID = accessoryID
        self.roomName = roomName
        self.description = description
        self.detectedAt = detectedAt
        self.confidence = confidence
        self.suggestedRuleJSON = suggestedRuleJSON
        self.status = status
    }

    /// Confidenza formattata come percentuale intera (es. "87%").
    var confidenceLabel: String {
        "\(Int(confidence * 100))%"
    }
}
