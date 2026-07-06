import Foundation
import SwiftData

// MARK: - OpportunityStatus

enum OpportunityStatus: String, Codable {
    case pending   // awaiting user decision
    case snoozed   // user asked to remind later
    case approved  // user created an automation rule
    case dismissed // user permanently dismissed
    case expired   // pattern decayed — no longer relevant
}

// MARK: - OpportunityOrigin

/// How this automation opportunity was created.
enum OpportunityOrigin: String, Codable {
    case detected       // derived automatically by PatternDetectionEngine
    case conversational // proposed by the user via the chatbot
    case contextual     // generated from a contextual rule
}

// MARK: - AutomationOpportunity

/// A ranked, explainable automation opportunity derived from a BehavioralPattern
/// or from a conversational user request.
/// Carries everything needed to explain itself and map into an AutomationProposal.
@Model
final class AutomationOpportunity {

    @Attribute(.unique) var id: UUID
    var profileID: UUID?
    var modifiedAt: Date

    var createdAt: Date
    var lastUpdatedAt: Date

    // — Presentation —
    var title: String
    var naturalLanguage: String
    var roomName: String

    // — Source —
    var patternID: UUID
    var confidence: Double
    var observations: Int
    var firstObservedAt: Date
    var lastObservedAt: Date
    var avgTimeString: String?
    var timeDeviationMinutes: Int
    var dayTypeLabel: String
    var patternTypeRaw: String  // BehavioralPatternType.rawValue

    // — Trigger (for proposal generation) —
    var triggerType: String
    var triggerTime: String?
    var triggerWeekdaysRaw: String?
    var triggerSensorType: String?
    var triggerThreshold: Double?
    var triggerDirection: String?

    // — Effect (for proposal generation) —
    var effectAccessoryIDString: String?
    var effectActionRaw: String
    var effectValue: Double?
    var effectValue2: Double?
    var effectSceneName: String?

    // — Status (rawValue strings for CloudKit field-level access) —
    var statusRaw: String
    var snoozedUntil: Date?
    var dismissedAt: Date?
    var approvedAt: Date?

    // — Origin (rawValue string for CloudKit field-level access) —
    var originRaw: String

    // MARK: - Computed enum wrappers

    var status: OpportunityStatus {
        get { OpportunityStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var origin: OpportunityOrigin {
        get { OpportunityOrigin(rawValue: originRaw) ?? .detected }
        set { originRaw = newValue.rawValue }
    }

    var patternType: BehavioralPatternType {
        get { BehavioralPatternType(rawValue: patternTypeRaw) ?? .temporal }
        set { patternTypeRaw = newValue.rawValue }
    }

    // MARK: - Computed

    var triggerWeekdays: [Int] {
        triggerWeekdaysRaw?
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? []
    }

    var confidenceLabel: String { "\(Int(confidence * 100))%" }

    var isActionable: Bool { status == .pending || status == .snoozed }

    /// True only when the opportunity has enough structured data to open the
    /// unified HomeKit automation builder without producing an empty proposal.
    var isStructurallyConvertibleToAutomation: Bool {
        hasSupportedAutomationTrigger && hasSupportedAutomationEffect
    }

    private var hasSupportedAutomationTrigger: Bool {
        switch triggerType {
        case "calendar":
            guard let triggerTime else { return false }
            let parts = triggerTime.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]) else { return false }
            return (0...23).contains(hour) && (0...59).contains(minute)

        case "characteristic":
            return triggerSensorType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        case "accessoryState":
            // Validità piena verificata dal mapper (risoluzione causa dal pattern sorgente).
            return true

        case "presence", "people":
            return true

        default:
            return false
        }
    }

    private var hasSupportedAutomationEffect: Bool {
        if effectSceneName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }

        guard let rawID = effectAccessoryIDString,
              UUID(uuidString: rawID) != nil else { return false }

