import Foundation

// MARK: - OpportunityStatus

enum OpportunityStatus: String, Codable {
    case pending   // awaiting user decision
    case snoozed   // user asked to remind later
    case approved  // user created an automation rule
    case dismissed // user permanently dismissed
    case expired   // pattern decayed — no longer relevant
}

// MARK: - AutomationOpportunity

/// A ranked, explainable automation opportunity derived from a BehavioralPattern.
/// Carries everything needed to explain itself and build a Rule when approved.
struct AutomationOpportunity: Identifiable, Codable {
    var id:            UUID
    var createdAt:     Date
    var lastUpdatedAt: Date

    // — Presentation —
    var title:           String
    var naturalLanguage: String
    var roomName:        String

    // — Source —
    var patternID:   UUID
    var confidence:  Double
    var observations:Int
    var firstObservedAt:        Date
    var lastObservedAt:         Date
    var avgTimeString:          String?   // "22:43"
    var timeDeviationMinutes:   Int
    var dayTypeLabel:           String
    var patternType:            BehavioralPatternType

    // — Trigger (for Rule generation) —
    var triggerType:           String    // "calendar" | "characteristic" | "inApp"
    var triggerTime:           String?   // "23:15"
    var triggerWeekdaysRaw:    String?   // "2,3,4,5,6"
    var triggerSensorType:     String?
    var triggerThreshold:      Double?
    var triggerDirection:      String?

    // — Effect (for Rule generation) —
    var effectAccessoryIDString: String?
    var effectActionRaw:         String
    var effectValue:             Double?

    // — Status —
    var status:      OpportunityStatus
    var snoozedUntil:Date?
    var dismissedAt: Date?
    var approvedAt:  Date?

    // MARK: - Computed

    var triggerWeekdays: [Int] {
        triggerWeekdaysRaw?
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? []
    }

    var confidenceLabel: String { "\(Int(confidence * 100))%" }

    var isActionable: Bool { status == .pending || status == .snoozed }

    /// Builds a Rule from this opportunity — call after user approval.
    func buildRule() -> Rule {
        Rule(
            name:                    title,
            ruleDescription:         naturalLanguage,
            triggerType:             triggerType,
            triggerTime:             triggerTime,
            triggerWeekdays:         triggerWeekdaysRaw,
            triggerCharacteristicID: triggerSensorType,
            triggerThreshold:        triggerThreshold,
            actionAccessoryID:       effectAccessoryIDString ?? "",
            actionType:              effectActionRaw,
            actionValue:             effectValue,
            executionMode:           "inApp",
            isEnabled:               true,
            confidenceScore:         confidence,
            generatedByAI:           true
        )
    }
}

// MARK: - AutomationOpportunity + BehavioralPattern

extension AutomationOpportunity {

    /// Constructs an opportunity from a qualified BehavioralPattern.
    init(from pattern: BehavioralPattern) {
        let title = AutomationOpportunity.buildTitle(pattern: pattern)
        let weekdayStr = pattern.weekdays.isEmpty
            ? nil
            : pattern.weekdays.map(String.init).joined(separator: ",")

        self.id            = UUID()
        self.createdAt     = Date()
        self.lastUpdatedAt = Date()
        self.title         = title
        self.naturalLanguage = pattern.naturalLanguageDescription
        self.roomName        = pattern.roomName
        self.patternID       = pattern.id
        self.confidence      = pattern.confidence
        self.observations    = pattern.observations
        self.firstObservedAt = pattern.firstObservedAt
        self.lastObservedAt  = pattern.lastObservedAt
        self.avgTimeString   = (pattern.patternType == .temporal || pattern.patternType == .scene)
                                ? pattern.avgTimeString : nil
        self.timeDeviationMinutes = pattern.timeDeviationMinutes
        self.dayTypeLabel    = pattern.dayType?.localizedLabel ?? ""
        self.patternType     = pattern.patternType

        // Trigger mapping
        switch pattern.patternType {
        case .temporal, .scene, .lighting:
            self.triggerType        = "calendar"
            self.triggerTime        = pattern.avgTimeString
            self.triggerWeekdaysRaw = weekdayStr
            self.triggerSensorType  = nil
            self.triggerThreshold   = nil
            self.triggerDirection   = nil
        case .sequential, .contextual:
            self.triggerType        = "inApp"
            self.triggerTime        = nil
            self.triggerWeekdaysRaw = weekdayStr
            self.triggerSensorType  = nil
            self.triggerThreshold   = nil
            self.triggerDirection   = nil
        }

        self.effectAccessoryIDString = pattern.accessoryID?.uuidString
        self.effectActionRaw         = pattern.action.rawValue
        self.effectValue             = pattern.numericValue

        self.status      = .pending
        self.snoozedUntil = nil
        self.dismissedAt  = nil
        self.approvedAt   = nil
    }

    private static func buildTitle(pattern: BehavioralPattern) -> String {
        switch pattern.action {
        case .on:
            return String(
                format: String(localized: "behavioral.opportunity.title.on",
                               defaultValue: "Turn on %@"),
                pattern.accessoryName
            )
        case .off:
            return String(
                format: String(localized: "behavioral.opportunity.title.off",
                               defaultValue: "Turn off %@"),
                pattern.accessoryName
            )
        case .dim:
            return String(
                format: String(localized: "behavioral.opportunity.title.dim",
                               defaultValue: "Dim %@"),
                pattern.accessoryName
            )
        case .activate:
            return String(
                format: String(localized: "behavioral.opportunity.title.activate",
                               defaultValue: "Activate %@"),
                pattern.accessoryName
            )
        case .lock:
            return String(
                format: String(localized: "behavioral.opportunity.title.lock",
                               defaultValue: "Lock %@"),
                pattern.accessoryName
            )
        case .unlock:
            return String(
                format: String(localized: "behavioral.opportunity.title.unlock",
                               defaultValue: "Unlock %@"),
                pattern.accessoryName
            )
        case .open:
            return String(
                format: String(localized: "behavioral.opportunity.title.open",
                               defaultValue: "Open %@"),
                pattern.accessoryName
            )
        case .close:
            return String(
                format: String(localized: "behavioral.opportunity.title.close",
                               defaultValue: "Close %@"),
                pattern.accessoryName
            )
        }
    }
}
