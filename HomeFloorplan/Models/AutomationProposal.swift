import Foundation

/// Product-level automation draft shared by opportunities, chat, and the HomeKit builder.
/// It stores stable references only; the builder resolves them against the current HomeKit home.
struct AutomationProposal: Identifiable, Codable, Hashable {
    var id: UUID
    var source: AutomationProposalSource
    var title: String
    var explanation: String
    var confidence: Double?
    var startEvents: [AutomationProposalStartEvent]
    var conditions: [AutomationProposalCondition]
    var conditionJoinMode: AutomationProposalConditionJoinMode
    var actions: [AutomationProposalAction]
    var limitations: [String]
    var requiresUserReview: Bool
    var unsupportedReason: String?
    var shouldEnableAutomation: Bool

    var hasResolvedContent: Bool {
        !startEvents.isEmpty || !conditions.isEmpty || !actions.isEmpty
    }

    var isReadyForBuilder: Bool {
        hasResolvedContent
    }

    init(
        id: UUID = UUID(),
        source: AutomationProposalSource,
        title: String,
        explanation: String,
        confidence: Double? = nil,
        startEvents: [AutomationProposalStartEvent],
        conditions: [AutomationProposalCondition] = [],
        conditionJoinMode: AutomationProposalConditionJoinMode = .all,
        actions: [AutomationProposalAction],
        limitations: [String] = [],
        requiresUserReview: Bool = true,
        unsupportedReason: String? = nil,
        shouldEnableAutomation: Bool = true
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.explanation = explanation
        self.confidence = confidence
        self.startEvents = startEvents
        self.conditions = conditions
        self.conditionJoinMode = conditionJoinMode
        self.actions = actions
        self.limitations = limitations
        self.requiresUserReview = requiresUserReview
        self.unsupportedReason = unsupportedReason
        self.shouldEnableAutomation = shouldEnableAutomation
    }
}

enum AutomationProposalSource: String, Codable, Hashable {
    case opportunity
    case chatbot
    case manual
    case imported
}

enum AutomationProposalConditionJoinMode: String, Codable, Hashable {
    case all
    case any
}

enum AutomationProposalStartEvent: Codable, Hashable {
    case accessory(AutomationProposalCapabilitySelection)
    case schedule(AutomationProposalSchedule)
    case presence(AutomationProposalPresenceTrigger)
    case location(AutomationProposalLocationTrigger)
}

enum AutomationProposalCondition: Codable, Hashable {
    case accessory(AutomationProposalCapabilitySelection)
    case time(AutomationProposalTimeCondition)
    case presence(AutomationProposalPresenceCondition)
}

enum AutomationProposalAction: Codable, Hashable {
    case scene(AutomationProposalSceneReference)
    case accessoryPower(AutomationProposalPowerAction)
    case accessory(AutomationProposalAccessoryAction)
}

struct AutomationProposalCapabilitySelection: Codable, Hashable {
    var capabilityID: String?
    var accessoryID: UUID?
    var characteristicID: UUID?
    var comparisonOperator: AutomationProposalOperator
    var targetValue: AutomationProposalTargetValue

    init(
        capabilityID: String? = nil,
        accessoryID: UUID? = nil,
        characteristicID: UUID? = nil,
        comparisonOperator: AutomationProposalOperator,
        targetValue: AutomationProposalTargetValue
    ) {
        self.capabilityID = capabilityID
        self.accessoryID = accessoryID
        self.characteristicID = characteristicID
        self.comparisonOperator = comparisonOperator
        self.targetValue = targetValue
    }
}

enum AutomationProposalOperator: String, Codable, Hashable {
    case becomesActive
    case becomesInactive
    case equals
    case greaterThan
    case lessThan
}

enum AutomationProposalTargetValue: Codable, Hashable {
    case bool(Bool)
    case number(Double)
    case state(Int)
}

struct AutomationProposalSchedule: Codable, Hashable {
    var kind: AutomationProposalScheduleKind
    var hour: Int
    var minute: Int
    var offsetMinutes: Int
    var weekdays: Set<Int>

    init(
        kind: AutomationProposalScheduleKind = .fixedTime,
        hour: Int = 8,
        minute: Int = 0,
        offsetMinutes: Int = 0,
        weekdays: Set<Int> = Set(1...7)
    ) {
        self.kind = kind
        self.hour = hour
        self.minute = minute
        self.offsetMinutes = offsetMinutes
        self.weekdays = weekdays
    }
}

