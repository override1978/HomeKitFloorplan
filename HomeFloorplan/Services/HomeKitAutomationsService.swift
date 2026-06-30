import Foundation
import HomeKit
import CoreLocation
import Observation

/// Tipo di trigger di un'automazione HomeKit.
enum AutomationTriggerType: String {
    case timer      = "Timer"
    case event      = "Evento"
    case location   = "Posizione"
    case presence   = "Presenza"
    case time       = "Orario"
    case unknown    = "Sconosciuto"

    var localizedName: String {
        switch self {
        case .timer:    return String(localized: "automation.type.timer", defaultValue: "Timer")
        case .event:    return String(localized: "automation.type.event", defaultValue: "Event")
        case .location: return String(localized: "automation.type.location", defaultValue: "Location")
        case .presence: return String(localized: "automation.type.presence", defaultValue: "Presence")
        case .time:     return String(localized: "automation.type.time", defaultValue: "Time")
        case .unknown:  return String(localized: "automation.type.unknown", defaultValue: "Unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .timer:    return "clock"
        case .event:    return "bolt"
        case .location: return "location.fill"
        case .presence: return "person.fill"
        case .time:     return "calendar"
        case .unknown:  return "questionmark.circle"
        }
    }
}

/// Wrapper UI per un'automazione HomeKit (`HMTrigger`).
struct AutomationItem: Identifiable {
    let trigger: HMTrigger

    var id: String { trigger.uniqueIdentifier.uuidString }
    var name: String { trigger.name }
    var isEnabled: Bool { trigger.isEnabled }
    var triggerType: AutomationTriggerType
    var summary: String
    var conditionSummary: String?
    var conditionSummaries: [String]
    var actionSetNames: [String]
    var actionCount: Int { trigger.actionSets.reduce(0) { $0 + $1.actions.count } }

    init(trigger: HMTrigger) {
        self.trigger = trigger
        self.triggerType = Self.classifyTrigger(trigger)
        self.summary = Self.describeTrigger(trigger)
        self.conditionSummaries = Self.describeConditions(trigger)
        self.conditionSummary = conditionSummaries.isEmpty ? nil : conditionSummaries.joined(separator: " • ")
        self.actionSetNames = trigger.actionSets.map { actionSet in
            SceneItem(actionSet: actionSet).name
        }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    // MARK: - Classificazione e descrizione trigger

    private static func classifyTrigger(_ trigger: HMTrigger) -> AutomationTriggerType {
        if trigger is HMTimerTrigger {
            return .timer
        }
        guard let eventTrigger = trigger as? HMEventTrigger else {
            return .unknown
        }
        // HMEventTrigger può contenere eventi di tipo diverso
        for event in eventTrigger.events {
            if event is HMLocationEvent { return .location }
            if event is HMPresenceEvent { return .presence }
            if event is HMSignificantTimeEvent || event is HMCalendarEvent { return .time }
            if event is HMCharacteristicEvent<NSCopying> { return .event }
        }
        return .event
    }

    private static func describeTrigger(_ trigger: HMTrigger) -> String {
        if let timer = trigger as? HMTimerTrigger {
            return describeTimerTrigger(timer)
        }
        if let event = trigger as? HMEventTrigger {
            return describeEventTrigger(event)
        }
        return String(localized: "automation.description.custom", defaultValue: "Custom Automation")
    }

    private static func describeTimerTrigger(_ timer: HMTimerTrigger) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let timeStr = formatter.string(from: timer.fireDate)

        if let recurrence = timer.recurrence {
            var components: [String] = []
            // Controlla i giorni della settimana
            if recurrence.weekOfYear != nil {
                components.append(String(localized: "automation.recurrence.weekly", defaultValue: "Weekly"))
            } else if let _ = recurrence.value(for: .day) {
                components.append(String(localized: "automation.recurrence.daily", defaultValue: "Daily"))
            }
            if components.isEmpty {
                // Riprova con weekday
                let days = [
                    String(localized: "weekday.sun", defaultValue: "Sun"),
                    String(localized: "weekday.mon", defaultValue: "Mon"),
                    String(localized: "weekday.tue", defaultValue: "Tue"),
                    String(localized: "weekday.wed", defaultValue: "Wed"),
                    String(localized: "weekday.thu", defaultValue: "Thu"),
                    String(localized: "weekday.fri", defaultValue: "Fri"),
                    String(localized: "weekday.sat", defaultValue: "Sat")
                ]
                if let wd = recurrence.weekday, wd >= 1, wd <= 7 {
                    components.append(days[wd - 1])
                }
            }
            let recStr = components.isEmpty
                ? String(localized: "automation.recurrence.recurring", defaultValue: "Recurring")
                : components.joined(separator: ", ")
            let atStr = String(localized: "automation.timer.at", defaultValue: "at")
            return "\(recStr) \(atStr) \(timeStr)"
        }
        let onceStr = String(localized: "automation.timer.once", defaultValue: "Once at")
        return "\(onceStr) \(timeStr)"
    }

    private static func describeEventTrigger(_ trigger: HMEventTrigger) -> String {
        var parts: [String] = []
        for event in trigger.events {
            if event is HMSignificantTimeEvent {
                parts.append(String(localized: "automation.event.sunsetSunrise", defaultValue: "Sunset / Sunrise"))
            } else if let cal = event as? HMCalendarEvent {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                parts.append(formatter.string(from: cal.fireDateComponents.date ?? Date()))
            } else if event is HMLocationEvent {
                parts.append(String(localized: "automation.event.location", defaultValue: "Location"))
            } else if let pres = event as? HMPresenceEvent {
                switch pres.presenceEventType {
                case .everyEntry: parts.append(String(localized: "automation.event.presence.everyEntry", defaultValue: "Every arrival home"))
                case .everyExit:  parts.append(String(localized: "automation.event.presence.everyExit", defaultValue: "Every departure home"))
                case .firstEntry: parts.append(String(localized: "automation.event.presence.firstEntry", defaultValue: "First arrival home"))
                case .lastExit:   parts.append(String(localized: "automation.event.presence.lastExit", defaultValue: "Last departure home"))
                @unknown default: parts.append(String(localized: "automation.event.presence.other", defaultValue: "Presence"))
                }
            } else if let charEvent = event as? HMCharacteristicEvent<NSCopying> {
                let accName = charEvent.characteristic.service?.accessory?.name ?? String(localized: "automation.event.accessory.fallback", defaultValue: "Accessory")
                let eventPrefix = String(localized: "automation.event.characteristic.prefix", defaultValue: "Event on")
                parts.append("\(eventPrefix) \(accName)")
            }
        }
        return parts.isEmpty
            ? String(localized: "automation.event.description.fallback", defaultValue: "Event-based Automation")
            : parts.joined(separator: " • ")
    }

    private static func describeConditions(_ trigger: HMTrigger) -> [String] {
        guard let eventTrigger = trigger as? HMEventTrigger,
              let predicate = eventTrigger.predicate else {
            return []
        }

        let triggerCharacteristicIDs = Set(eventTrigger.events.compactMap { event -> String? in
            guard let characteristicEvent = event as? HMCharacteristicEvent<NSCopying> else { return nil }
            return characteristicEvent.characteristic.uniqueIdentifier.uuidString
        })

        let summaries = describePredicate(predicate, triggerCharacteristicIDs: triggerCharacteristicIDs)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if summaries.isEmpty {
            return [String(localized: "automation.conditions.configured", defaultValue: "HomeKit conditions configured")]
        }
        return summaries
    }

