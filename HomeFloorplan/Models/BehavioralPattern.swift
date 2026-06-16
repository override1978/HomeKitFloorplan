import Foundation

// MARK: - ConfidenceTier

enum ConfidenceTier: String, Codable {
    case emerging        // < 0.60, < 5 observations — not surfaced to user
    case forming         // 0.60–0.74
    case stable          // 0.75–0.89
    case highConfidence  // 0.90+
    case decaying        // no recent observations — confidence declining
    case dormant         // no observations for 30d+ — possibly seasonal

    var localizedLabel: String {
        switch self {
        case .emerging:       return String(localized: "behavioral.confidence.emerging",       defaultValue: "Observing")
        case .forming:        return String(localized: "behavioral.confidence.forming",        defaultValue: "Forming")
        case .stable:         return String(localized: "behavioral.confidence.stable",         defaultValue: "Stable")
        case .highConfidence: return String(localized: "behavioral.confidence.highConfidence", defaultValue: "High Confidence")
        case .decaying:       return String(localized: "behavioral.confidence.decaying",       defaultValue: "Decaying")
        case .dormant:        return String(localized: "behavioral.confidence.dormant",        defaultValue: "Dormant")
        }
    }

    var isVisible: Bool {
        switch self {
        case .forming, .stable, .highConfidence: return true
        default: return false
        }
    }
}

// MARK: - BehavioralPatternType

enum BehavioralPatternType: String, Codable {
    case temporal    // happens at a consistent time of day
    case sequential  // event B consistently follows event A
    case contextual  // when sensor condition → accessory action
    case scene       // scene activated at consistent time/context
    case lighting    // consistent brightness/color at a time of day
}

// MARK: - BehavioralPatternStatus

enum BehavioralPatternStatus: String, Codable {
    case active    // actively surfaced and available for suggestion
    case dismissed // user dismissed this pattern
    case approved  // user converted to an automation rule
    case decaying  // not observed recently
    case dormant   // not observed for 30d+, possibly seasonal
}

// MARK: - BehavioralPattern

/// A detected behavioral pattern with full confidence tracking.
/// Persisted via VersionedStore (JSON) in Application Support.
struct BehavioralPattern: Identifiable, Codable {
    var id: UUID

    var patternType:  BehavioralPatternType
    var detectedAt:   Date

    // — What happens —
    var accessoryName: String
    var accessoryID:   UUID?
    var roomName:      String
    var eventTypeRaw:  String
    var action:        BehavioralAction
    var numericValue:  Double?         // brightness 0–1 for dim actions

    // — Temporal trigger —
    var avgMinuteOfDay:       Int      // mean minute-of-day 0–1439
    var timeDeviationMinutes: Int      // std deviation in minutes (timing consistency)
    var weekdays:             [Int]    // Calendar weekday ints where pattern holds
    var dayType:              DayType?

    // — Sequential trigger (for .sequential patterns) —
    var causeSignature: String?        // signature of the triggering event
    var causeName:      String?        // human-readable name of the cause
    var avgGapSeconds:  Double?        // mean delay from cause to effect

    // — Confidence tracking —
    var observations:     Int          // total times the pattern was observed
    var validations:      Int          // retained for compatibility; not used in confidence
    var firstObservedAt:  Date
    var lastObservedAt:   Date
    var stabilityDays:    Int          // retained for compatibility; not used in confidence
    /// Distinct calendar days on which the pattern was observed.
    /// Nil on legacy persisted patterns — next analysis run fills this in.
    var distinctActiveDays: Int?

    // — Status —
    var status:      BehavioralPatternStatus
    var dismissedAt: Date?
    var approvedAt:  Date?

    // — Presentation —
    var naturalLanguageDescription: String

    // MARK: - Confidence (data-driven)

