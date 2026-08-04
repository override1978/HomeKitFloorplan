import Foundation

// MARK: - RestorableAutomation

/// Un'automazione salvata in una forma da cui si può **ricrearla**.
///
/// Il resto di `AutomationSnapshot` è documentazione: descrive in lingua cosa
/// scatta e quando, e serve a rifarla a mano. Questo invece è la stessa
/// automazione ridotta ai parametri che l'`AutomationsService` accetta per
/// crearne una — quindi esiste solo per quelle che l'app sa davvero rimettere,
/// ed è `nil` per tutte le altre.
///
/// Nessun UUID di HomeKit: gli identificatori sono generati per device, mentre
/// nomi di accessorio, stanza e scena sono dati della casa e valgono ovunque.
struct RestorableAutomation: Codable, Sendable {

    struct Schedule: Codable, Sendable {
        /// `AutomationScheduleKind`: fixedTime, sunrise, sunset.
        var kind: String
        var hour: Int
        var minute: Int
        var offsetMinutes: Int
        /// `AutomationScheduleWeekday` grezzi, 1 = domenica.
        var weekdays: [Int]
    }

    /// Una condizione o un evento di avvio legato a una caratteristica.
    struct CapabilityRef: Codable, Sendable {
        var accessory: AccessoryAddress
        var characteristicType: String
        /// `becomesActive` · `becomesInactive` · `equals` · `greaterThan` · `lessThan`
        var comparisonOperator: String
        var targetValue: TargetValue
    }

    enum TargetValue: Codable, Sendable {
        case bool(Bool)
        case number(Double)
        case state(Int)
        case any
    }

    enum StartEvent: Codable, Sendable {
        case accessory(CapabilityRef)
        case schedule(Schedule)
        /// `AutomationPresenceTriggerKind` + ambito utente, grezzi.
        case presence(kind: String, userScope: String)
    }

    var startEvents: [StartEvent]
    var conditions: [CapabilityRef]
    /// `AutomationConditionJoinMode`: all · any.
    var conditionJoinMode: String
    /// La scena eseguita, per nome. Un'automazione senza scena non entra qui:
    /// ricrearne il trigger senza ciò che esegue produrrebbe un guscio.
    var sceneName: String
    var isEnabled: Bool
}

// MARK: - Descrizione

extension RestorableAutomation {

    /// Cosa verrà ricreato, in lingua. È il testo della conferma: chi la legge
    /// deve poter dire «no, non era così» **prima** che venga scritto qualcosa.
    var confirmationLines: [String] {
        var lines = startEvents.map(Self.describe)
        lines.append(String(format: String(localized: "restorableAutomation.runs",
                                           defaultValue: "runs the scene “%@”"), sceneName))
        if !conditions.isEmpty {
            let joiner = conditionJoinMode == "any"
                ? String(localized: "restorableAutomation.joinAny", defaultValue: "if any of:")
                : String(localized: "restorableAutomation.joinAll", defaultValue: "only if:")
            lines.append(joiner + " " + conditions.map(Self.describe).joined(separator: ", "))
        }
        if !isEnabled {
            lines.append(String(localized: "restorableAutomation.paused", defaultValue: "recreated paused"))
        }
        return lines
    }

    private static func describe(_ event: StartEvent) -> String {
        switch event {
        case .accessory(let ref):
            return describe(ref)
        case .schedule(let schedule):
            return describe(schedule)
        case .presence(let kind, _):
            return String(format: String(localized: "restorableAutomation.presence",
                                         defaultValue: "on presence (%@)"), kind)
        }
    }

    private static func describe(_ schedule: Schedule) -> String {
        let days = schedule.weekdays.count >= 7
            ? String(localized: "restorableAutomation.everyDay", defaultValue: "every day")
            : String(format: String(localized: "restorableAutomation.someDays",
                                    defaultValue: "%d days a week"), schedule.weekdays.count)
        switch schedule.kind {
        case "sunrise", "sunset":
            let base = schedule.kind == "sunrise"
                ? String(localized: "restorableAutomation.sunrise", defaultValue: "at sunrise")
                : String(localized: "restorableAutomation.sunset", defaultValue: "at sunset")
            let offset = schedule.offsetMinutes == 0
                ? ""
                : String(format: String(localized: "restorableAutomation.offset",
                                        defaultValue: " %+d min"), schedule.offsetMinutes)
            return "\(base)\(offset) · \(days)"
        default:
            return String(format: "%02d:%02d · %@", schedule.hour, schedule.minute, days)
        }
    }

    private static func describe(_ ref: CapabilityRef) -> String {
        let characteristic = SnapshotCharacteristicNames.readable(ref.characteristicType)
        let value: String
        switch ref.targetValue {
        case .bool(let flag):   value = flag ? "on" : "off"
        case .number(let n):    value = n == n.rounded() ? "\(Int(n))" : String(format: "%.1f", n)
        case .state(let s):     value = "\(s)"
        case .any:              value = String(localized: "restorableAutomation.anyValue", defaultValue: "any change")
        }
        return "\(ref.accessory.name) · \(characteristic) \(ref.comparisonOperator) \(value)"
    }
}