enum AutomationProposalScheduleKind: String, Codable, Hashable {
    case fixedTime
    case sunrise
    case sunset
}

struct AutomationProposalTimeCondition: Codable, Hashable {
    var kind: AutomationProposalScheduleKind
    var relation: AutomationProposalTimeRelation
    var hour: Int
    var minute: Int
    var offsetMinutes: Int
    var endKind: AutomationProposalScheduleKind
    var endHour: Int
    var endMinute: Int
    var endOffsetMinutes: Int

    init(
        kind: AutomationProposalScheduleKind = .fixedTime,
        relation: AutomationProposalTimeRelation = .after,
        hour: Int = 8,
        minute: Int = 0,
        offsetMinutes: Int = 0,
        endKind: AutomationProposalScheduleKind? = nil,
        endHour: Int = 18,
        endMinute: Int = 0,
        endOffsetMinutes: Int = 0
    ) {
        self.kind = kind
        self.relation = relation
        self.hour = hour
        self.minute = minute
        self.offsetMinutes = offsetMinutes
        self.endKind = endKind ?? kind
        self.endHour = endHour
        self.endMinute = endMinute
        self.endOffsetMinutes = endOffsetMinutes
    }

    private enum CodingKeys: String, CodingKey {
        case kind, relation, hour, minute, offsetMinutes
        case endKind, endHour, endMinute, endOffsetMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AutomationProposalScheduleKind.self, forKey: .kind)
        relation = try container.decode(AutomationProposalTimeRelation.self, forKey: .relation)
        hour = try container.decode(Int.self, forKey: .hour)
        minute = try container.decode(Int.self, forKey: .minute)
        offsetMinutes = try container.decode(Int.self, forKey: .offsetMinutes)
        endKind = try container.decodeIfPresent(AutomationProposalScheduleKind.self, forKey: .endKind) ?? kind
        endHour = try container.decodeIfPresent(Int.self, forKey: .endHour) ?? 18
        endMinute = try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? 0
        endOffsetMinutes = try container.decodeIfPresent(Int.self, forKey: .endOffsetMinutes) ?? 0
    }
}

enum AutomationProposalTimeRelation: String, Codable, Hashable {
    case after
    case before
    case between
}

struct AutomationProposalPresenceTrigger: Codable, Hashable {
    var kind: AutomationProposalPresenceTriggerKind
    var userScope: AutomationProposalPresenceUserScope
}

enum AutomationProposalPresenceTriggerKind: String, Codable, Hashable {
    case everyEntry
    case everyExit
    case firstEntry
    case lastExit
}

struct AutomationProposalPresenceCondition: Codable, Hashable {
    var kind: AutomationProposalPresenceConditionKind
    var userScope: AutomationProposalPresenceUserScope
}

enum AutomationProposalPresenceConditionKind: String, Codable, Hashable {
    case atHome
    case notAtHome
}

enum AutomationProposalPresenceUserScope: String, Codable, Hashable {
    case currentUser
    case homeUsers
}

struct AutomationProposalLocationTrigger: Codable, Hashable {
    var kind: AutomationProposalLocationKind
    var latitude: Double
    var longitude: Double
    var radius: Double
}

enum AutomationProposalLocationKind: String, Codable, Hashable {
    case arrive
    case leave
}

struct AutomationProposalSceneReference: Codable, Hashable {
    var sceneID: UUID?
    var name: String?
}

struct AutomationProposalPowerAction: Codable, Hashable {
    var capabilityID: String?
    var accessoryID: UUID?
    var characteristicID: UUID?
    var powerOn: Bool
}

struct AutomationProposalAccessoryAction: Codable, Hashable {
    var accessoryID: UUID
    var kind: AutomationProposalAccessoryActionKind
    var value: Double?
    var secondaryValue: Double?

    init(
        accessoryID: UUID,
        kind: AutomationProposalAccessoryActionKind,
        value: Double? = nil,
        secondaryValue: Double? = nil
    ) {
        self.accessoryID = accessoryID
        self.kind = kind
        self.value = value
        self.secondaryValue = secondaryValue
    }
}

enum AutomationProposalAccessoryActionKind: String, Codable, Hashable {
    case turnOn
    case turnOff
    case dim
    case activate
    case deactivate
    case setMode
    case setTemperature
    case setFanSpeed
    case setHumidity
    case open
    case close
    case lock
    case unlock
}