    /// Multi-factor confidence score 0.0–0.97.
    ///
    /// regularity   = distinctActiveDays / expectedActiveDays (fraction of eligible days observed)
    /// stability    = saturates at 14 days of data span (firstObservedAt → lastObservedAt)
    /// recency      = decays exponentially if the last event is more than 1 day old
    var confidence: Double {
        guard observations >= 2 else { return 0 }

        let calSpan = Calendar.current.dateComponents([.day], from: firstObservedAt, to: lastObservedAt).day ?? 0
        let dataSpanDays = Double(max(1, calSpan))
        let stabilityFactor = min(1.0, dataSpanDays / 14.0)

        let daysSinceLastEvent = max(0.0, -lastObservedAt.timeIntervalSinceNow / 86400)
        let recencyFactor = exp(-max(0.0, daysSinceLastEvent - 1.0) / 7.0)

        // regularity: actual active days vs expected days in the span
        // For legacy patterns without distinctActiveDays, use observations as lower-bound proxy
        let activeDays = distinctActiveDays ?? min(observations, max(1, Int(dataSpanDays)))
        let expected   = expectedActiveDays
        let regularity = Double(activeDays) / Double(max(1, expected))

        return min(0.97, regularity * stabilityFactor * recencyFactor)
    }

    /// Number of calendar days eligible for this pattern within its observed span.
    var expectedActiveDays: Int {
        var count    = 0
        let cal      = Calendar.current
        var current  = cal.startOfDay(for: firstObservedAt)
        let end      = lastObservedAt
        while current <= end {
            let weekday  = cal.component(.weekday, from: current)
            let isWeekend = weekday == 1 || weekday == 7
            let qualifies: Bool
            switch dayType {
            case .weekday: qualifies = !isWeekend
            case .weekend: qualifies = isWeekend
            case nil:      qualifies = true
            }
            if qualifies { count += 1 }
            current = cal.date(byAdding: .day, value: 1, to: current)!
        }
        return max(1, count)
    }

    var tier: ConfidenceTier {
        let c = confidence
        let daysSinceLast = max(0, -lastObservedAt.timeIntervalSinceNow / 86400)
        if daysSinceLast >= 30 { return .dormant }
        if daysSinceLast >= 7  { return .decaying }
        if c >= 0.90           { return .highConfidence }
        if c >= 0.75           { return .stable }
        if c >= 0.60           { return .forming }
        return .emerging
    }

    var confidenceLabel: String { "\(Int(confidence * 100))%" }

    var avgTimeString: String {
        let h = avgMinuteOfDay / 60
        let m = avgMinuteOfDay % 60
        return String(format: "%02d:%02d", h, m)
    }

