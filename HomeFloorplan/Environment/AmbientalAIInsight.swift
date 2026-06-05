import Foundation

// MARK: - InsightSeverity

enum InsightSeverity: String, Codable, Comparable {
    case info    = "info"     // 🔵 osservazione
    case warning = "warning"  // 🟡 attenzione
    case anomaly = "anomaly"  // 🔴 anomalia significativa

    private var sortOrder: Int {
        switch self {
        case .info:    return 0
        case .warning: return 1
        case .anomaly: return 2
        }
    }

    static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    var sfSymbol: String {
        switch self {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .anomaly: return "exclamationmark.octagon.fill"
        }
    }

    var color: String {
        switch self {
        case .info:    return "blue"
        case .warning: return "yellow"
        case .anomaly: return "red"
        }
    }
}

// MARK: - AINextAction

/// Azione generata dall'AI assieme a un insight.
/// Tre forme:
///   "suggest" — controllo accessorio HomeKit (ha accessoryID + accessoryActionType)
///   "tip"     — consiglio manuale senza accessorio ("Apri la finestra", "Arieggia la stanza")
///   "executeNow" / "createRule" — forme legacy ancora usate dal RuleEditor
struct AINextAction: Identifiable, Codable {
    let id: UUID
    /// Testo del pulsante/chip in italiano (max ~25 caratteri).
    let label: String
    /// "suggest" | "tip" | "executeNow" | "createRule"
    let actionType: String

    /// True se è un suggerimento manuale senza accessorio associato.
    var isTip: Bool { actionType == "tip" }

    // Per executeNow
    /// UUID stringa dell'accessorio da controllare.
    let accessoryID: String?
    /// "on" | "off" | "open" | "close" | "dim"
    let accessoryActionType: String?
    /// 0.0–1.0 per dim, nil per gli altri tipi.
    let accessoryValue: Double?
    /// Temperatura secondaria in °C per setMode su termostati/climatizzatori.
    let accessoryValue2: Double?

    // Per createRule
    /// JSON della RuleDraft pre-compilata dall'AI.
    let ruleJSON: String?

    init(
        id: UUID = UUID(),
        label: String,
        actionType: String,
        accessoryID: String? = nil,
        accessoryActionType: String? = nil,
        accessoryValue: Double? = nil,
        accessoryValue2: Double? = nil,
        ruleJSON: String? = nil
    ) {
        self.id = id
        self.label = label
        self.actionType = actionType
        self.accessoryID = accessoryID
        self.accessoryActionType = accessoryActionType
        self.accessoryValue = accessoryValue
        self.accessoryValue2 = accessoryValue2
        self.ruleJSON = ruleJSON
    }
}

// MARK: - AmbientalAIInsight

/// Insight generato dall'AI per una stanza specifica.
/// Complementa i warning manuali (basati su soglie fisse) con pattern
/// temporali e anomalie storiche che le soglie non rilevano.
struct AmbientalAIInsight: Identifiable {
    let id: UUID
    let roomName: String
    let message: String           // testo in linguaggio naturale (max 2 frasi)
    let severity: InsightSeverity
    let generatedAt: Date
    var isDismissed: Bool
    /// Azioni suggerite dall'AI (max 3). Possono essere vuote.
    let nextActions: [AINextAction]
    /// Intent semantici risolti dal LLM per questo insight (es. ["coolRoom", "reduceHumidity"]).
    /// Usati da ActionEffectivenessTracker per registrare dismissal ed expiration.
    let resolvedIntents: [String]

    init(
        id: UUID = UUID(),
        roomName: String,
        message: String,
        severity: InsightSeverity,
        generatedAt: Date = Date(),
        isDismissed: Bool = false,
        nextActions: [AINextAction] = [],
        resolvedIntents: [String] = []
    ) {
        self.id = id
        self.roomName = roomName
        self.message = message
        self.severity = severity
        self.generatedAt = generatedAt
        self.isDismissed = isDismissed
        self.nextActions = nextActions
        self.resolvedIntents = resolvedIntents
    }

    /// True se l'insight è scaduto (più vecchio di 2 ore).
    var isExpired: Bool {
        Date().timeIntervalSince(generatedAt) > 2 * 3600
    }

    /// True se deve ancora essere mostrato (non dismesso, non scaduto).
    var isVisible: Bool {
        !isDismissed && !isExpired
    }
}
