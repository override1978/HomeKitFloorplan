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

    var localizedLabel: String {
        switch self {
        case .anomaly: return String(localized: "insight.severity.anomaly", defaultValue: "Anomaly")
        case .warning: return String(localized: "insight.severity.warning", defaultValue: "Warning")
        case .info:    return String(localized: "insight.severity.info",    defaultValue: "Info")
        }
    }
}

// MARK: - IntelligenceLevel

/// Classifies the semantic nature of an AI insight.
/// Drives icon and badge display in the feed and digest card.
enum IntelligenceLevel: String, Codable, CaseIterable {
    case observation    = "observation"
    case pattern        = "pattern"
    case prediction     = "prediction"
    case recommendation = "recommendation"

    var sfSymbol: String {
        switch self {
        case .observation:    return "eye"
        case .pattern:        return "arrow.triangle.2.circlepath"
        case .prediction:     return "wand.and.stars"
        case .recommendation: return "lightbulb.fill"
        }
    }

    var localizedLabel: String {
        switch self {
        case .observation:    return String(localized: "intelligence.level.observation",    defaultValue: "Observation")
        case .pattern:        return String(localized: "intelligence.level.pattern",        defaultValue: "Pattern")
        case .prediction:     return String(localized: "intelligence.level.prediction",     defaultValue: "Prediction")
        case .recommendation: return String(localized: "intelligence.level.recommendation", defaultValue: "Recommendation")
        }
    }

    /// Color token resolved in the view layer.
    var colorToken: String {
        switch self {
        case .observation:    return "blue"
        case .pattern:        return "indigo"
        case .prediction:     return "purple"
        case .recommendation: return "green"
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
    /// Testo del pulsante/chip localizzato (max ~25 caratteri).
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

    /// SF Symbol override per le tip manuali. Nil → usa "lightbulb.fill" come fallback.
    let iconName: String?
    /// Display name of the target accessory (e.g. "Aqara Climate Sensor Bagno").
    /// Populated by ActionResolver at resolution time; nil for manual tips.
    let accessoryName: String?

    init(
        id: UUID = UUID(),
        label: String,
        actionType: String,
        accessoryID: String? = nil,
        accessoryActionType: String? = nil,
        accessoryValue: Double? = nil,
        accessoryValue2: Double? = nil,
        ruleJSON: String? = nil,
        iconName: String? = nil,
        accessoryName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.actionType = actionType
        self.accessoryID = accessoryID
        self.accessoryActionType = accessoryActionType
        self.accessoryValue = accessoryValue
        self.accessoryValue2 = accessoryValue2
        self.ruleJSON = ruleJSON
        self.iconName = iconName
        self.accessoryName = accessoryName
    }
}

// MARK: - AmbientalAIInsight

/// Insight generato dall'AI per una stanza specifica.
/// Complementa i warning manuali (basati su soglie fisse) con pattern
/// temporali e anomalie storiche che le soglie non rilevano.
struct AmbientalAIInsight: Identifiable {
    let id: UUID
    let roomName: String
    /// Messaggio semantico in linguaggio naturale (max 2 frasi, lingua del dispositivo).
    let message: String
    let severity: InsightSeverity
    /// Classification of the insight's semantic nature (Part 12).
    let intelligenceLevel: IntelligenceLevel
    /// Stable English snake_case key for semantic deduplication across sessions (Part 8).
    let patternKey: String?
    /// Brief explanation of why this insight was generated (Part 11).
    let whyExplanation: String?
    /// AI confidence in this insight 0.0–1.0.
    let confidence: Double
    let generatedAt: Date
    var isDismissed: Bool
    /// Azioni suggerite dall'AI (max 3). Possono essere vuote.
    let nextActions: [AINextAction]
    /// Intent semantici risolti dal LLM per questo insight (es. ["coolRoom", "reduceHumidity"]).
    /// Usati da ActionEffectivenessTracker per registrare dismissal ed expiration.
    let resolvedIntents: [String]

    // MARK: Sprint 16A — Accessory attribution

    /// UUID string of the primary accessory whose reading triggered this insight.
    /// Nil when the insight is synthesised from multiple sensors or no accessory is known.
    let sourceAccessoryID: String?
    /// Display name of the primary triggering accessory (e.g. "Aqara Climate Sensor Bagno").
    let sourceAccessoryName: String?
    /// SensorServiceType.rawValue of the triggering sensor (e.g. "humidity", "carbonDioxide").
    let sourceServiceType: String?

    // MARK: Sprint 24A/E — Prompt versioning & language quality

    /// AIPromptVersion used when generating this insight. Persisted for stale-version detection.
    let promptVersion: String?
    /// True when the response message appears to be in the wrong language (24.E quality flag).
    /// Only meaningful at generation time; not stored in PersistedInsight.
    let isLanguageSuspect: Bool

    init(
        id: UUID = UUID(),
        roomName: String,
        message: String,
        severity: InsightSeverity,
        intelligenceLevel: IntelligenceLevel = .observation,
        patternKey: String? = nil,
        whyExplanation: String? = nil,
        confidence: Double = 0.7,
        generatedAt: Date = Date(),
        isDismissed: Bool = false,
        nextActions: [AINextAction] = [],
        resolvedIntents: [String] = [],
        sourceAccessoryID: String? = nil,
        sourceAccessoryName: String? = nil,
        sourceServiceType: String? = nil,
        promptVersion: String? = nil,
        isLanguageSuspect: Bool = false
    ) {
        self.id = id
        self.roomName = roomName
        self.message = message
        self.severity = severity
        self.intelligenceLevel = intelligenceLevel
        self.patternKey = patternKey
        self.whyExplanation = whyExplanation
        self.confidence = confidence
        self.generatedAt = generatedAt
        self.isDismissed = isDismissed
        self.nextActions = nextActions
        self.resolvedIntents = resolvedIntents
        self.sourceAccessoryID = sourceAccessoryID
        self.sourceAccessoryName = sourceAccessoryName
        self.sourceServiceType = sourceServiceType
        self.promptVersion = promptVersion
        self.isLanguageSuspect = isLanguageSuspect
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
