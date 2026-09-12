import Foundation

// MARK: - DayMoment

/// Un momento della giornata della casa.
///
/// Le automazioni da sole non fanno una giornata: sono dieci righe con due
/// addensamenti, e un asse temporale che mostrasse solo quelle resterebbe
/// mezzo vuoto. Una giornata ha anche il sole che sorge e cala, gli impegni
/// di chi ci abita, e in prospettiva le fasce di prezzo dell'energia.
///
/// Perciò il tipo non è «automazione con un orario» ma «momento», con la
/// sorgente come dettaglio invece che come identità. È il punto in cui il
/// documento diceva che una capacità nuova deve entrare da una porta che
/// esiste già: aggiungere il calendario non deve voler dire una schermata in
/// più, solo un'altra sorgente che deposita qui.
struct DayMoment: Identifiable, Equatable, Sendable {

    enum Kind: Equatable, Sendable {
        /// Un'automazione a orario. `isConditional` quando ha condizioni che
        /// possono impedirle di agire: è la differenza fra una promessa e una
        /// previsione, e va portata fino a chi legge.
        case automation(isConditional: Bool)
        /// Alba o tramonto, agli orari reali del posto in cui sta la casa.
        case solar(NextFireResolver.SolarEvent)
        /// Un impegno di chi ci abita.
        case calendar(isAllDay: Bool)

        var isAutomation: Bool {
            if case .automation = self { return true }
            return false
        }
    }

    let id: String
    let at: Date
    let title: String
    /// Riga secondaria, quando aggiunge qualcosa. `nil` quando tacerebbe.
    let detail: String?
    let kind: Kind
    /// Vero quando l'orario è trascorso.
    ///
    /// Per le automazioni vuol dire «era previsto», non «è successo»: il
    /// registro di cosa sia davvero accaduto non esiste ancora.
    let isPast: Bool

    /// Serve alla nota sul passato: solo le automazioni hanno il problema
    /// «previsto contro avvenuto». Alba e impegni sono fatti, non promesse.
    var isAutomationKind: Bool { kind.isAutomation }

    /// Alba e tramonto: sul nastro diventano lo sfondo invece che due punti in
    /// fila, quindi chi li disegna così deve poterli togliere dall'elenco.
    var isSolarKind: Bool {
        if case .solar = kind { return true }
        return false
    }

    var symbolName: String {
        switch kind {
        case .automation:      return "gearshape.2"
        case .solar(.sunrise): return "sunrise"
        case .solar(.sunset):  return "sunset"
        case .calendar:        return "calendar"
        }
    }
}

// MARK: - DayTimeline

/// Fonde le sorgenti di una giornata in un'unica sequenza ordinata.
///
/// Non va a prendere niente da sola: riceve ciò che le sorgenti hanno già
/// raccolto. Così resta pura e provabile senza HomeKit, senza WeatherKit e
/// senza il permesso al calendario.
enum DayTimeline {

    /// Gli eventi di calendario, ridotti a ciò che serve qui.
    struct CalendarEntry: Equatable, Sendable {
        let id: String
        let title: String
        let start: Date
        let isAllDay: Bool
        /// Nome del calendario di provenienza, se vale la pena distinguerlo.
        let calendarName: String?

        init(id: String, title: String, start: Date, isAllDay: Bool, calendarName: String? = nil) {
            self.id = id
            self.title = title
            self.start = start
            self.isAllDay = isAllDay
            self.calendarName = calendarName
        }
    }

    static func build(day: DateInterval,
                      now: Date,
                      automations: [HomeKitAutomationsService.ScheduledFire],
                      solar: NextFireResolver.SolarTimes,
                      calendarEntries: [CalendarEntry] = []) -> [DayMoment] {
        var moments: [DayMoment] = []

        for fire in automations where day.contains(fire.at) {
            moments.append(DayMoment(
                id: "automation:\(fire.id)",
                at: fire.at,
                title: fire.name,
                detail: fire.actionSetNames.isEmpty
                    ? (fire.actionCount > 0 ? actionsLabel(fire.actionCount) : nil)
                    : fire.actionSetNames.joined(separator: " · "),
                kind: .automation(isConditional: fire.isConditional),
                isPast: fire.at <= now))
        }

        // Il sole non è un'automazione ma è il fatto che scandisce la giornata
        // più di qualunque altro: senza, l'asse non ha mattina né sera.
        if let sunrise = solar.todaySunrise, day.contains(sunrise) {
            moments.append(DayMoment(id: "solar:sunrise",
                                     at: sunrise,
                                     title: String(localized: "day.sunrise", defaultValue: "Alba"),
                                     detail: nil,
                                     kind: .solar(.sunrise),
                                     isPast: sunrise <= now))
        }
        if let sunset = solar.todaySunset, day.contains(sunset) {
            moments.append(DayMoment(id: "solar:sunset",
                                     at: sunset,
                                     title: String(localized: "day.sunset", defaultValue: "Tramonto"),
                                     detail: nil,
                                     kind: .solar(.sunset),
                                     isPast: sunset <= now))
        }

        for entry in calendarEntries where day.contains(entry.start) {
            moments.append(DayMoment(
                id: "calendar:\(entry.id)",
                at: entry.isAllDay ? day.start : entry.start,
                title: entry.title,
                detail: entry.calendarName,
                kind: .calendar(isAllDay: entry.isAllDay),
                // Un impegno che dura tutto il giorno non è passato finché il
                // giorno non è finito: trattarlo come le altre righe lo
                // spegnerebbe subito dopo mezzanotte.
                isPast: entry.isAllDay ? (day.end <= now) : (entry.start <= now)))
        }

        return moments.sorted {
            $0.at == $1.at ? $0.id < $1.id : $0.at < $1.at
        }
    }

    private static func actionsLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "automations.today.oneAction", defaultValue: "1 azione")
            : String(localized: "automations.today.actions", defaultValue: "\(count) azioni")
    }
}
