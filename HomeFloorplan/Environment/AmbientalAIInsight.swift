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
        case .anomaly: return String(localized: "insight.severity.anomaly", defaultValue: "Critico")
        case .warning: return String(localized: "insight.severity.warning", defaultValue: "Attenzione")
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
        case .observation:    return String(localized: "intelligence.level.observation",    defaultValue: "Osservazione")
        case .pattern:        return String(localized: "intelligence.level.pattern",        defaultValue: "Schema")
        case .prediction:     return String(localized: "intelligence.level.prediction",     defaultValue: "Previsione")
        case .recommendation: return String(localized: "intelligence.level.recommendation", defaultValue: "Suggerimento")
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
/// Forme correnti:
///   "suggest" — controllo accessorio HomeKit immediato (ha accessoryID + accessoryActionType)
///   "tip"     — consiglio manuale senza accessorio ("Apri la finestra", "Arieggia la stanza")
///   altri tipi storici vengono trattati come proposta da revisionare nel nuovo Automation Builder.
struct AINextAction: Identifiable, Codable {
    let id: UUID
    /// Testo del pulsante/chip localizzato (max ~25 caratteri).
    let label: String
    /// "suggest" | "tip" | legacy values mapped to AutomationProposal review.
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

    /// JSON legacy di automazione. Conservato per compatibilità con insight persistiti.
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

// MARK: - Ambiental Automation Proposal Factory

enum AmbientalAutomationProposalFactory {
    static func proposal(
        from action: AINextAction,
        insight: AmbientalAIInsight,
        fallbackAccessoryID: String?
    ) -> AutomationProposal? {
        let legacy = legacyRulePayload(from: action.ruleJSON)
        let accessoryID = action.accessoryID
            ?? legacy.accessoryID
            ?? fallbackAccessoryID
        let actionType = action.accessoryActionType
            ?? legacy.actionType
            ?? "on"

        guard let accessoryID,
              let proposalAction = AutomationProposalMapper.chatbotAction(
                accessoryID: accessoryID,
                action: actionType,
                value: action.accessoryValue ?? legacy.actionValue,
                value2: action.accessoryValue2 ?? legacy.actionValue2
              ) else {
            return nil
        }

        let startEvents = startEvents(from: legacy)
        let unsupportedReason = startEvents.isEmpty
            ? String(localized: "automation.proposal.unsupported.trigger", defaultValue: "This opportunity cannot be converted because its trigger is not supported by the automation builder yet.")
            : nil

        return AutomationProposal(
            source: .manual,
            title: actionLabel(action, insight: insight),
            explanation: insight.message,
            confidence: insight.confidence,
            startEvents: startEvents,
            actions: [proposalAction],
            limitations: unsupportedReason.map { [$0] } ?? [],
            requiresUserReview: true,
            unsupportedReason: unsupportedReason,
            shouldEnableAutomation: true
        )
    }

    private static func actionLabel(_ action: AINextAction, insight: AmbientalAIInsight) -> String {
        let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty { return label }
        return String(
            format: String(localized: "environment.automation.proposal.title", defaultValue: "Automation for %@"),
            insight.roomName
        )
    }

    private static func startEvents(from legacy: LegacyRulePayload) -> [AutomationProposalStartEvent] {
        switch legacy.triggerType {
        case "calendar":
            guard let time = legacy.triggerTime,
                  let components = timeComponents(from: time) else { return [] }
            return [.schedule(AutomationProposalSchedule(
                hour: components.hour,
                minute: components.minute,
                weekdays: normalizedWeekdays(from: legacy.weekdays)
            ))]
        case "characteristic":
            guard let threshold = legacy.triggerThreshold else { return [] }
            return [.accessory(AutomationProposalCapabilitySelection(
                characteristicID: legacy.triggerCharacteristicID.flatMap(UUID.init(uuidString:)),
                comparisonOperator: .greaterThan,
                targetValue: .number(threshold)
            ))]
        default:
            return []
        }
    }

    private struct LegacyRulePayload {
        var triggerType: String?
        var triggerTime: String?
        var weekdays: [Int]
        var triggerCharacteristicID: String?
        var triggerThreshold: Double?
        var accessoryID: String?
        var actionType: String?
        var actionValue: Double?
        var actionValue2: Double?
    }

    private static func legacyRulePayload(from json: String?) -> LegacyRulePayload {
        guard let json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LegacyRulePayload(weekdays: [])
        }

        return LegacyRulePayload(
            triggerType: dict["triggerType"] as? String,
            triggerTime: dict["triggerTime"] as? String ?? dict["time"] as? String,
            weekdays: dict["triggerWeekdays"] as? [Int] ?? dict["weekdays"] as? [Int] ?? [],
            triggerCharacteristicID: dict["triggerCharacteristicID"] as? String,
            triggerThreshold: dict["triggerThreshold"] as? Double,
            accessoryID: dict["actionAccessoryID"] as? String ?? dict["accessoryID"] as? String,
            actionType: dict["actionType"] as? String ?? dict["action"] as? String,
            actionValue: dict["actionValue"] as? Double ?? dict["value"] as? Double,
            actionValue2: dict["actionValue2"] as? Double
        )
    }

    private static func timeComponents(from text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    private static func normalizedWeekdays(from values: [Int]) -> Set<Int> {
        let normalized = values.filter { (1...7).contains($0) }
        return normalized.isEmpty ? Set(1...7) : Set(normalized)
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
