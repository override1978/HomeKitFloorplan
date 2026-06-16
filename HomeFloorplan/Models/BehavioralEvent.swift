import Foundation

// MARK: - TimeOfDay

enum TimeOfDay: String, Codable, CaseIterable {
    case earlyMorning = "earlyMorning"  // 5–8
    case morning      = "morning"       // 8–12
    case afternoon    = "afternoon"     // 12–17
    case evening      = "evening"       // 17–21
    case night        = "night"         // 21–5

    init(hour: Int) {
        switch hour {
        case 5..<8:   self = .earlyMorning
        case 8..<12:  self = .morning
        case 12..<17: self = .afternoon
        case 17..<21: self = .evening
        default:      self = .night
        }
    }

    var localizedLabel: String {
        switch self {
        case .earlyMorning: return String(localized: "behavioral.timeOfDay.earlyMorning", defaultValue: "Early Morning")
        case .morning:      return String(localized: "behavioral.timeOfDay.morning",      defaultValue: "Morning")
        case .afternoon:    return String(localized: "behavioral.timeOfDay.afternoon",    defaultValue: "Afternoon")
        case .evening:      return String(localized: "behavioral.timeOfDay.evening",      defaultValue: "Evening")
        case .night:        return String(localized: "behavioral.timeOfDay.night",        defaultValue: "Night")
        }
    }
}

// MARK: - DayType

enum DayType: String, Codable {
    case weekday = "weekday"
    case weekend = "weekend"

    /// Calendar weekday: 1 = Sunday, 7 = Saturday
    init(weekday: Int) {
        self = (weekday == 1 || weekday == 7) ? .weekend : .weekday
    }

    var localizedLabel: String {
        switch self {
        case .weekday: return String(localized: "behavioral.dayType.weekday", defaultValue: "on weekdays")
        case .weekend: return String(localized: "behavioral.dayType.weekend", defaultValue: "on weekends")
        }
    }
}

// MARK: - BehavioralAction

enum BehavioralAction: String, Codable {
    case on       = "on"
    case off      = "off"
    case dim      = "dim"
    case activate = "activate"
    case lock     = "lock"
    case unlock   = "unlock"
    case open     = "open"
    case close    = "close"
}

// MARK: - BehavioralEventSource

enum BehavioralEventSource: String, Codable {
    case accessory = "accessory"
    case scene     = "scene"
    case rule      = "rule"
}

// MARK: - BehavioralEventContext

struct BehavioralEventContext: Codable, Equatable {
    let timeOfDay:   TimeOfDay
    let dayType:     DayType
    let hourOfDay:   Int
    let minuteOfDay: Int   // 0–1439
    let weekday:     Int   // 1–7, Calendar convention
}

// MARK: - BehavioralEvent

/// Normalized, context-enriched representation of a raw home event.
/// Produced by BehavioralEventPreprocessor from AccessoryEvent / ActivityEvent.
struct BehavioralEvent: Identifiable, Codable {
    let id:            UUID
    let timestamp:     Date
    let source:        BehavioralEventSource
    let accessoryID:   UUID?
    let accessoryName: String
    let roomName:      String
    let eventTypeRaw:  String     // "light", "blind", "scene", "burst", …
    let action:        BehavioralAction
    let numericValue:  Double?    // brightness 0–1, or other scalar

    let context: BehavioralEventContext

    /// Stable cluster ID for burst synthetic events (set by PatternDetectionEngine).
    /// Nil for raw accessory/scene events.
    var groupingKey: String? = nil

    /// Stable key for correlation pairing and deduplication.
    var signature: String {
        "\(eventTypeRaw):\(accessoryName):\(action.rawValue)"
    }

    var minuteOfDay: Int { context.minuteOfDay }
}

// MARK: - BehavioralEventPreprocessor

enum BehavioralEventPreprocessor {

    static func convert(_ event: AccessoryEvent) -> BehavioralEvent {
        let cal     = Calendar.current
        let hour    = cal.component(.hour,    from: event.timestamp)
        let minute  = cal.component(.minute,  from: event.timestamp)
        let weekday = cal.component(.weekday, from: event.timestamp)

        let action: BehavioralAction
        if let brightness = event.brightness, event.state {
            action = brightness < 0.95 ? .dim : .on
        } else {
            action = event.state ? .on : .off
        }

        let ctx = BehavioralEventContext(
            timeOfDay:   TimeOfDay(hour: hour),
            dayType:     DayType(weekday: weekday),
            hourOfDay:   hour,
            minuteOfDay: hour * 60 + minute,
            weekday:     weekday
        )
        return BehavioralEvent(
            id:            event.id,
            timestamp:     event.timestamp,
            source:        .accessory,
            accessoryID:   event.accessoryID,
            accessoryName: event.accessoryName,
            roomName:      event.roomName ?? "",
            eventTypeRaw:  event.eventType,
            action:        action,
            numericValue:  event.brightness,
            context:       ctx
        )
    }

    static func convert(_ event: ActivityEvent) -> BehavioralEvent {
        let cal     = Calendar.current
        let hour    = cal.component(.hour,    from: event.timestamp)
        let minute  = cal.component(.minute,  from: event.timestamp)
        let weekday = cal.component(.weekday, from: event.timestamp)

        let ctx = BehavioralEventContext(
            timeOfDay:   TimeOfDay(hour: hour),
            dayType:     DayType(weekday: weekday),
            hourOfDay:   hour,
            minuteOfDay: hour * 60 + minute,
            weekday:     weekday
        )
        return BehavioralEvent(
            id:            event.id,
            timestamp:     event.timestamp,
            source:        .scene,
            accessoryID:   nil,
            accessoryName: event.title,
            roomName:      event.roomName ?? "",
            eventTypeRaw:  "scene",
            action:        .activate,
            numericValue:  nil,
            context:       ctx
        )
    }
}