    private static func describePredicate(_ predicate: NSPredicate, triggerCharacteristicIDs: Set<String>) -> [String] {
        if let compound = predicate as? NSCompoundPredicate {
            let parts = compound.subpredicates.flatMap { subpredicate -> [String] in
                guard let predicate = subpredicate as? NSPredicate else { return [] }
                return describePredicate(predicate, triggerCharacteristicIDs: triggerCharacteristicIDs)
            }

            guard compound.compoundPredicateType == .or, parts.count > 1 else {
                return parts
            }

            return [parts.joined(separator: " OR ")]
        }

        if let comparison = predicate as? NSComparisonPredicate,
           let summary = describeComparisonPredicate(comparison, triggerCharacteristicIDs: triggerCharacteristicIDs) {
            return [summary]
        }

        return [String(localized: "automation.conditions.configured", defaultValue: "HomeKit conditions configured")]
    }

    nonisolated private static func describeComparisonPredicate(
        _ predicate: NSComparisonPredicate,
        triggerCharacteristicIDs: Set<String>
    ) -> String? {
        let expressions = [predicate.leftExpression, predicate.rightExpression]
        let constantValues = expressions.compactMap(constantExpressionValue)
        let characteristic = constantValues.compactMap { $0 as? HMCharacteristic }.first

        if let characteristic,
           triggerCharacteristicIDs.contains(characteristic.uniqueIdentifier.uuidString) {
            return nil
        }

        let value = constantValues.first { !($0 is HMCharacteristic) }
        let characteristicName = characteristic?.metadata?.manufacturerDescription ??
            characteristic?.characteristicType.components(separatedBy: ".").last ??
            String(localized: "automation.condition.characteristic", defaultValue: "Characteristic")
        let accessoryName = characteristic?.service?.accessory?.name
        let operatorText = comparisonOperatorText(predicate.predicateOperatorType)
        let valueText = value.map(describePredicateValue) ??
            String(localized: "automation.condition.value.current", defaultValue: "current value")

        if let accessoryName {
            return "\(accessoryName) - \(characteristicName) \(operatorText) \(valueText)"
        }
        return "\(characteristicName) \(operatorText) \(valueText)"
    }

    nonisolated private static func constantExpressionValue(_ expression: NSExpression) -> Any? {
        guard expression.expressionType == .constantValue else {
            return nil
        }
        return expression.constantValue
    }

    nonisolated private static func comparisonOperatorText(_ operatorType: NSComparisonPredicate.Operator) -> String {
        switch operatorType {
        case .lessThan:
            return String(localized: "automation.condition.operator.lessThan", defaultValue: "below")
        case .lessThanOrEqualTo:
            return String(localized: "automation.condition.operator.lessThanOrEqual", defaultValue: "at most")
        case .greaterThan:
            return String(localized: "automation.condition.operator.greaterThan", defaultValue: "above")
        case .greaterThanOrEqualTo:
            return String(localized: "automation.condition.operator.greaterThanOrEqual", defaultValue: "at least")
        case .equalTo:
            return String(localized: "automation.condition.operator.equal", defaultValue: "is")
        case .notEqualTo:
            return String(localized: "automation.condition.operator.notEqual", defaultValue: "is not")
        default:
            return String(localized: "automation.condition.operator.matches", defaultValue: "matches")
        }
    }

    nonisolated private static func describePredicateValue(_ value: Any) -> String {
        if let boolValue = value as? Bool {
            return boolValue
                ? String(localized: "automation.condition.value.on", defaultValue: "On")
                : String(localized: "automation.condition.value.off", defaultValue: "Off")
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let string = value as? String {
            return string
        }
        return "\(value)"
    }
}

enum AutomationScheduleKind: String, CaseIterable, Identifiable {
    case fixedTime
    case sunrise
    case sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixedTime:
            return String(localized: "automation.schedule.fixedTime", defaultValue: "Time")
        case .sunrise:
            return String(localized: "automation.schedule.sunrise", defaultValue: "Sunrise")
        case .sunset:
            return String(localized: "automation.schedule.sunset", defaultValue: "Sunset")
        }
    }

    var iconName: String {
        switch self {
        case .fixedTime: return "clock"
        case .sunrise: return "sunrise.fill"
        case .sunset: return "sunset.fill"
        }
    }
}

enum AutomationScheduleWeekday: Int, CaseIterable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var shortTitle: String {
        switch self {
        case .sunday: return String(localized: "weekday.sun", defaultValue: "Sun")
        case .monday: return String(localized: "weekday.mon", defaultValue: "Mon")
        case .tuesday: return String(localized: "weekday.tue", defaultValue: "Tue")
        case .wednesday: return String(localized: "weekday.wed", defaultValue: "Wed")
        case .thursday: return String(localized: "weekday.thu", defaultValue: "Thu")
        case .friday: return String(localized: "weekday.fri", defaultValue: "Fri")
        case .saturday: return String(localized: "weekday.sat", defaultValue: "Sat")
        }
    }
}

struct AutomationScheduleTrigger {
    var kind: AutomationScheduleKind = .fixedTime
    var time: Date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    var offsetMinutes: Int = 0
    var weekdays: Set<AutomationScheduleWeekday> = Set(AutomationScheduleWeekday.allCases)

    var summary: String {
        let timing: String
        switch kind {
        case .fixedTime:
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            timing = String(format: String(localized: "automation.schedule.summary.time", defaultValue: "At %@"), formatter.string(from: time))
        case .sunrise, .sunset:
            timing = "\(kind.title) \(offsetSummary)"
        }

        return "\(timing) - \(daysSummary)"
    }

    var offsetSummary: String {
        if offsetMinutes == 0 {
            return String(localized: "automation.schedule.offset.none", defaultValue: "No offset")
        }

        let absolute = abs(offsetMinutes)
        if offsetMinutes < 0 {
            return String(format: String(localized: "automation.schedule.offset.before", defaultValue: "%d min before"), absolute)
        }
        return String(format: String(localized: "automation.schedule.offset.after", defaultValue: "%d min after"), absolute)
    }

    private var daysSummary: String {
        if weekdays.count == AutomationScheduleWeekday.allCases.count {
            return String(localized: "automation.schedule.days.everyDay", defaultValue: "Every day")
        }
        if weekdays == [.monday, .tuesday, .wednesday, .thursday, .friday] {
            return String(localized: "automation.schedule.days.weekdays", defaultValue: "Weekdays")
        }
        if weekdays == [.saturday, .sunday] {
            return String(localized: "automation.schedule.days.weekend", defaultValue: "Weekend")
        }
        return AutomationScheduleWeekday.allCases
            .filter { weekdays.contains($0) }
            .map(\.shortTitle)
            .joined(separator: ", ")
    }
}

enum AutomationTimeConditionKind: String, CaseIterable, Identifiable {
    case fixedTime
    case sunrise
    case sunset

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixedTime:
            return String(localized: "automation.schedule.fixedTime", defaultValue: "Time")
        case .sunrise:
            return String(localized: "automation.schedule.sunrise", defaultValue: "Sunrise")
        case .sunset:
            return String(localized: "automation.schedule.sunset", defaultValue: "Sunset")
        }
    }

    var iconName: String {
        switch self {
        case .fixedTime: return "clock"
        case .sunrise: return "sunrise.fill"
        case .sunset: return "sunset.fill"
        }
    }
}

enum AutomationTimeConditionRelation: String, CaseIterable, Identifiable {
    case after
    case before
    case between

    var id: String { rawValue }

