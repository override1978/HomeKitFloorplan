import Foundation

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
    var effectSceneName:         String?

    // — Status —
    var status:      OpportunityStatus
    var snoozedUntil:Date?
    var dismissedAt: Date?
    var approvedAt:  Date?

    // — Origin —
    var origin: OpportunityOrigin

    // MARK: - Computed

    var triggerWeekdays: [Int] {
        triggerWeekdaysRaw?
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? []
    }

    var confidenceLabel: String { "\(Int(confidence * 100))%" }

    var isActionable: Bool { status == .pending || status == .snoozed }

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

    // MARK: - Codable (backward-compatible: origin missing → .detected)

    enum CodingKeys: String, CodingKey {
        case id, createdAt, lastUpdatedAt
        case title, naturalLanguage, roomName
        case patternID, confidence, observations
        case firstObservedAt, lastObservedAt, avgTimeString
        case timeDeviationMinutes, dayTypeLabel, patternType
        case triggerType, triggerTime, triggerWeekdaysRaw
        case triggerSensorType, triggerThreshold, triggerDirection
        case effectAccessoryIDString, effectActionRaw, effectValue, effectSceneName
        case status, snoozedUntil, dismissedAt, approvedAt
        case origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                       = try c.decode(UUID.self,                  forKey: .id)
        createdAt                = try c.decode(Date.self,                  forKey: .createdAt)
        lastUpdatedAt            = try c.decode(Date.self,                  forKey: .lastUpdatedAt)
        title                    = try c.decode(String.self,                forKey: .title)
        naturalLanguage          = try c.decode(String.self,                forKey: .naturalLanguage)
        roomName                 = try c.decode(String.self,                forKey: .roomName)
        patternID                = try c.decode(UUID.self,                  forKey: .patternID)
        confidence               = try c.decode(Double.self,                forKey: .confidence)
        observations             = try c.decode(Int.self,                   forKey: .observations)
        firstObservedAt          = try c.decode(Date.self,                  forKey: .firstObservedAt)
        lastObservedAt           = try c.decode(Date.self,                  forKey: .lastObservedAt)
        avgTimeString            = try c.decodeIfPresent(String.self,       forKey: .avgTimeString)
        timeDeviationMinutes     = try c.decode(Int.self,                   forKey: .timeDeviationMinutes)
        dayTypeLabel             = try c.decode(String.self,                forKey: .dayTypeLabel)
        patternType              = try c.decode(BehavioralPatternType.self, forKey: .patternType)
        triggerType              = try c.decode(String.self,                forKey: .triggerType)
        triggerTime              = try c.decodeIfPresent(String.self,       forKey: .triggerTime)
        triggerWeekdaysRaw       = try c.decodeIfPresent(String.self,       forKey: .triggerWeekdaysRaw)
        triggerSensorType        = try c.decodeIfPresent(String.self,       forKey: .triggerSensorType)
        triggerThreshold         = try c.decodeIfPresent(Double.self,       forKey: .triggerThreshold)
        triggerDirection         = try c.decodeIfPresent(String.self,       forKey: .triggerDirection)
        effectAccessoryIDString  = try c.decodeIfPresent(String.self,       forKey: .effectAccessoryIDString)
        effectActionRaw          = try c.decode(String.self,                forKey: .effectActionRaw)
        effectValue              = try c.decodeIfPresent(Double.self,       forKey: .effectValue)
        effectSceneName          = try c.decodeIfPresent(String.self,       forKey: .effectSceneName)
        status                   = try c.decode(OpportunityStatus.self,     forKey: .status)
        snoozedUntil             = try c.decodeIfPresent(Date.self,         forKey: .snoozedUntil)
        dismissedAt              = try c.decodeIfPresent(Date.self,         forKey: .dismissedAt)
        approvedAt               = try c.decodeIfPresent(Date.self,         forKey: .approvedAt)
        // Legacy JSON without `origin` defaults to .detected
        origin = try c.decodeIfPresent(OpportunityOrigin.self, forKey: .origin) ?? .detected
    }

    /// Builds a Rule from this opportunity — call after user approval.
    func buildRule() -> Rule {
        // For characteristic triggers, encode "sensorType|sensorRoom|direction" so the
        // in-app evaluation engine can identify both the sensor and the direction.
        let charID: String?
        if let st = triggerSensorType {
            var parts = [st]
            if !roomName.isEmpty { parts.append(roomName) }
            if let dir = triggerDirection { parts.append(dir) }
            charID = parts.joined(separator: "|")
        } else {
            charID = nil
        }

        // Delegate to HomeKit for calendar triggers and for characteristic triggers
        // that have a physical sensor (triggerSensorType set). The HomeKit path will
        // fall back to inApp automatically if the sensor isn't found as an HMCharacteristic.
        // Scene-based rules are always delegatable — the HMActionSet already exists in HomeKit.
        let canDelegate = effectSceneName != nil
            || triggerType == "calendar"
            || (triggerType == "characteristic" && triggerSensorType != nil)

        return Rule(
            name:                    title,
            ruleDescription:         naturalLanguage,
            triggerType:             triggerType,
            triggerTime:             triggerTime,
            triggerWeekdays:         triggerWeekdaysRaw,
            triggerCharacteristicID: charID,
            triggerThreshold:        triggerThreshold,
            actionAccessoryID:       effectAccessoryIDString ?? "",
            actionType:              effectActionRaw,
            actionValue:             effectValue,
            actionSceneName:         effectSceneName,
            executionMode:           canDelegate ? "homeKit" : "inApp",
            isEnabled:               true,
            confidenceScore:         confidence,
            generatedByAI:           true
        )
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
        self.origin       = .detected
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
    ///
    /// - Parameters:
    ///   - accessoryID: HomeKit UUID string of the target accessory.
    ///   - action: Action string ("on", "off", "dim", …).
    ///   - value: Numeric value for dim/setTemp/setSpeed; nil for on/off/open/close.
    ///   - label: Short user-facing label for the button/opportunity title.
    ///   - naturalLanguage: Full description shown in HabitsView.
    ///   - semanticKey: Stable dedup key, typically "\(accessoryID):\(action)".
    static func fromConversation(
        accessoryID:     String,
        action:          String,
        value:           Double?,
        label:           String,
        naturalLanguage: String,
        triggerType:     String,
        triggerTime:     String?,
        triggerWeekdaysRaw: String?,
        triggerSensorType:  String? = nil,
        triggerSensorRoom:  String? = nil,
        triggerThreshold:   Double? = nil,
        triggerDirection:   String? = nil,
        sceneName:          String? = nil,
        semanticKey:     String
    ) -> AutomationOpportunity {
        let patternID = uuidFromSeed(semanticKey)
        let now       = Date()

        // roomName holds the sensor room so buildRule() can encode it in triggerCharacteristicID.
        let roomName = triggerSensorRoom ?? ""

        let opp = AutomationOpportunity(
            id:                      UUID(),
            createdAt:               now,
            lastUpdatedAt:           now,
            title:                   label,
            naturalLanguage:         naturalLanguage,
            roomName:                roomName,
            patternID:               patternID,
            confidence:              0.0,
            observations:            0,
            firstObservedAt:         now,
            lastObservedAt:          now,
            avgTimeString:           nil,
            timeDeviationMinutes:    0,
            dayTypeLabel:            "",
            patternType:             .temporal,
            triggerType:             triggerType,
            triggerTime:             triggerTime,
            triggerWeekdaysRaw:      triggerWeekdaysRaw,
            triggerSensorType:       triggerSensorType,
            triggerThreshold:        triggerThreshold,
            triggerDirection:        triggerDirection,
            effectAccessoryIDString: accessoryID,
            effectActionRaw:         action,
            effectValue:             value,
            effectSceneName:         sceneName,
            status:                  .pending,
            snoozedUntil:            nil,
            dismissedAt:             nil,
            approvedAt:              nil,
            origin:                  .conversational
        )
        return opp
    }

    /// Memberwise init used by fromConversation (keeps all fields explicit).
    private init(
        id: UUID, createdAt: Date, lastUpdatedAt: Date,
        title: String, naturalLanguage: String, roomName: String,
        patternID: UUID, confidence: Double, observations: Int,
        firstObservedAt: Date, lastObservedAt: Date, avgTimeString: String?,
        timeDeviationMinutes: Int, dayTypeLabel: String, patternType: BehavioralPatternType,
        triggerType: String, triggerTime: String?, triggerWeekdaysRaw: String?,
        triggerSensorType: String?, triggerThreshold: Double?, triggerDirection: String?,
        effectAccessoryIDString: String?, effectActionRaw: String, effectValue: Double?,
        effectSceneName: String? = nil,
        status: OpportunityStatus, snoozedUntil: Date?, dismissedAt: Date?, approvedAt: Date?,
        origin: OpportunityOrigin
    ) {
        self.id                      = id
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
        self.patternType             = patternType
        self.triggerType             = triggerType
        self.triggerTime             = triggerTime
        self.triggerWeekdaysRaw      = triggerWeekdaysRaw
        self.triggerSensorType       = triggerSensorType
        self.triggerThreshold        = triggerThreshold
        self.triggerDirection        = triggerDirection
        self.effectAccessoryIDString = effectAccessoryIDString
        self.effectActionRaw         = effectActionRaw
        self.effectValue             = effectValue
        self.effectSceneName         = effectSceneName
        self.status                  = status
        self.snoozedUntil            = snoozedUntil
        self.dismissedAt             = dismissedAt
        self.approvedAt              = approvedAt
        self.origin                  = origin
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
