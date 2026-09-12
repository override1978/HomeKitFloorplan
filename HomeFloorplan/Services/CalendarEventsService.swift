import Foundation
import EventKit
import Observation

// MARK: - CalendarEventsService

/// Gli impegni di oggi, letti dal calendario del dispositivo.
///
/// Entra dalla porta che esiste già. Il calendario non è una schermata nuova e
/// non è una scheda: è una sorgente che deposita momenti nella giornata,
/// accanto alle automazioni e agli orari del sole. Era la prova del nove
/// dell'architettura — se aggiungere il calendario avesse richiesto una
/// sezione sua, l'impianto sarebbe stato sbagliato.
///
/// Nulla esce dal dispositivo: gli eventi si leggono da EventKit e restano
/// dove sono. Non vengono persistiti, non vengono sincronizzati, non entrano
/// in nessun archivio. Un impegno di famiglia è più intimo di una temperatura,
/// e trattarlo come telemetria sarebbe un abuso silenzioso.
@Observable
@MainActor
final class CalendarEventsService {

    /// Stato del permesso, per poterlo raccontare invece di fallire in silenzio.
    enum Access: Equatable {
        /// Non ancora chiesto: si chiede solo quando serve davvero.
        case notDetermined
        case granted
        /// Negato o limitato dal sistema: si smette di chiedere.
        case denied
    }

    private(set) var access: Access = .notDetermined
    private(set) var todayEntries: [DayTimeline.CalendarEntry] = []

    /// Interruttore dell'utente. Spento di default: una casa non legge gli
    /// impegni di nessuno finché non glielo si chiede.
    static let enabledKey = "calendar.showsInDay"
    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private let store = EKEventStore()

    init() {
        refreshAccessStatus()
    }

    // MARK: - Permesso

    func refreshAccessStatus() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:                 access = .granted
        case .notDetermined:              access = .notDetermined
        case .denied, .restricted:        access = .denied
        // L'accesso in sola scrittura non serve a niente qui: si può creare ma
        // non leggere, ed è la lettura che ci interessa.
        case .writeOnly:                  access = .denied
        @unknown default:                 access = .denied
        }
    }

    /// Chiede il permesso, una volta sola.
    @discardableResult
    func requestAccess() async -> Bool {
        guard access == .notDetermined else { return access == .granted }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : .denied
        return granted
    }

    // MARK: - Lettura

    /// Ricarica gli impegni della giornata indicata.
    ///
    /// Non chiede il permesso da sola: se non c'è, semplicemente non c'è
    /// niente da mostrare. Chiedere di sorpresa mentre qualcuno guarda la
    /// planimetria sarebbe un modo eccellente di farselo negare.
    func refresh(day: DateInterval) {
        guard isEnabled, access == .granted else {
            todayEntries = []
            return
        }

        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { todayEntries = []; return }

        let predicate = store.predicateForEvents(withStart: day.start,
                                                 end: day.end,
                                                 calendars: calendars)
        let events = store.events(matching: predicate)

        // Più calendari significa più contesto: il nome serve solo quando ce
        // n'è più d'uno, altrimenti ripeterebbe l'ovvio su ogni riga.
        let showsCalendarName = Set(events.compactMap { $0.calendar?.calendarIdentifier }).count > 1

        todayEntries = events.compactMap { event -> DayTimeline.CalendarEntry? in
            guard let start = event.startDate else { return nil }
            let title = (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return DayTimeline.CalendarEntry(
                id: event.eventIdentifier ?? "\(start.timeIntervalSinceReferenceDate)-\(title)",
                title: title,
                start: start,
                isAllDay: event.isAllDay,
                calendarName: showsCalendarName ? event.calendar?.title : nil)
        }
    }
}