    var title: String {
        switch self {
        case .after:
            return String(localized: "automation.timeCondition.after", defaultValue: "After")
        case .before:
            return String(localized: "automation.timeCondition.before", defaultValue: "Before")
        case .between:
            return String(localized: "automation.timeCondition.between", defaultValue: "Between")
        }
    }
}

struct AutomationTimeCondition: Identifiable {
    let id = UUID()
    var kind: AutomationTimeConditionKind = .fixedTime
    var relation: AutomationTimeConditionRelation = .after
    var time: Date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    var offsetMinutes: Int = 0
    var endKind: AutomationTimeConditionKind = .fixedTime
    var endTime: Date = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
    var endOffsetMinutes: Int = 0

    var summary: String {
        switch kind {
        case .fixedTime:
            if relation == .between {
                return String(
                    format: String(localized: "automation.timeCondition.summary.between", defaultValue: "Between %@ and %@"),
                    boundarySummary(kind: kind, time: time, offsetMinutes: offsetMinutes),
                    boundarySummary(kind: endKind, time: endTime, offsetMinutes: endOffsetMinutes)
                )
            }
            return "\(relation.title) \(boundarySummary(kind: kind, time: time, offsetMinutes: offsetMinutes))"
        case .sunrise, .sunset:
            if relation == .between {
                return String(
                    format: String(localized: "automation.timeCondition.summary.between", defaultValue: "Between %@ and %@"),
                    boundarySummary(kind: kind, time: time, offsetMinutes: offsetMinutes),
                    boundarySummary(kind: endKind, time: endTime, offsetMinutes: endOffsetMinutes)
                )
            }
            return "\(relation.title) \(kind.title) \(offsetSummary)"
        }
    }

    var offsetSummary: String {
        if offsetMinutes == 0 {
            return String(localized: "automation.schedule.offset.none", defaultValue: "No offset")
        }

        let absolute = abs(offsetMinutes)
        if offsetMinutes < 0 {
            return String(format: String(localized: "automation.schedule.offset.before", defaultValue: "%d min before"), absolute)
        }
        return String(format: String(localized: "automation.schedule.offset.after", defaultValue: "%d min after"), absolute)
    }

    private func boundarySummary(
        kind: AutomationTimeConditionKind,
        time: Date,
        offsetMinutes: Int
    ) -> String {
        switch kind {
        case .fixedTime:
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return formatter.string(from: time)
        case .sunrise, .sunset:
            let offset = Self.offsetSummary(for: offsetMinutes)
            return "\(kind.title) \(offset)"
        }
    }

    private static func offsetSummary(for offsetMinutes: Int) -> String {
        if offsetMinutes == 0 {
            return String(localized: "automation.schedule.offset.none", defaultValue: "No offset")
        }

        let absolute = abs(offsetMinutes)
        if offsetMinutes < 0 {
            return String(format: String(localized: "automation.schedule.offset.before", defaultValue: "%d min before"), absolute)
        }
        return String(format: String(localized: "automation.schedule.offset.after", defaultValue: "%d min after"), absolute)
    }
}

enum AutomationPresenceUserScope: String, CaseIterable, Identifiable {
    case currentUser
    case homeUsers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .currentUser:
            return String(localized: "automation.presence.user.current", defaultValue: "Me")
        case .homeUsers:
            return String(localized: "automation.presence.user.home", defaultValue: "Anyone")
        }
    }

    var homeKitValue: HMPresenceEventUserType {
        switch self {
        case .currentUser:
            return .currentUser
        case .homeUsers:
            return .homeUsers
        }
    }
}

enum AutomationPresenceTriggerKind: String, CaseIterable, Identifiable {
    case everyEntry
    case everyExit
    case firstEntry
    case lastExit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everyEntry:
            return String(localized: "automation.presence.trigger.everyEntry", defaultValue: "Arrives home")
        case .everyExit:
            return String(localized: "automation.presence.trigger.everyExit", defaultValue: "Leaves home")
        case .firstEntry:
            return String(localized: "automation.presence.trigger.firstEntry", defaultValue: "First person arrives")
        case .lastExit:
            return String(localized: "automation.presence.trigger.lastExit", defaultValue: "Last person leaves")
        }
    }

    var iconName: String {
        switch self {
        case .everyEntry, .firstEntry:
            return "figure.walk.arrival"
        case .everyExit, .lastExit:
            return "figure.walk.departure"
        }
    }

    var homeKitValue: HMPresenceEventType {
        switch self {
        case .everyEntry:
            return .everyEntry
        case .everyExit:
            return .everyExit
        case .firstEntry:
            return .firstEntry
        case .lastExit:
            return .lastExit
        }
    }
}

struct AutomationPresenceTrigger {
    var kind: AutomationPresenceTriggerKind = .everyEntry
    var userScope: AutomationPresenceUserScope = .currentUser

    var summary: String {
        "\(kind.title) - \(userScope.title)"
    }
}

enum AutomationPresenceConditionKind: String, CaseIterable, Identifiable {
    case atHome
    case notAtHome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .atHome:
            return String(localized: "automation.presence.condition.atHome", defaultValue: "At home")
        case .notAtHome:
            return String(localized: "automation.presence.condition.notAtHome", defaultValue: "Not at home")
        }
    }

    var iconName: String {
        switch self {
        case .atHome:
            return "house.fill"
        case .notAtHome:
            return "house.slash.fill"
        }
    }

    var homeKitValue: HMPresenceEventType {
        switch self {
        case .atHome:
            return .atHome
        case .notAtHome:
            return .notAtHome
        }
    }
}

struct AutomationPresenceCondition: Identifiable {
    let id = UUID()
    var kind: AutomationPresenceConditionKind = .atHome
    var userScope: AutomationPresenceUserScope = .homeUsers

    var summary: String {
        "\(kind.title) - \(userScope.title)"
    }
}

enum AutomationLocationTriggerKind: String, CaseIterable, Identifiable {
    case arrive
    case leave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .arrive:
            return String(localized: "automation.location.trigger.arrive", defaultValue: "Arrive")
        case .leave:
            return String(localized: "automation.location.trigger.leave", defaultValue: "Leave")
        }
    }

    var iconName: String {
        switch self {
        case .arrive:
            return "location.fill"
        case .leave:
            return "location.slash.fill"
        }
    }
}

struct AutomationLocationTrigger {
    var kind: AutomationLocationTriggerKind = .arrive
    var latitude: Double = 0
    var longitude: Double = 0
    var radius: Double = 150

    var isValid: Bool {
        (-90...90).contains(latitude) &&
        (-180...180).contains(longitude) &&
        radius >= 50 &&
        radius <= 100_000 &&
        !(latitude == 0 && longitude == 0)
    }

    var summary: String {
        let coordinate = String(format: "%.5f, %.5f", latitude, longitude)
        let radiusText = String(format: "%.0f m", radius)
        return "\(kind.title) - \(coordinate) - \(radiusText)"
    }

    var region: CLCircularRegion {
        let center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let region = CLCircularRegion(center: center, radius: radius, identifier: "HomeFloorplanAutomationLocation")
        region.notifyOnEntry = kind == .arrive
        region.notifyOnExit = kind == .leave
        return region
    }
}

enum AutomationStartEvent {
    case accessory(AutomationCapabilitySelection)
    case schedule(AutomationScheduleTrigger)
    case presence(AutomationPresenceTrigger)
    case location(AutomationLocationTrigger)
}

struct AutomationInlinePowerAction: Identifiable {
    let id: UUID
    var accessoryName: String
    var roomName: String
    var characteristic: HMCharacteristic
    var powerOn: Bool