        switch effectActionRaw {
        case "on", "activate", "off", "dim", "setMode", "setTemp", "setSpeed", "setHumidity",
             "open", "openGarage", "close", "closeGarage", "lock", "unlock",
             "armStay", "armAway", "armNight", "disarm":
            return true
        default:
            return false
        }
    }

    /// SF Symbol for the trigger type, shown in opportunity cards.
    var triggerIcon: String {
        switch triggerType {
        case "calendar":       return "clock"
        case "characteristic": return "waveform.path.ecg"
        default:               return "arrow.trianglehead.2.clockwise"
        }
    }

    /// Human-readable schedule summary for calendar and characteristic triggers.
    /// Returns nil for inApp triggers.
    var scheduleSummary: String? {
        switch triggerType {
        case "calendar":
            guard let time = triggerTime else { return nil }
            let days = triggerWeekdays
            if days.isEmpty {
                return "\(String(localized: "schedule.everyday", defaultValue: "Every day")) · \(time)"
            }
            let symbols = Calendar.current.shortWeekdaySymbols
            let dayNames = days.compactMap { d -> String? in
                guard d >= 1, d <= 7 else { return nil }
                return symbols[d - 1]
            }.joined(separator: ", ")
            return "\(dayNames) · \(time)"
        case "characteristic":
            guard let sensor = triggerSensorType else { return nil }
            let sensorName = SensorServiceType(rawValue: sensor)?.displayName ?? sensor
            let sensorRoom = roomName.isEmpty ? "" : " (\(roomName))"
            let dirSymbol  = triggerDirection == "above" ? ">" : "<"
            if let threshold = triggerThreshold {
                return "\(sensorName)\(sensorRoom) \(dirSymbol) \(String(format: "%.1f", threshold))"
            }
            return "\(sensorName)\(sensorRoom)"
        default:
            return nil
        }
    }

    // MARK: - Designated Init

    init(
        id: UUID = UUID(),
        profileID: UUID?,
        createdAt: Date,
        lastUpdatedAt: Date,
        title: String,
        naturalLanguage: String,
        roomName: String,
        patternID: UUID,
        confidence: Double,
        observations: Int,
        firstObservedAt: Date,
        lastObservedAt: Date,
        avgTimeString: String?,
        timeDeviationMinutes: Int,
        dayTypeLabel: String,
        patternTypeRaw: String,
        triggerType: String,
        triggerTime: String?,
        triggerWeekdaysRaw: String?,
        triggerSensorType: String?,
        triggerThreshold: Double?,
        triggerDirection: String?,
        effectAccessoryIDString: String?,
        effectActionRaw: String,
        effectValue: Double?,
        effectValue2: Double?,
        effectSceneName: String?,
        statusRaw: String,
        snoozedUntil: Date?,
        dismissedAt: Date?,
        approvedAt: Date?,
        originRaw: String
    ) {
        self.id                      = id
        self.profileID               = profileID
        self.modifiedAt              = .now
        self.createdAt               = createdAt
        self.lastUpdatedAt           = lastUpdatedAt
        self.title                   = title
        self.naturalLanguage         = naturalLanguage
        self.roomName                = roomName
        self.patternID               = patternID
        self.confidence              = confidence
        self.observations            = observations
        self.firstObservedAt         = firstObservedAt
        self.lastObservedAt          = lastObservedAt
        self.avgTimeString           = avgTimeString
        self.timeDeviationMinutes    = timeDeviationMinutes
        self.dayTypeLabel            = dayTypeLabel
        self.patternTypeRaw          = patternTypeRaw
        self.triggerType             = triggerType
        self.triggerTime             = triggerTime
        self.triggerWeekdaysRaw      = triggerWeekdaysRaw
        self.triggerSensorType       = triggerSensorType
        self.triggerThreshold        = triggerThreshold
        self.triggerDirection        = triggerDirection
        self.effectAccessoryIDString = effectAccessoryIDString
        self.effectActionRaw         = effectActionRaw
        self.effectValue             = effectValue
        self.effectValue2            = effectValue2
        self.effectSceneName         = effectSceneName
        self.statusRaw               = statusRaw
        self.snoozedUntil            = snoozedUntil
        self.dismissedAt             = dismissedAt
        self.approvedAt              = approvedAt
        self.originRaw               = originRaw
    }
}

// MARK: - AutomationOpportunity Equatable (identity-based)

extension AutomationOpportunity: Equatable {
    static func == (lhs: AutomationOpportunity, rhs: AutomationOpportunity) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - AutomationOpportunity + BehavioralPattern

extension AutomationOpportunity {

