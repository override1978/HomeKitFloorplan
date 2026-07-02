import Foundation

@MainActor
enum HomeStateIntervalBuilder {
    struct Configuration {
        var eventLimit: Int = 300
        var outputLimit: Int = 120
        var includeMomentaryMotion: Bool = false
    }

    static func build(
        from accessoryEvents: [AccessoryEvent],
        configuration: Configuration? = nil
    ) -> [HomeStateInterval] {
        let configuration = configuration ?? Configuration()
        let events = accessoryEvents
            .prefix(configuration.eventLimit)
            .filter { shouldBuildInterval(for: $0, configuration: configuration) }
            .sorted { $0.timestamp < $1.timestamp }

        var activeByKey: [String: AccessoryEvent] = [:]
        var intervals: [HomeStateInterval] = []

        for event in events {
            let key = intervalKey(for: event)
            let signalType = signalType(for: event)
            if startsInterval(event, signalType: signalType) {
                activeByKey[key] = event
            } else if endsInterval(event, signalType: signalType),
                      let start = activeByKey.removeValue(forKey: key) {
                intervals.append(makeInterval(start: start, end: event))
            }
        }

        for start in activeByKey.values {
            intervals.append(makeInterval(start: start, end: nil))
        }

        return Array(intervals.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
            return lhs.startedAt > rhs.startedAt
        }.prefix(configuration.outputLimit))
    }

    private static func shouldBuildInterval(for event: AccessoryEvent, configuration: Configuration) -> Bool {
        guard event.eventType != AccessoryEventType.blind.rawValue else {
            return false
        }

        switch signalType(for: event) {
        case .contact, .power, .active:
            return true
        case .motion:
            return configuration.includeMomentaryMotion
        default:
            return false
        }
    }

    private static func startsInterval(_ event: AccessoryEvent, signalType: HomeSignalType) -> Bool {
        switch signalType {
        case .contact:
            // AccessoryEventStore maps HomeKit contact state as true = closed, false = open.
            return !event.state
        case .power, .active, .motion:
            return event.state
        default:
            return false
        }
    }

    private static func endsInterval(_ event: AccessoryEvent, signalType: HomeSignalType) -> Bool {
        switch signalType {
        case .contact:
            return event.state
        case .power, .active, .motion:
            return !event.state
        default:
            return false
        }
    }

    private static func makeInterval(start: AccessoryEvent, end: AccessoryEvent?) -> HomeStateInterval {
        let signal = HomeSignalEventMapper.map(start)
        let sourceEventIDs = [start.id] + (end.map { [$0.id] } ?? [])
        return HomeStateInterval(
            entityID: start.accessoryID.uuidString,
            entityName: start.accessoryName,
            roomID: start.roomID?.uuidString,
            roomName: start.roomName,
            signalType: signal.signalType,
            stateRaw: stateRaw(for: signal.signalType, eventType: start.eventType),
            startedAt: start.timestamp,
            endedAt: end?.timestamp,
            sourceEventIDs: sourceEventIDs,
            confidence: end == nil ? 0.85 : 1.0
        )
    }

    private static func stateRaw(for signalType: HomeSignalType, eventType: String) -> String {
        switch eventType {
        case AccessoryEventType.thermostat.rawValue:
            return "heating"
        case AccessoryEventType.blind.rawValue:
            return "positioned"
        case AccessoryEventType.fan.rawValue:
            return "running"
        case AccessoryEventType.airPurifier.rawValue:
            return "purifying"
        case AccessoryEventType.humidifier.rawValue:
            return "humidifying"
        default:
            break
        }

        switch signalType {
        case .contact:
            return "open"
        case .power:
            return "on"
        case .active:
            return "active"
        case .motion:
            return "detected"
        default:
            return "true"
        }
    }

    private static func intervalKey(for event: AccessoryEvent) -> String {
        "\(event.accessoryID.uuidString)|\(event.eventType)"
    }

    private static func signalType(for event: AccessoryEvent) -> HomeSignalType {
        HomeSignalEventMapper.map(event).signalType
    }
}