    init(
        id: UUID = UUID(),
        accessoryName: String,
        roomName: String,
        characteristic: HMCharacteristic,
        powerOn: Bool
    ) {
        self.id = id
        self.accessoryName = accessoryName
        self.roomName = roomName
        self.characteristic = characteristic
        self.powerOn = powerOn
    }
}

/// Servizio che carica e gestisce le automazioni HomeKit.
@MainActor
@Observable
final class HomeKitAutomationsService {

    var automations: [AutomationItem] = []
    var lastError: Error?

    private let homeKit: HomeKitService

    init(homeKit: HomeKitService) {
        self.homeKit = homeKit
    }

    /// Carica/ricarica la lista delle automazioni dalla casa corrente.
    func refresh() {
        guard let home = homeKit.currentHome else {
            automations = []
            return
        }
        automations = home.triggers
            .map { AutomationItem(trigger: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Abilita o disabilita un'automazione.
    func setEnabled(_ enabled: Bool, for item: AutomationItem) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            item.trigger.enable(enabled) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        // Aggiorna lista in-memory per riflettere immediatamente il cambio
        refresh()
    }

    /// Rinomina un'automazione HomeKit esistente.
    func rename(_ name: String, for item: AutomationItem) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 50,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyName", defaultValue: "Automation name is required")])
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            item.trigger.updateName(trimmed) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        refresh()
    }

    /// Elimina un'automazione HomeKit esistente.
    func delete(_ item: AutomationItem) async throws {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitAutomationsService", code: 51,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        let inlineActionSets = item.trigger.actionSets.filter(isInlineActionSet)
        try await remove(item.trigger, from: home)
        for actionSet in inlineActionSets {
            try? await removeActionSet(actionSet, from: home)
        }
        refresh()
    }

    /// Aggiorna in-place un'automazione HomeKit esistente senza creare un nuovo trigger.
    ///
    /// Evita il conflitto "oggetto già esistente" che si verifica quando il nuovo trigger
    /// avrebbe lo stesso predicato di quello originale (tipico per trigger `.any`).
    @discardableResult
    func updateSceneAutomation(
        _ automation: AutomationItem,
        name: String,
        startEvents: [AutomationStartEvent],
        conditions: [AutomationCapabilitySelection] = [],
        timeConditions: [AutomationTimeCondition] = [],
        presenceConditions: [AutomationPresenceCondition] = [],
        conditionJoinMode: AutomationConditionJoinMode = .all,
        scene: SceneItem? = nil,
        inlinePowerActions: [AutomationInlinePowerAction] = [],
        inlineActions: [HMAction] = [],
        preservedConditionPredicate: NSPredicate? = nil,
        enabled: Bool = true
    ) async throws -> AutomationItem {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitAutomationsService", code: 60,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }
        guard let trigger = home.triggers
            .first(where: { $0.uniqueIdentifier.uuidString == automation.id }) as? HMEventTrigger else {
            throw NSError(domain: "HomeKitAutomationsService", code: 61,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.notFound", defaultValue: "Automation not found")])
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 62,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyName", defaultValue: "Automation name is required")])
        }
        guard !startEvents.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 63,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidTrigger", defaultValue: "Selected trigger is not valid for automations")])
        }
        guard scene != nil || !inlinePowerActions.isEmpty || !inlineActions.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 64,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyAction", defaultValue: "Choose a scene or at least one accessory action")])
        }

        dprint("[UpdateAuto] ▶ START '\(trigger.name)' → '\(trimmed)'")
        dprint("[UpdateAuto]   actionSets now: \(trigger.actionSets.map { "\($0.name)[\(isInlineActionSet($0) ? "inline" : "scene")]" })")
        dprint("[UpdateAuto]   startEvents: \(startEvents.count), conditions: \(conditions.count)")

        // 1. Rename first to catch name conflicts early before mutating anything else
        if trigger.name != trimmed {
            dprint("[UpdateAuto] Step 1: rename '\(trigger.name)' → '\(trimmed)'")
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    trigger.updateName(trimmed) { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                dprint("[UpdateAuto] Step 1: rename OK")
            } catch {
                dprint("[UpdateAuto] Step 1: rename FAILED — \(error)")
                throw error
            }
        } else {
            dprint("[UpdateAuto] Step 1: rename skipped (name unchanged)")
        }

        // 2. Update events
        let events = startEvents.map { homeKitEvent(for: $0) }
        dprint("[UpdateAuto] Step 2: updateEvents (\(events.count) events)")
        do {
            try await updateEvents(events, for: trigger)
            dprint("[UpdateAuto] Step 2: updateEvents OK")
        } catch let nsErr as NSError where isHomeKitObjectAlreadyExists(nsErr) {
            // HomeKit returns objectAlreadyExists when the new events are identical to
            // the existing ones (no actual change). Safe to treat as a no-op.
            dprint("[UpdateAuto] Step 2: updateEvents objectAlreadyExists — events unchanged, continuing")
        } catch {
            dprint("[UpdateAuto] Step 2: updateEvents FAILED — \(error)")
            throw error
        }

        // 3. Update predicate
        let predicate = automationPredicate(
            startEvents: startEvents,
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            preservedConditionPredicate: preservedConditionPredicate,
            conditionJoinMode: conditionJoinMode
        )
        dprint("[UpdateAuto] Step 3: updatePredicate \(predicate.map { "\($0)" } ?? "nil")")
        do {
            try await updatePredicate(predicate, for: trigger)
            dprint("[UpdateAuto] Step 3: updatePredicate OK")
        } catch let nsErr as NSError where isHomeKitObjectAlreadyExists(nsErr) {
            // Same reasoning: predicate already set to this value — no-op.
            dprint("[UpdateAuto] Step 3: updatePredicate objectAlreadyExists — predicate unchanged, continuing")
        } catch {
            dprint("[UpdateAuto] Step 3: updatePredicate FAILED — \(error)")
            throw error
        }

        // 4. Replace action sets.
        // Capture a snapshot BEFORE any removals so we don't iterate a mutating collection.
        let snapshotActionSets = Array(trigger.actionSets)
        let currentInlineActionSets = snapshotActionSets.filter(isInlineActionSet)
        let currentSceneActionSets  = snapshotActionSets.filter { !isInlineActionSet($0) }
        dprint("[UpdateAuto] Step 4: actionSets snapshot — scene:\(currentSceneActionSets.count) inline:\(currentInlineActionSets.count)")

        // Only swap the scene action set when it actually changed.
        // If the same scene is selected, skip the remove+add to avoid "objectAlreadyExists".
        let newSceneActionSet = scene?.actionSet
        let sceneIsUnchanged: Bool = {
            guard let new = newSceneActionSet, currentSceneActionSets.count == 1 else { return false }
            return currentSceneActionSets[0].uniqueIdentifier == new.uniqueIdentifier
        }()

        if sceneIsUnchanged {
            dprint("[UpdateAuto] Step 4: scene action set unchanged — skipping remove+add")
        } else {
            for actionSet in currentSceneActionSets {
                dprint("[UpdateAuto] Step 4: removing scene actionSet '\(actionSet.name)' from trigger")
                if let err = await removeFromTriggerReturningError(actionSet, trigger: trigger) {
                    dprint("[UpdateAuto] Step 4: remove scene WARN (ignored) — \(err)")
                } else {
                    dprint("[UpdateAuto] Step 4: remove scene OK")
                }
            }
            if let newSceneActionSet {
                dprint("[UpdateAuto] Step 4: adding scene actionSet '\(newSceneActionSet.name)' to trigger")
                do {
                    try await add(newSceneActionSet, to: trigger)
                    dprint("[UpdateAuto] Step 4: add scene OK")
                } catch {
                    dprint("[UpdateAuto] Step 4: add scene FAILED — \(error)")
                    throw error
                }
            }
        }

        // Inline action sets: update in-place to avoid the home.addActionSet "already present"
        // error that occurs when HomeKit hasn't fully propagated a preceding home.removeActionSet.
        let needsInlineActions = !inlinePowerActions.isEmpty || !inlineActions.isEmpty
        if currentInlineActionSets.isEmpty {
            // No existing inline action set — create one from scratch if needed
            if needsInlineActions {
                dprint("[UpdateAuto] Step 4: no inline actionSet exists — creating from scratch")
                do {
                    let actionSet = try await addActionSet(named: inlineActionSetName(for: trimmed), to: home)
                    try await addInlinePowerActions(inlinePowerActions, to: actionSet)
                    for action in inlineActions {
                        try await add(action, to: actionSet)
                    }
                    try await add(actionSet, to: trigger)
                    dprint("[UpdateAuto] Step 4: inline actionSet created OK")
                } catch {
                    dprint("[UpdateAuto] Step 4: inline actionSet create FAILED — \(error)")
                    throw error
                }
            }
        } else if !needsInlineActions {
            // Have inline action set(s) but no longer need them — detach and delete
            dprint("[UpdateAuto] Step 4: removing \(currentInlineActionSets.count) inline actionSet(s) — no longer needed")
            for actionSet in currentInlineActionSets {
                if let err = await removeFromTriggerReturningError(actionSet, trigger: trigger) {
                    dprint("[UpdateAuto] Step 4: remove inline from trigger WARN — \(err)")
                }
                if let err = await removeActionSetReturningError(actionSet, from: home) {
                    dprint("[UpdateAuto] Step 4: remove inline from home WARN — \(err)")
                }
            }
        } else {
            // Existing inline action set AND we still need one.
            // Strategy: update actions IN-PLACE using updateTargetValue.
            // NEVER remove+re-add an action for the same characteristic — HomeKit returns
            // Code=1 "already present" even after a nominally-successful remove, especially
            // when two saves happen in quick succession on automations sharing the same accessory.
            let existingActionSet = currentInlineActionSets[0]
            dprint("[UpdateAuto] Step 4: updating inline actionSet '\(existingActionSet.name)' in-place")

            // Build a lookup: characteristicUUID → existing write action
            let existingByChar = Dictionary(
                existingActionSet.actions
                    .compactMap { $0 as? HMCharacteristicWriteAction<NSNumber> }
                    .map { ($0.characteristic.uniqueIdentifier, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            // Collect all desired write actions: power actions + generic inline actions (cast to write)
            // Both use updateTargetValue path so the same characteristic is never removed+re-added.
            var processedCharUUIDs = Set<UUID>()

            // Power on/off actions
            for powerAction in inlinePowerActions {
                let charUUID = powerAction.characteristic.uniqueIdentifier
                processedCharUUIDs.insert(charUUID)
                let newValue = NSNumber(value: powerAction.powerOn)
                if let existing = existingByChar[charUUID] {
                    if existing.targetValue != newValue {
                        dprint("[UpdateAuto] Step 4:   updateTargetValue power \(charUUID)")
                        do { try await updateTargetValue(newValue, for: existing) } catch {
                            dprint("[UpdateAuto] Step 4:   updateTargetValue FAILED — \(error)"); throw error
                        }
                    } else {
                        dprint("[UpdateAuto] Step 4:   power action unchanged \(charUUID)")
                    }
                } else {
                    dprint("[UpdateAuto] Step 4:   adding power action \(charUUID)")
                    let wa = HMCharacteristicWriteAction(characteristic: powerAction.characteristic, targetValue: newValue)
                    do { try await add(wa, to: existingActionSet) } catch {
                        dprint("[UpdateAuto] Step 4:   add power action FAILED — \(error)"); throw error
                    }
                }
            }

            // Generic inline actions: also use updateTargetValue when possible
            for action in inlineActions {
                if let writeAction = action as? HMCharacteristicWriteAction<NSNumber> {
                    let charUUID = writeAction.characteristic.uniqueIdentifier
                    processedCharUUIDs.insert(charUUID)
                    let newValue = writeAction.targetValue
                    if let existing = existingByChar[charUUID] {
                        if existing.targetValue != newValue {
                            dprint("[UpdateAuto] Step 4:   updateTargetValue inline \(charUUID)")
                            do { try await updateTargetValue(newValue, for: existing) } catch {
                                dprint("[UpdateAuto] Step 4:   updateTargetValue FAILED — \(error)"); throw error
                            }
                        } else {
                            dprint("[UpdateAuto] Step 4:   inline action unchanged \(charUUID)")
                        }
                    } else {
                        dprint("[UpdateAuto] Step 4:   adding inline action \(charUUID)")
                        do { try await add(writeAction, to: existingActionSet) } catch {
                            dprint("[UpdateAuto] Step 4:   add inline action FAILED — \(error)"); throw error
                        }
                    }
                } else {
                    // Non-write action: add, treating duplicates as no-op
                    do {
                        try await add(action, to: existingActionSet)
                    } catch let nsErr as NSError where isHomeKitObjectAlreadyExists(nsErr) {
                        dprint("[UpdateAuto] Step 4:   non-write inlineAction already present — skipping")
                    } catch {
                        dprint("[UpdateAuto] Step 4:   add non-write inlineAction FAILED — \(error)"); throw error
                    }
                }
            }

            // Remove actions for characteristics no longer in the desired list
            for (charUUID, existing) in existingByChar where !processedCharUUIDs.contains(charUUID) {
                dprint("[UpdateAuto] Step 4:   removing obsolete action \(charUUID)")
                try? await removeAction(existing, from: existingActionSet)
            }

            dprint("[UpdateAuto] Step 4: inline actionSet updated in-place OK")

            // Clean up any unexpected extra inline action sets
            for actionSet in currentInlineActionSets.dropFirst() {
                dprint("[UpdateAuto] Step 4: removing extra inline actionSet '\(actionSet.name)'")
                if let err = await removeFromTriggerReturningError(actionSet, trigger: trigger) {
                    dprint("[UpdateAuto] Step 4: remove extra inline from trigger WARN — \(err)")
                }
                if let err = await removeActionSetReturningError(actionSet, from: home) {
                    dprint("[UpdateAuto] Step 4: remove extra inline from home WARN — \(err)")
                }
            }
        }

        // 5. Update enabled state
        dprint("[UpdateAuto] Step 5: setEnabled \(enabled)")
        do {
            try await setEnabled(enabled, for: trigger)
            dprint("[UpdateAuto] Step 5: setEnabled OK")
        } catch {
            dprint("[UpdateAuto] Step 5: setEnabled FAILED — \(error)")
            throw error
        }

        dprint("[UpdateAuto] ✅ DONE '\(trimmed)'")
        refresh()
        return AutomationItem(trigger: trigger)
    }

    private func updateTargetValue(_ value: NSNumber, for action: HMCharacteristicWriteAction<NSNumber>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            action.updateTargetValue(value) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func removeAction(_ action: HMAction, from actionSet: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.removeAction(action) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func isHomeKitObjectAlreadyExists(_ error: NSError) -> Bool {
        // Code=1 "Oggetto già presente." and Code=11 are both seen in practice for "already exists".
        error.domain == HMErrorDomain && (error.code == 1 || error.code == 11)
    }

    // Returns the error instead of throwing, so callers can log and ignore
    private func removeFromTriggerReturningError(_ actionSet: HMActionSet, trigger: HMEventTrigger) async -> Error? {
        await withCheckedContinuation { continuation in
            trigger.removeActionSet(actionSet) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private func removeActionSetReturningError(_ actionSet: HMActionSet, from home: HMHome) async -> Error? {
        await withCheckedContinuation { continuation in
            home.removeActionSet(actionSet) { error in
                continuation.resume(returning: error)
            }
        }
    }

    /// Crea una nuova automazione HomeKit che esegue una scena esistente.
    ///
    /// Il trigger e le condizioni arrivano dal layer `AutomationCharacteristicCapability`.
    /// Questo metodo non crea/modifica scene: usa l'`HMActionSet` già presente in `SceneItem`.
    @discardableResult
    func createSceneAutomation(
        name: String,
        trigger triggerSelection: AutomationCapabilitySelection,
        conditions: [AutomationCapabilitySelection] = [],
        timeConditions: [AutomationTimeCondition] = [],
        presenceConditions: [AutomationPresenceCondition] = [],
        conditionJoinMode: AutomationConditionJoinMode = .all,
        scene: SceneItem,
        inlinePowerActions: [AutomationInlinePowerAction] = [],
        inlineActions: [HMAction] = [],
        preservedConditionPredicate: NSPredicate? = nil,
        enabled: Bool = true
    ) async throws -> AutomationItem {
        try await createSceneAutomation(
            name: name,
            startEvents: [.accessory(triggerSelection)],
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            conditionJoinMode: conditionJoinMode,
            scene: scene,
            inlinePowerActions: inlinePowerActions,
            inlineActions: inlineActions,
            preservedConditionPredicate: preservedConditionPredicate,
            enabled: enabled
        )
    }

    @discardableResult
    func createSceneAutomation(
        name: String,
        startEvents: [AutomationStartEvent],
        conditions: [AutomationCapabilitySelection] = [],
        timeConditions: [AutomationTimeCondition] = [],
        presenceConditions: [AutomationPresenceCondition] = [],
        conditionJoinMode: AutomationConditionJoinMode = .all,
        scene: SceneItem?,
        inlinePowerActions: [AutomationInlinePowerAction] = [],
        inlineActions: [HMAction] = [],
        preservedConditionPredicate: NSPredicate? = nil,
        enabled: Bool = true
    ) async throws -> AutomationItem {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitAutomationsService", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 11,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyName", defaultValue: "Automation name is required")])
        }

        guard !startEvents.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidTrigger", defaultValue: "Selected trigger is not valid for automations")])
        }

        guard scene != nil || !inlinePowerActions.isEmpty || !inlineActions.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 19,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyAction", defaultValue: "Choose a scene or at least one accessory action")])
        }

        let accessoryTriggers = startEvents.compactMap { event -> AutomationCapabilitySelection? in
            guard case .accessory(let selection) = event else { return nil }
            return selection
        }
        guard accessoryTriggers.allSatisfy({ $0.capability.supportedRoles.contains(.trigger) }) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidTrigger", defaultValue: "Selected trigger is not valid for automations")])
        }

        guard conditions.allSatisfy({ $0.capability.supportedRoles.contains(.condition) }) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidCondition", defaultValue: "One or more conditions are not valid")])
        }