    /// Constructs an opportunity from a qualified BehavioralPattern.
    convenience init(from pattern: BehavioralPattern, profileID: UUID? = nil) {
        let title      = AutomationOpportunity.buildTitle(pattern: pattern)
        let weekdayStr = pattern.weekdays.isEmpty
            ? nil
            : pattern.weekdays.map(String.init).joined(separator: ",")

        let triggerType: String
        let triggerTime: String?
        let triggerWeekdaysRaw: String?
        var triggerSensorType: String?
        var triggerThreshold: Double?
        var triggerDirection: String?

        switch pattern.patternType {
        case .temporal, .scene, .lighting:
            triggerType        = "calendar"
            triggerTime        = pattern.avgTimeString
            triggerWeekdaysRaw = weekdayStr
        case .sequential:
            // P1: sequenze A→B diventano automazioni HomeKit con event-trigger.
            // I dettagli della causa (accessorio + azione) vivono nel BehavioralPattern
            // sorgente e vengono risolti dal mapper al momento della proposta.
            triggerType        = "accessoryState"
            triggerTime        = nil
            triggerWeekdaysRaw = weekdayStr
        case .contextual:
            // P2: condizione ambientale codificata nella causeSignature → trigger
            // a soglia sensore, già supportato end-to-end dal mapper ("characteristic").
            if let condition = pattern.causeSignature.flatMap(ContextualCondition.parse(fromSignature:)) {
                triggerType       = "characteristic"
                triggerSensorType = condition.sensorTypeRaw
                triggerThreshold  = condition.threshold
                triggerDirection  = condition.direction
            } else {
                triggerType = "inApp"
            }
            triggerTime        = nil
            triggerWeekdaysRaw = weekdayStr
        }

        let matchedSceneName = pattern.patternType == .scene ? pattern.causeName : nil

        self.init(
            profileID:            profileID,
            createdAt:            Date(),
            lastUpdatedAt:        Date(),
            title:                title,
            naturalLanguage:      pattern.naturalLanguageDescription,
            roomName:             pattern.roomName,
            patternID:            pattern.id,
            confidence:           pattern.confidence,
            observations:         pattern.observations,
            firstObservedAt:      pattern.firstObservedAt,
            lastObservedAt:       pattern.lastObservedAt,
            avgTimeString:        (pattern.patternType == .temporal || pattern.patternType == .scene)
                                      ? pattern.avgTimeString : nil,
            timeDeviationMinutes: pattern.timeDeviationMinutes,
            dayTypeLabel:         pattern.dayType?.localizedLabel ?? "",
            patternTypeRaw:       pattern.patternType.rawValue,
            triggerType:          triggerType,
            triggerTime:          triggerTime,
            triggerWeekdaysRaw:   triggerWeekdaysRaw,
            triggerSensorType:    triggerSensorType,
            triggerThreshold:     triggerThreshold,
            triggerDirection:     triggerDirection,
            effectAccessoryIDString: matchedSceneName == nil ? pattern.accessoryID?.uuidString : nil,
            effectActionRaw:      pattern.action.rawValue,
            effectValue:          pattern.numericValue,
            effectValue2:         nil,
            effectSceneName:      matchedSceneName,
            statusRaw:            OpportunityStatus.pending.rawValue,
            snoozedUntil:         nil,
            dismissedAt:          nil,
            approvedAt:           nil,
            originRaw:            OpportunityOrigin.detected.rawValue
        )
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

// MARK: - AutomationOpportunity + Conversational

extension AutomationOpportunity {

    /// Creates an opportunity from a user conversational request (chatbot `proposeOpportunity` tool).
    ///
    /// Synthetic fields: confidence = 0.0, observations = 0, origin = .conversational.
    /// The patternID is derived deterministically from semanticKey so cross-session dedup in
    /// rebuildOpportunities() works — two equal requests yield the same patternID and the
    /// preserved filter (origin != .detected) keeps only one copy.
    static func fromConversation(
        accessoryID:        String,
        action:             String,
        value:              Double?,
        value2:             Double? = nil,
        label:              String,
        naturalLanguage:    String,
        triggerType:        String,
        triggerTime:        String?,
        triggerWeekdaysRaw: String?,
        triggerSensorType:  String? = nil,
        triggerSensorRoom:  String? = nil,
        triggerThreshold:   Double? = nil,
        triggerDirection:   String? = nil,
        sceneName:          String? = nil,
        semanticKey:        String,
        profileID:          UUID?   = nil
    ) -> AutomationOpportunity {
        let patternID = uuidFromSeed(semanticKey)
        let now       = Date()
        let roomName  = triggerSensorRoom ?? ""

        return AutomationOpportunity(
            profileID:            profileID,
            createdAt:            now,
            lastUpdatedAt:        now,
            title:                label,
            naturalLanguage:      naturalLanguage,
            roomName:             roomName,
            patternID:            patternID,
            confidence:           0.0,
            observations:         0,
            firstObservedAt:      now,
            lastObservedAt:       now,
            avgTimeString:        nil,
            timeDeviationMinutes: 0,
            dayTypeLabel:         "",
            patternTypeRaw:       BehavioralPatternType.temporal.rawValue,
            triggerType:          triggerType,
            triggerTime:          triggerTime,
            triggerWeekdaysRaw:   triggerWeekdaysRaw,
            triggerSensorType:    triggerSensorType,
            triggerThreshold:     triggerThreshold,
            triggerDirection:     triggerDirection,
            effectAccessoryIDString: accessoryID,
            effectActionRaw:      action,
            effectValue:          value,
            effectValue2:         value2,
            effectSceneName:      sceneName,
            statusRaw:            OpportunityStatus.pending.rawValue,
            snoozedUntil:         nil,
            dismissedAt:          nil,
            approvedAt:           nil,
            originRaw:            OpportunityOrigin.conversational.rawValue
        )
    }

    /// Derives a stable UUID from an arbitrary seed string using a simple XOR fold of the
    /// UTF-8 bytes into 16 bytes, then reinterprets as a UUID.
    /// Not cryptographic — used solely as a deterministic patternID for dedup.
    private static func uuidFromSeed(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in seed.utf8.enumerated() {
            bytes[i % 16] ^= byte
        }
        // Set version 5 bits (name-based SHA)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2],  bytes[3],
            bytes[4], bytes[5], bytes[6],  bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