    /// Always-current localized title, regenerated from structural data at read time.
    /// Use in UI instead of `naturalLanguageDescription` to avoid stale persisted English strings.
    /// `.scene` and `.contextual` fall back to `naturalLanguageDescription` (burst names via habitService).
    var localizedTitle: String {
        switch patternType {

        case .temporal, .lighting:
            let timeStr  = avgTimeString
            let dayLabel = dayType?.localizedLabel
                ?? String(localized: "behavioral.dayType.daily", defaultValue: "every day")
            switch action {
            case .on:
                return String(format: String(localized: "behavioral.pattern.temporal.on",
                                             defaultValue: "%1$@ turns on %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .off:
                return String(format: String(localized: "behavioral.pattern.temporal.off",
                                             defaultValue: "%1$@ turns off %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .dim:
                return String(format: String(localized: "behavioral.pattern.temporal.dim",
                                             defaultValue: "%1$@ dims %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .activate:
                return String(format: String(localized: "behavioral.pattern.temporal.activate",
                                             defaultValue: "%1$@ activates %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .lock:
                return String(format: String(localized: "behavioral.pattern.temporal.lock",
                                             defaultValue: "%1$@ locks %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .unlock:
                return String(format: String(localized: "behavioral.pattern.temporal.unlock",
                                             defaultValue: "%1$@ unlocks %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .open:
                return String(format: String(localized: "behavioral.pattern.temporal.open",
                                             defaultValue: "%1$@ opens %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            case .close:
                return String(format: String(localized: "behavioral.pattern.temporal.close",
                                             defaultValue: "%1$@ closes %2$@ at %3$@"),
                              accessoryName, dayLabel, timeStr)
            }

        case .sequential:
            let gapMins = max(1, Int((avgGapSeconds ?? 60) / 60))
            let cause   = causeName ?? accessoryName
            switch action {
            case .on:
                return String(format: String(localized: "behavioral.pattern.sequential.on",
                                             defaultValue: "After %1$@, %2$@ turns on within %3$d min"),
                              cause, accessoryName, gapMins)
            case .off:
                return String(format: String(localized: "behavioral.pattern.sequential.off",
                                             defaultValue: "After %1$@, %2$@ turns off within %3$d min"),
                              cause, accessoryName, gapMins)
            case .dim:
                return String(format: String(localized: "behavioral.pattern.sequential.dim",
                                             defaultValue: "After %1$@, %2$@ dims within %3$d min"),
                              cause, accessoryName, gapMins)
            case .activate:
                return String(format: String(localized: "behavioral.pattern.sequential.activate",
                                             defaultValue: "After %1$@, %2$@ activates within %3$d min"),
                              cause, accessoryName, gapMins)
            case .lock, .unlock, .open, .close:
                return String(format: String(localized: "behavioral.pattern.sequential.default",
                                             defaultValue: "When %1$@ is used, %2$@ changes within %3$d min"),
                              cause, accessoryName, gapMins)
            }

        case .scene, .contextual:
            return naturalLanguageDescription
        }
    }

    /// Canonical key for merging duplicate detections.
    var deduplicationKey: String {
        if patternType == .sequential {
            if let cs = causeSignature, cs.hasPrefix("burst_cluster:") {
                // Burst-caused sequential: stable cluster ID + effect accessory + action + dayType.
                let effectID = accessoryID?.uuidString ?? accessoryName
                return "seq_burst:\(cs):\(effectID):\(action.rawValue):\(dayType?.rawValue ?? "any")"
            }
            // Regular sequential: causeName + cause action (parsed from signature) + effect + action.
            let causeAct  = causeSignature?.split(separator: ":").last.map(String.init) ?? "?"
            let effectID  = accessoryID?.uuidString ?? accessoryName
            return "seq:\(causeName ?? "?"):\(causeAct):\(effectID):\(action.rawValue):\(dayType?.rawValue ?? "any")"
        }
        if patternType == .scene, let sig = causeSignature {
            // Cluster-derived scene patterns: stable cluster ID + dayType.
            return "\(sig):\(dayType?.rawValue ?? "any")"
        }
        return "\(accessoryName):\(action.rawValue):\(dayType?.rawValue ?? "any"):\(patternType.rawValue)"
    }

    var sfSymbol: String {
        switch patternType {
        case .scene:      return "play.circle.fill"
        case .sequential: return "arrow.forward.circle.fill"
        case .contextual: return "sensor.tag.radiowaves.forward.fill"
        case .lighting:   return "lightbulb.2.fill"
        case .temporal:
            switch action {
            case .on, .unlock, .open: return "lightbulb.fill"
            case .off, .lock, .close: return "moon.fill"
            case .dim:                return "light.min"
            case .activate:           return "wand.and.sparkles"
            }
        }
    }

    // MARK: - Codable (backward compatible: distinctActiveDays defaults to nil)

    enum CodingKeys: String, CodingKey {
        case id, patternType, detectedAt, accessoryName, accessoryID, roomName,
             eventTypeRaw, action, numericValue, avgMinuteOfDay, timeDeviationMinutes,
             weekdays, dayType, causeSignature, causeName, avgGapSeconds,
             observations, validations, firstObservedAt, lastObservedAt, stabilityDays,
             distinctActiveDays,
             status, dismissedAt, approvedAt, naturalLanguageDescription
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                        = try c.decode(UUID.self,                    forKey: .id)
        patternType               = try c.decode(BehavioralPatternType.self,   forKey: .patternType)
        detectedAt                = try c.decode(Date.self,                    forKey: .detectedAt)
        accessoryName             = try c.decode(String.self,                  forKey: .accessoryName)
        accessoryID               = try c.decodeIfPresent(UUID.self,           forKey: .accessoryID)
        roomName                  = try c.decode(String.self,                  forKey: .roomName)
        eventTypeRaw              = try c.decode(String.self,                  forKey: .eventTypeRaw)
        action                    = try c.decode(BehavioralAction.self,        forKey: .action)
        numericValue              = try c.decodeIfPresent(Double.self,         forKey: .numericValue)
        avgMinuteOfDay            = try c.decode(Int.self,                     forKey: .avgMinuteOfDay)
        timeDeviationMinutes      = try c.decode(Int.self,                     forKey: .timeDeviationMinutes)
        weekdays                  = try c.decode([Int].self,                   forKey: .weekdays)
        dayType                   = try c.decodeIfPresent(DayType.self,        forKey: .dayType)
        causeSignature            = try c.decodeIfPresent(String.self,         forKey: .causeSignature)
        causeName                 = try c.decodeIfPresent(String.self,         forKey: .causeName)
        avgGapSeconds             = try c.decodeIfPresent(Double.self,         forKey: .avgGapSeconds)
        observations              = try c.decode(Int.self,                     forKey: .observations)
        validations               = try c.decode(Int.self,                     forKey: .validations)
        firstObservedAt           = try c.decode(Date.self,                    forKey: .firstObservedAt)
        lastObservedAt            = try c.decode(Date.self,                    forKey: .lastObservedAt)
        stabilityDays             = try c.decode(Int.self,                     forKey: .stabilityDays)
        distinctActiveDays        = try c.decodeIfPresent(Int.self,            forKey: .distinctActiveDays)
        status                    = try c.decode(BehavioralPatternStatus.self, forKey: .status)
        dismissedAt               = try c.decodeIfPresent(Date.self,           forKey: .dismissedAt)
        approvedAt                = try c.decodeIfPresent(Date.self,           forKey: .approvedAt)
        naturalLanguageDescription = try c.decode(String.self,                 forKey: .naturalLanguageDescription)
    }
}

// MARK: - Memberwise Init (used by PatternDetectionEngine)

extension BehavioralPattern {
    init(
        id:                         UUID,
        patternType:                BehavioralPatternType,
        detectedAt:                 Date,
        accessoryName:              String,
        accessoryID:                UUID?,
        roomName:                   String,
        eventTypeRaw:               String,
        action:                     BehavioralAction,
        numericValue:               Double?,
        avgMinuteOfDay:             Int,
        timeDeviationMinutes:       Int,
        weekdays:                   [Int],
        dayType:                    DayType?,
        causeSignature:             String?,
        causeName:                  String?,
        avgGapSeconds:              Double?,
        observations:               Int,
        validations:                Int,
        firstObservedAt:            Date,
        lastObservedAt:             Date,
        stabilityDays:              Int,
        distinctActiveDays:         Int? = nil,
        status:                     BehavioralPatternStatus,
        dismissedAt:                Date?,
        approvedAt:                 Date?,
        naturalLanguageDescription: String
    ) {
        self.id                         = id
        self.patternType                = patternType
        self.detectedAt                 = detectedAt
        self.accessoryName              = accessoryName
        self.accessoryID                = accessoryID
        self.roomName                   = roomName
        self.eventTypeRaw               = eventTypeRaw
        self.action                     = action
        self.numericValue               = numericValue
        self.avgMinuteOfDay             = avgMinuteOfDay
        self.timeDeviationMinutes       = timeDeviationMinutes
        self.weekdays                   = weekdays
        self.dayType                    = dayType
        self.causeSignature             = causeSignature
        self.causeName                  = causeName
        self.avgGapSeconds              = avgGapSeconds
        self.observations               = observations
        self.validations                = validations
        self.firstObservedAt            = firstObservedAt
        self.lastObservedAt             = lastObservedAt
        self.stabilityDays              = stabilityDays
        self.distinctActiveDays         = distinctActiveDays
        self.status                     = status
        self.dismissedAt                = dismissedAt
        self.approvedAt                 = approvedAt
        self.naturalLanguageDescription = naturalLanguageDescription
    }
}
