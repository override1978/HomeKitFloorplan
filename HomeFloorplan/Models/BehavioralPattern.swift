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
        case .emerging:       return String(localized: "behavioral.confidence.emerging",       defaultValue: "In osservazione")
        case .forming:        return String(localized: "behavioral.confidence.forming",        defaultValue: "In formazione")
        case .stable:         return String(localized: "behavioral.confidence.stable",         defaultValue: "Stabile")
        case .highConfidence: return String(localized: "behavioral.confidence.highConfidence", defaultValue: "Alta confidenza")
        case .decaying:       return String(localized: "behavioral.confidence.decaying",       defaultValue: "In diminuzione")
        case .dormant:        return String(localized: "behavioral.confidence.dormant",        defaultValue: "Dormiente")
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
/// Persisted via Codable in UserDefaults — no SwiftData schema migration needed.
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
    var validations:      Int          // subset of observations confirmed by following behavior
    var firstObservedAt:  Date
    var lastObservedAt:   Date
    var stabilityDays:    Int          // number of days the pattern has held

    // — Status —
    var status:      BehavioralPatternStatus
    var dismissedAt: Date?
    var approvedAt:  Date?

    // — Presentation —
    var naturalLanguageDescription: String

    // MARK: - Computed

    /// Multi-factor confidence score 0.0–0.97.
    var confidence: Double {
        guard observations >= 2 else { return 0 }
        let baseRate       = Double(validations) / Double(observations)
        let stabilityFactor = min(1.0, Double(stabilityDays) / 14.0)
        let daysSinceLast  = max(0, Calendar.current.dateComponents(
            [.day], from: lastObservedAt, to: Date()).day ?? 0)
        let recencyFactor  = exp(-max(0.0, Double(daysSinceLast) - 1.0) / 7.0)
        return min(0.97, baseRate * stabilityFactor * recencyFactor)
    }

    var tier: ConfidenceTier {
        let c = confidence
        let daysSinceLast = Calendar.current.dateComponents(
            [.day], from: lastObservedAt, to: Date()).day ?? 0
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

    /// Canonical key for merging duplicate detections.
    var deduplicationKey: String {
        "\(accessoryName):\(action.rawValue):\(dayType?.rawValue ?? "any"):\(patternType.rawValue)"
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
}