        let schedules = startEvents.compactMap { event -> AutomationScheduleTrigger? in
            guard case .schedule(let schedule) = event else { return nil }
            return schedule
        }
        guard schedules.allSatisfy({ !$0.weekdays.isEmpty }) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyScheduleDays", defaultValue: "Select at least one day")])
        }
        if let firstSchedule = schedules.first,
           schedules.contains(where: { $0.weekdays != firstSchedule.weekdays }) {
            throw NSError(domain: "HomeKitAutomationsService", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.mixedScheduleDays", defaultValue: "Multiple schedule start events must use the same days")])
        }

        let locations = startEvents.compactMap { event -> AutomationLocationTrigger? in
            guard case .location(let location) = event else { return nil }
            return location
        }
        guard locations.allSatisfy(\.isValid) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidLocation", defaultValue: "Enter a valid location")])
        }

        guard accessoryTriggers.isEmpty || accessoryTriggers.count == startEvents.count else {
            throw NSError(domain: "HomeKitAutomationsService", code: 18,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.mixedAccessoryTriggers", defaultValue: "Accessory start events cannot be mixed with time, people, or location events yet")])
        }

        let events = startEvents.map { homeKitEvent(for: $0) }
        let predicate = automationPredicate(
            startEvents: startEvents,
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            preservedConditionPredicate: preservedConditionPredicate,
            conditionJoinMode: conditionJoinMode
        )

        let trigger = HMEventTrigger(
            name: trimmed,
            events: events,
            end: nil,
            recurrences: schedules.first.flatMap { scheduleRecurrences(for: $0) },
            predicate: predicate
        )

        try await add(trigger, to: home)
        var createdInlineActionSet: HMActionSet?
        do {
            if let scene {
                try await add(scene.actionSet, to: trigger)
            }
            let accessoryActions = inlineActions
            if !inlinePowerActions.isEmpty || !accessoryActions.isEmpty {
                let actionSet = try await addActionSet(named: inlineActionSetName(for: trimmed), to: home)
                createdInlineActionSet = actionSet
                try await addInlinePowerActions(inlinePowerActions, to: actionSet)
                for action in accessoryActions {
                    try await add(action, to: actionSet)
                }
                try await add(actionSet, to: trigger)
            }
            try await setEnabled(enabled, for: trigger)
        } catch {
            try? await remove(trigger, from: home)
            if let createdInlineActionSet {
                try? await removeActionSet(createdInlineActionSet, from: home)
            }
            throw error
        }

        refresh()
        return AutomationItem(trigger: trigger)
    }

    @discardableResult
    func createScheduledSceneAutomation(
        name: String,
        schedule: AutomationScheduleTrigger,
        conditions: [AutomationCapabilitySelection] = [],
        timeConditions: [AutomationTimeCondition] = [],
        presenceConditions: [AutomationPresenceCondition] = [],
        conditionJoinMode: AutomationConditionJoinMode = .all,
        scene: SceneItem,
        enabled: Bool = true
    ) async throws -> AutomationItem {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitAutomationsService", code: 20,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 21,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyName", defaultValue: "Automation name is required")])
        }

        guard !schedule.weekdays.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 22,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyScheduleDays", defaultValue: "Select at least one day")])
        }

        guard conditions.allSatisfy({ $0.capability.supportedRoles.contains(.condition) }) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 23,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidCondition", defaultValue: "One or more conditions are not valid")])
        }

        let event = scheduleEvent(for: schedule)
        let trigger = HMEventTrigger(
            name: trimmed,
            events: [event],
            end: nil,
            recurrences: scheduleRecurrences(for: schedule),
            predicate: conditionsPredicate(
                conditions,
                timeConditions: timeConditions,
                presenceConditions: presenceConditions,
                conditionJoinMode: conditionJoinMode
            )
        )

        try await add(trigger, to: home)
        do {
            try await add(scene.actionSet, to: trigger)
            try await setEnabled(enabled, for: trigger)
        } catch {
            try? await remove(trigger, from: home)
            throw error
        }

        refresh()
        return AutomationItem(trigger: trigger)
    }

    @discardableResult
    func createPresenceSceneAutomation(
        name: String,
        presence: AutomationPresenceTrigger,
        conditions: [AutomationCapabilitySelection] = [],
        timeConditions: [AutomationTimeCondition] = [],
        presenceConditions: [AutomationPresenceCondition] = [],
        conditionJoinMode: AutomationConditionJoinMode = .all,
        scene: SceneItem,
        enabled: Bool = true
    ) async throws -> AutomationItem {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitAutomationsService", code: 30,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 31,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyName", defaultValue: "Automation name is required")])
        }

        guard conditions.allSatisfy({ $0.capability.supportedRoles.contains(.condition) }) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 32,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidCondition", defaultValue: "One or more conditions are not valid")])
        }

        let event = presenceEvent(
            type: presence.kind.homeKitValue,
            userScope: presence.userScope
        )
        let trigger = HMEventTrigger(
            name: trimmed,
            events: [event],
            end: nil,
            recurrences: nil,
            predicate: conditionsPredicate(
                conditions,
                timeConditions: timeConditions,
                presenceConditions: presenceConditions,
                conditionJoinMode: conditionJoinMode
            )
        )

        try await add(trigger, to: home)
        do {
            try await add(scene.actionSet, to: trigger)
            try await setEnabled(enabled, for: trigger)
        } catch {
            try? await remove(trigger, from: home)
            throw error
        }

        refresh()
        return AutomationItem(trigger: trigger)
    }

    @discardableResult
    func createLocationSceneAutomation(
        name: String,
        location: AutomationLocationTrigger,
        conditions: [AutomationCapabilitySelection] = [],
        timeConditions: [AutomationTimeCondition] = [],
        presenceConditions: [AutomationPresenceCondition] = [],
        conditionJoinMode: AutomationConditionJoinMode = .all,
        scene: SceneItem,
        enabled: Bool = true
    ) async throws -> AutomationItem {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeKitAutomationsService", code: 40,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "HomeKitAutomationsService", code: 41,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.emptyName", defaultValue: "Automation name is required")])
        }

        guard location.isValid else {
            throw NSError(domain: "HomeKitAutomationsService", code: 42,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidLocation", defaultValue: "Enter a valid location")])
        }

        guard conditions.allSatisfy({ $0.capability.supportedRoles.contains(.condition) }) else {
            throw NSError(domain: "HomeKitAutomationsService", code: 43,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "automation.editor.error.invalidCondition", defaultValue: "One or more conditions are not valid")])
        }

        let event = HMLocationEvent(region: location.region)
        let trigger = HMEventTrigger(
            name: trimmed,
            events: [event],
            end: nil,
            recurrences: nil,
            predicate: conditionsPredicate(
                conditions,
                timeConditions: timeConditions,
                presenceConditions: presenceConditions,
                conditionJoinMode: conditionJoinMode
            )
        )

        try await add(trigger, to: home)
        do {
            try await add(scene.actionSet, to: trigger)
            try await setEnabled(enabled, for: trigger)
        } catch {
            try? await remove(trigger, from: home)
            throw error
        }

        refresh()
        return AutomationItem(trigger: trigger)
    }

    private func automationPredicate(
        trigger triggerSelection: AutomationCapabilitySelection,
        conditions: [AutomationCapabilitySelection],
        timeConditions: [AutomationTimeCondition],
        presenceConditions: [AutomationPresenceCondition],
        preservedConditionPredicate: NSPredicate? = nil,
        conditionJoinMode: AutomationConditionJoinMode
    ) -> NSPredicate {
        let triggerPredicate = triggerSelection.predicate
        let conditionPredicates = allConditionPredicates(
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            preservedConditionPredicate: preservedConditionPredicate
        )

        guard !conditionPredicates.isEmpty else {
            return triggerPredicate
        }

        let conditionGroup: NSPredicate
        switch conditionJoinMode {
        case .all:
            conditionGroup = NSCompoundPredicate(andPredicateWithSubpredicates: conditionPredicates)
        case .any:
            conditionGroup = NSCompoundPredicate(orPredicateWithSubpredicates: conditionPredicates)
        }

        return NSCompoundPredicate(andPredicateWithSubpredicates: [triggerPredicate, conditionGroup])
    }

    private func automationPredicate(
        startEvents: [AutomationStartEvent],
        conditions: [AutomationCapabilitySelection],
        timeConditions: [AutomationTimeCondition],
        presenceConditions: [AutomationPresenceCondition],
        preservedConditionPredicate: NSPredicate? = nil,
        conditionJoinMode: AutomationConditionJoinMode
    ) -> NSPredicate? {
        let triggerPredicates = startEvents.compactMap { event -> NSPredicate? in
            guard case .accessory(let selection) = event else { return nil }
            return selection.triggerPredicate
        }
        let conditionPredicate = conditionsPredicate(
            conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            preservedConditionPredicate: preservedConditionPredicate,
            conditionJoinMode: conditionJoinMode
        )

        let triggerPredicate: NSPredicate?
        if triggerPredicates.isEmpty {
            triggerPredicate = nil
        } else if triggerPredicates.count == 1 {
            triggerPredicate = triggerPredicates[0]
        } else {
            triggerPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: triggerPredicates)
        }

        switch (triggerPredicate, conditionPredicate) {
        case (nil, nil):
            return nil
        case (let triggerPredicate?, nil):
            return triggerPredicate
        case (nil, let conditionPredicate?):
            return conditionPredicate
        case (let triggerPredicate?, let conditionPredicate?):
            return NSCompoundPredicate(andPredicateWithSubpredicates: [triggerPredicate, conditionPredicate])
        }
    }

    private func conditionsPredicate(
        _ conditions: [AutomationCapabilitySelection],
        timeConditions: [AutomationTimeCondition],
        presenceConditions: [AutomationPresenceCondition],
        preservedConditionPredicate: NSPredicate? = nil,
        conditionJoinMode: AutomationConditionJoinMode
    ) -> NSPredicate? {
        let conditionPredicates = allConditionPredicates(
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            preservedConditionPredicate: preservedConditionPredicate
        )
        guard !conditionPredicates.isEmpty else { return nil }

        switch conditionJoinMode {
        case .all:
            return NSCompoundPredicate(andPredicateWithSubpredicates: conditionPredicates)
        case .any:
            return NSCompoundPredicate(orPredicateWithSubpredicates: conditionPredicates)
        }
    }

    private func allConditionPredicates(
        conditions: [AutomationCapabilitySelection],
        timeConditions: [AutomationTimeCondition],
        presenceConditions: [AutomationPresenceCondition],
        preservedConditionPredicate: NSPredicate? = nil
    ) -> [NSPredicate] {
        conditions.map(\.predicate) +
        timeConditions.map(timeConditionPredicate) +
        presenceConditions.map(presenceConditionPredicate) +
        [preservedConditionPredicate].compactMap { $0 }
    }

    private func timeConditionPredicate(_ condition: AutomationTimeCondition) -> NSPredicate {
        if condition.relation == .between {
            return betweenTimeConditionPredicate(condition)
        }

        switch condition.kind {
        case .fixedTime:
            let components = Calendar.current.dateComponents([.hour, .minute], from: condition.time)
            switch condition.relation {
            case .after:
                return HMEventTrigger.predicateForEvaluatingTrigger(occurringAfter: components)
            case .before:
                return HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: components)
            case .between:
                return betweenTimeConditionPredicate(condition)
            }

        case .sunrise, .sunset:
            let significantEvent = condition.kind == .sunrise
                ? HMSignificantEvent.sunrise
                : HMSignificantEvent.sunset
            let event = HMSignificantTimeEvent(
                significantEvent: significantEvent,
                offset: timeConditionOffsetComponents(for: condition)
            )
            switch condition.relation {
            case .after:
                return HMEventTrigger.predicateForEvaluatingTriggerOccurring(afterSignificantEvent: event)
            case .before:
                return HMEventTrigger.predicateForEvaluatingTriggerOccurring(beforeSignificantEvent: event)
            case .between:
                return betweenTimeConditionPredicate(condition)
            }
        }
    }

    private func betweenTimeConditionPredicate(_ condition: AutomationTimeCondition) -> NSPredicate {
        switch (condition.kind, condition.endKind) {
        case (.fixedTime, .fixedTime):
            return HMEventTrigger.predicateForEvaluatingTriggerOccurringBetweenDate(
                with: Calendar.current.dateComponents([.hour, .minute], from: condition.time),
                secondDateWith: Calendar.current.dateComponents([.hour, .minute], from: condition.endTime)
            )

        case (.sunrise, .sunrise), (.sunrise, .sunset), (.sunset, .sunrise), (.sunset, .sunset):
            return HMEventTrigger.predicate(
                forEvaluatingTriggerOccurringBetweenSignificantEvent: significantTimeEvent(
                    kind: condition.kind,
                    offsetMinutes: condition.offsetMinutes
                ),
                secondSignificantEvent: significantTimeEvent(
                    kind: condition.endKind,
                    offsetMinutes: condition.endOffsetMinutes
                )
            )

        default:
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                afterPredicate(kind: condition.kind, time: condition.time, offsetMinutes: condition.offsetMinutes),
                beforePredicate(kind: condition.endKind, time: condition.endTime, offsetMinutes: condition.endOffsetMinutes)
            ])
        }
    }

    private func afterPredicate(
        kind: AutomationTimeConditionKind,
        time: Date,
        offsetMinutes: Int
    ) -> NSPredicate {
        switch kind {
        case .fixedTime:
            return HMEventTrigger.predicateForEvaluatingTrigger(
                occurringAfter: Calendar.current.dateComponents([.hour, .minute], from: time)
            )
        case .sunrise, .sunset:
            return HMEventTrigger.predicateForEvaluatingTriggerOccurring(
                afterSignificantEvent: significantTimeEvent(kind: kind, offsetMinutes: offsetMinutes)
            )
        }
    }

    private func beforePredicate(
        kind: AutomationTimeConditionKind,
        time: Date,
        offsetMinutes: Int
    ) -> NSPredicate {
        switch kind {
        case .fixedTime:
            return HMEventTrigger.predicateForEvaluatingTrigger(
                occurringBefore: Calendar.current.dateComponents([.hour, .minute], from: time)
            )
        case .sunrise, .sunset:
            return HMEventTrigger.predicateForEvaluatingTriggerOccurring(
                beforeSignificantEvent: significantTimeEvent(kind: kind, offsetMinutes: offsetMinutes)
            )
        }
    }

    private func significantTimeEvent(
        kind: AutomationTimeConditionKind,
        offsetMinutes: Int
    ) -> HMSignificantTimeEvent {
        HMSignificantTimeEvent(
            significantEvent: kind == .sunrise ? HMSignificantEvent.sunrise : HMSignificantEvent.sunset,
            offset: offsetMinutes == 0 ? nil : DateComponents(minute: offsetMinutes)
        )
    }

    private func timeConditionOffsetComponents(for condition: AutomationTimeCondition) -> DateComponents? {
        guard condition.offsetMinutes != 0 else { return nil }
        return DateComponents(minute: condition.offsetMinutes)
    }

    private func presenceConditionPredicate(_ condition: AutomationPresenceCondition) -> NSPredicate {
        HMEventTrigger.predicateForEvaluatingTrigger(
            withPresence: presenceEvent(
                type: condition.kind.homeKitValue,
                userScope: condition.userScope
            )
        )
    }

    private func presenceEvent(
        type: HMPresenceEventType,
        userScope: AutomationPresenceUserScope
    ) -> HMPresenceEvent {
        HMPresenceEvent(
            presenceEventType: type,
            presenceUserType: userScope.homeKitValue
        )
    }

    private func homeKitEvent(for startEvent: AutomationStartEvent) -> HMEvent {
        switch startEvent {
        case .accessory(let selection):
            return selection.characteristicEvent
        case .schedule(let schedule):
            return scheduleEvent(for: schedule)
        case .presence(let presence):
            return presenceEvent(
                type: presence.kind.homeKitValue,
                userScope: presence.userScope
            )
        case .location(let location):
            return HMLocationEvent(region: location.region)
        }
    }

    private func scheduleEvent(for schedule: AutomationScheduleTrigger) -> HMEvent {
        switch schedule.kind {
        case .fixedTime:
            let components = Calendar.current.dateComponents([.hour, .minute], from: schedule.time)
            return HMCalendarEvent(fire: components)
        case .sunrise:
            return HMSignificantTimeEvent(
                significantEvent: HMSignificantEvent.sunrise,
                offset: scheduleOffsetComponents(for: schedule)
            )
        case .sunset:
            return HMSignificantTimeEvent(
                significantEvent: HMSignificantEvent.sunset,
                offset: scheduleOffsetComponents(for: schedule)
            )
        }
    }

    private func scheduleOffsetComponents(for schedule: AutomationScheduleTrigger) -> DateComponents? {
        guard schedule.offsetMinutes != 0 else { return nil }
        return DateComponents(minute: schedule.offsetMinutes)
    }

    private func scheduleRecurrences(for schedule: AutomationScheduleTrigger) -> [DateComponents]? {
        guard schedule.weekdays.count < AutomationScheduleWeekday.allCases.count else {
            return nil
        }

        return AutomationScheduleWeekday.allCases
            .filter { schedule.weekdays.contains($0) }
            .map { DateComponents(weekday: $0.rawValue) }
    }

    private func add(_ trigger: HMTrigger, to home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.addTrigger(trigger) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func remove(_ trigger: HMTrigger, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeTrigger(trigger) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func add(_ actionSet: HMActionSet, to trigger: HMTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.addActionSet(actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func inlineActionSetName(for automationName: String) -> String {
        let safeName = automationName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "HF Actions - \(safeName) - \(UUID().uuidString.prefix(6))"
    }

    private func isInlineActionSet(_ actionSet: HMActionSet) -> Bool {
        actionSet.name.hasPrefix("HF Actions - ")
    }

    private func addActionSet(named name: String, to home: HMHome) async throws -> HMActionSet {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HMActionSet, Error>) in
            home.addActionSet(withName: name) { actionSet, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let actionSet {
                    continuation.resume(returning: actionSet)
                } else {
                    continuation.resume(throwing: NSError(domain: "HomeKitAutomationsService", code: 80,
                                                          userInfo: [NSLocalizedDescriptionKey: "HomeKit did not return an action set"]))
                }
            }
        }
    }

    private func removeActionSet(_ actionSet: HMActionSet, from home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.removeActionSet(actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func addInlinePowerActions(_ actions: [AutomationInlinePowerAction], to actionSet: HMActionSet) async throws {
        for action in actions {
            let writeAction = HMCharacteristicWriteAction(
                characteristic: action.characteristic,
                targetValue: NSNumber(value: action.powerOn)
            )
            try await add(writeAction, to: actionSet)
        }
    }

    private func add(_ action: HMAction, to actionSet: HMActionSet) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            actionSet.addAction(action) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func updatePredicate(_ predicate: NSPredicate?, for trigger: HMEventTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updatePredicate(predicate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func updateEvents(_ events: [HMEvent], for trigger: HMEventTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.updateEvents(events) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func removeFromTrigger(_ actionSet: HMActionSet, trigger: HMEventTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.removeActionSet(actionSet) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setEnabled(_ enabled: Bool, for trigger: HMTrigger) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            trigger.enable(enabled) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
