import Foundation
import HomeKit
import Observation

/// Tipo di trigger di un'automazione HomeKit.
enum AutomationTriggerType: String {
    case timer      = "Timer"
    case event      = "Evento"
    case location   = "Posizione"
    case presence   = "Presenza"
    case time       = "Orario"
    case unknown    = "Sconosciuto"

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
    var actionCount: Int { trigger.actionSets.reduce(0) { $0 + $1.actions.count } }

    init(trigger: HMTrigger) {
        self.trigger = trigger
        self.triggerType = Self.classifyTrigger(trigger)
        self.summary = Self.describeTrigger(trigger)
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
        return String(localized: "automation.description.custom", defaultValue: "Automazione personalizzata")
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
                components.append(String(localized: "automation.recurrence.weekly", defaultValue: "Settimanale"))
            } else if let _ = recurrence.value(for: .day) {
                components.append(String(localized: "automation.recurrence.daily", defaultValue: "Giornaliero"))
            }
            if components.isEmpty {
                // Riprova con weekday
                let days = [
                    String(localized: "weekday.sun", defaultValue: "Dom"),
                    String(localized: "weekday.mon", defaultValue: "Lun"),
                    String(localized: "weekday.tue", defaultValue: "Mar"),
                    String(localized: "weekday.wed", defaultValue: "Mer"),
                    String(localized: "weekday.thu", defaultValue: "Gio"),
                    String(localized: "weekday.fri", defaultValue: "Ven"),
                    String(localized: "weekday.sat", defaultValue: "Sab")
                ]
                if let wd = recurrence.weekday, wd >= 1, wd <= 7 {
                    components.append(days[wd - 1])
                }
            }
            let recStr = components.isEmpty
                ? String(localized: "automation.recurrence.recurring", defaultValue: "Ricorrente")
                : components.joined(separator: ", ")
            let atStr = String(localized: "automation.timer.at", defaultValue: "alle")
            return "\(recStr) \(atStr) \(timeStr)"
        }
        let onceStr = String(localized: "automation.timer.once", defaultValue: "Una volta alle")
        return "\(onceStr) \(timeStr)"
    }

    private static func describeEventTrigger(_ trigger: HMEventTrigger) -> String {
        var parts: [String] = []
        for event in trigger.events {
            if event is HMSignificantTimeEvent {
                parts.append(String(localized: "automation.event.sunsetSunrise", defaultValue: "Tramonto / Alba"))
            } else if let cal = event as? HMCalendarEvent {
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                parts.append(formatter.string(from: cal.fireDateComponents.date ?? Date()))
            } else if event is HMLocationEvent {
                parts.append(String(localized: "automation.event.location", defaultValue: "Posizione"))
            } else if let pres = event as? HMPresenceEvent {
                switch pres.presenceEventType {
                case .everyEntry: parts.append(String(localized: "automation.event.presence.everyEntry", defaultValue: "Ogni arrivo a casa"))
                case .everyExit:  parts.append(String(localized: "automation.event.presence.everyExit", defaultValue: "Ogni uscita da casa"))
                case .firstEntry: parts.append(String(localized: "automation.event.presence.firstEntry", defaultValue: "Primo arrivo a casa"))
                case .lastExit:   parts.append(String(localized: "automation.event.presence.lastExit", defaultValue: "Ultima uscita da casa"))
                @unknown default: parts.append(String(localized: "automation.event.presence.other", defaultValue: "Presenza"))
                }
            } else if let charEvent = event as? HMCharacteristicEvent<NSCopying> {
                let accName = charEvent.characteristic.service?.accessory?.name ?? String(localized: "automation.event.accessory.fallback", defaultValue: "Accessorio")
                let eventPrefix = String(localized: "automation.event.characteristic.prefix", defaultValue: "Evento su")
                parts.append("\(eventPrefix) \(accName)")
            }
        }
        return parts.isEmpty
            ? String(localized: "automation.event.description.fallback", defaultValue: "Automazione basata su eventi")
            : parts.joined(separator: " • ")
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
}
