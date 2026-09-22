import Foundation
import HomeKit

// MARK: - NextFireResolver

/// Quando un'automazione scatterà la prossima volta.
///
/// È il pezzo che mancava. Nessuna riga dell'app sapeva guardare avanti:
/// `HMTimerTrigger.fireDate` veniva letto solo per formattarlo come stringa, e
/// un'automazione legata al tramonto si descriveva con la parola «Tramonto»
/// senza che nessuno risolvesse *quando*. Da qui l'impossibilità di rispondere
/// alla domanda più semplice che si possa fare a una casa: **cosa farai oggi?**
///
/// Serve due volte, ed è la ragione per cui vale più di quanto costi. La prima
/// è mostrare il futuro. La seconda è tacere: se un'automazione sta per
/// sistemare la cosa da sola fra dieci minuti, quella cosa non è una
/// notifica — e per saperlo bisogna conoscere il prossimo scatto.
///
/// Il nucleo è puro e non conosce HomeKit: prende una pianificazione e degli
/// istanti solari e restituisce una data. La traduzione dai trigger sta in
/// fondo, separata, così le regole di calendario si possono provare senza una
/// casa vera.
enum NextFireResolver {

    // MARK: - Tipi

    enum SolarEvent: Equatable, Sendable { case sunrise, sunset }

    /// Ciò che di un trigger si può collocare nel tempo.
    ///
    /// Gli eventi di presenza, posizione e caratteristica non compaiono di
    /// proposito: non hanno un «quando». Fingere una previsione per loro
    /// sarebbe peggio che ammettere di non saperlo.
    enum Schedule: Equatable, Sendable {
        /// Timer HomeKit: primo scatto e, se ricorre, il passo.
        case timer(first: Date, recurrence: DateComponents?)
        /// Evento solare con scarto (negativo = prima dell'evento).
        case solar(SolarEvent, offset: TimeInterval)
        /// Ora del giorno fissa, dai componenti di un evento di calendario.
        case dailyTime(DateComponents)
    }

    /// Una pianificazione **con i giorni in cui vale**.
    ///
    /// Nasce da un baco vero: `Schedule` diceva *a che ora*, e nessuno diceva
    /// *in quali giorni*. HomeKit tiene la restrizione settimanale in
    /// `HMEventTrigger.recurrences`, separata dall'evento, e leggendo solo
    /// l'ora un'automazione del lunedi' compariva sul nastro tutti i giorni.
    ///
    /// Le due cose stanno insieme in un tipo solo proprio perche' separarle e'
    /// stato l'errore: chi risolve una pianificazione non deve poter
    /// dimenticare i giorni.
    struct Plan: Equatable, Sendable {
        var schedule: Schedule
        /// Giorni attivi, nella numerazione di `Calendar` (1 = domenica).
        /// `nil` significa tutti i giorni, non nessuno.
        var weekdays: Set<Int>?

        init(schedule: Schedule, weekdays: Set<Int>? = nil) {
            self.schedule = schedule
            self.weekdays = (weekdays?.isEmpty ?? true) ? nil : weekdays
        }

        func isActive(on date: Date, calendar: Calendar) -> Bool {
            guard let weekdays else { return true }
            return weekdays.contains(calendar.component(.weekday, from: date))
        }
    }

    /// Gli istanti solari noti. `nil` dove non li sappiamo.
    ///
    /// Si passano invece di calcolarli qui perché il sole è un fatto del posto
    /// in cui sta la casa, non di questo file: arrivano da WeatherKit, che sa
    /// dove siamo.
    struct SolarTimes: Equatable, Sendable {
        var todaySunrise: Date?
        var todaySunset: Date?
        var tomorrowSunrise: Date?
        var tomorrowSunset: Date?

        init(todaySunrise: Date? = nil,
             todaySunset: Date? = nil,
             tomorrowSunrise: Date? = nil,
             tomorrowSunset: Date? = nil) {
            self.todaySunrise = todaySunrise
            self.todaySunset = todaySunset
            self.tomorrowSunrise = tomorrowSunrise
            self.tomorrowSunset = tomorrowSunset
        }
    }

    /// Tetto di iterazioni quando si avanza di un passo alla volta.
    ///
    /// Si avanza con `Calendar` e non con l'aritmetica perché un passo
    /// giornaliero attraverso il cambio d'ora non dura ventiquattro ore, e
    /// sommare secondi sbaglierebbe di un'ora due volte l'anno. Il prezzo è
    /// iterare; il tetto evita che un `fireDate` dimenticato anni indietro
    /// faccia girare a vuoto — a passo giornaliero copre oltre cinque anni.
    private static let maxRecurrenceSteps = 2_000

    // MARK: - Nucleo

    /// Il prossimo istante in cui questa pianificazione scatta, dopo `now`.
    ///
    /// `nil` quando non scatterà più (un timer una tantum già passato) o
    /// quando manca il dato per saperlo (un evento solare senza istanti solari).
    static func next(for schedule: Schedule,
                     after now: Date,
                     solar: SolarTimes = SolarTimes(),
                     calendar: Calendar = .current) -> Date? {
        switch schedule {
        case let .timer(first, recurrence):
            return nextTimer(first: first, recurrence: recurrence, after: now, calendar: calendar)
        case let .solar(event, offset):
            return nextSolar(event: event, offset: offset, after: now, solar: solar)
        case let .dailyTime(components):
            return calendar.nextDate(after: now,
                                     matching: components,
                                     matchingPolicy: .nextTime,
                                     direction: .forward)
        }
    }

    /// Tutte le volte che questa pianificazione scatta dentro un intervallo.
    ///
    /// `next` risponde a «e adesso?», questa a «e la giornata?». Sono due
    /// domande diverse e la seconda non si ottiene dalla prima: guardando solo
    /// avanti, alle quattro del pomeriggio metà dei momenti di una casa sono
    /// già passati e invisibili, e si finisce per giudicare quanto sia densa
    /// una giornata avendone vista mezza.
    ///
    /// Gli istanti restituiti sono quelli **previsti**. Che l'automazione sia
    /// davvero scattata è un'altra cosa: poteva essere disabilitata allora, le
    /// condizioni potevano non essere soddisfatte, HomeKit poteva mancarla. Per
    /// sapere cosa è successo davvero serve il registro degli eventi, non
    /// questo calcolo.
    static func occurrences(for schedule: Schedule,
                            in interval: DateInterval,
                            solar: SolarTimes = SolarTimes(),
                            calendar: Calendar = .current) -> [Date] {
        switch schedule {
        case let .timer(first, recurrence):
            return timerOccurrences(first: first, recurrence: recurrence,
                                    in: interval, calendar: calendar)

        case let .solar(event, offset):
            let candidates: [Date?] = {
                switch event {
                case .sunrise: return [solar.todaySunrise, solar.tomorrowSunrise]
                case .sunset:  return [solar.todaySunset,  solar.tomorrowSunset]
                }
            }()
            return candidates
                .compactMap { $0?.addingTimeInterval(offset) }
                .filter { interval.contains($0) }
                .sorted()

        case let .dailyTime(components):
            var out: [Date] = []
            calendar.enumerateDates(startingAfter: interval.start.addingTimeInterval(-1),
                                    matching: components,
                                    matchingPolicy: .nextTime) { date, _, stop in
                guard let date, date <= interval.end, out.count < maxOccurrencesPerWindow else {
                    stop = true; return
                }
                out.append(date)
            }
            return out
        }
    }

    /// Il prossimo scatto di una pianificazione, rispettandone i giorni.
    ///
    /// Si avanza di giorno in giorno perche' la restrizione settimanale non si
    /// puo' applicare al solo primo risultato: un'automazione del lunedi'
    /// chiesta di martedi' non ha «nessun prossimo scatto», ne ha uno fra sei
    /// giorni.
    static func next(for plan: Plan,
                     after now: Date,
                     solar: SolarTimes = SolarTimes(),
                     calendar: Calendar = .current) -> Date? {
        guard plan.weekdays != nil else {
            return next(for: plan.schedule, after: now, solar: solar, calendar: calendar)
        }

        var cursor = now
        for _ in 0..<8 {
            guard let candidate = next(for: plan.schedule, after: cursor,
                                       solar: solar, calendar: calendar) else { return nil }
            if plan.isActive(on: candidate, calendar: calendar) { return candidate }
            cursor = candidate
        }
        return nil
    }

    /// Gli scatti dentro un intervallo, rispettandone i giorni.
    static func occurrences(for plan: Plan,
                            in interval: DateInterval,
                            solar: SolarTimes = SolarTimes(),
                            calendar: Calendar = .current) -> [Date] {
        occurrences(for: plan.schedule, in: interval, solar: solar, calendar: calendar)
            .filter { plan.isActive(on: $0, calendar: calendar) }
    }

    /// Tetto di scatti restituiti per finestra.
    ///
    /// Una ricorrenza al minuto produrrebbe 1.440 righe per una giornata: un
    /// elenco così non è una scaletta, è un log. Meglio troncare e restare
    /// leggibili.
    private static let maxOccurrencesPerWindow = 500

    private static func timerOccurrences(first: Date,
                                         recurrence: DateComponents?,
                                         in interval: DateInterval,
                                         calendar: Calendar) -> [Date] {
        guard let recurrence, hasPositiveStep(recurrence) else {
            return interval.contains(first) ? [first] : []
        }
        guard first <= interval.end else { return [] }

        var candidate = first
        var steps = 0
        // Porta il candidato dentro la finestra.
        while candidate < interval.start && steps < maxRecurrenceSteps {
            guard let advanced = calendar.date(byAdding: recurrence, to: candidate),
                  advanced > candidate else { return [] }
            candidate = advanced
            steps += 1
        }

        var out: [Date] = []
        while candidate <= interval.end && out.count < maxOccurrencesPerWindow {
            out.append(candidate)
            guard let advanced = calendar.date(byAdding: recurrence, to: candidate),
                  advanced > candidate else { break }
            candidate = advanced
        }
        return out
    }

    // MARK: - Timer

    private static func nextTimer(first: Date,
                                  recurrence: DateComponents?,
                                  after now: Date,
                                  calendar: Calendar) -> Date? {
        if first > now { return first }

        // Senza ricorrenza, un primo scatto già passato è passato e basta.
        guard let recurrence, hasPositiveStep(recurrence) else { return nil }

        var candidate = first
        var steps = 0
        while candidate <= now && steps < maxRecurrenceSteps {
            guard let advanced = calendar.date(byAdding: recurrence, to: candidate),
                  advanced > candidate       // difesa: un passo che non avanza è un ciclo infinito
            else { return nil }
            candidate = advanced
            steps += 1
        }
        return candidate > now ? candidate : nil
    }

    /// Vero se la ricorrenza contiene almeno un campo che fa avanzare il tempo.
    private static func hasPositiveStep(_ components: DateComponents) -> Bool {
        let fields: [Int?] = [
            components.second, components.minute, components.hour,
            components.day, components.weekday, components.weekOfYear,
            components.month, components.year
        ]
        return fields.contains { ($0 ?? 0) > 0 }
    }

    // MARK: - Sole

    private static func nextSolar(event: SolarEvent,
                                  offset: TimeInterval,
                                  after now: Date,
                                  solar: SolarTimes) -> Date? {
        let candidates: [Date?] = {
            switch event {
            case .sunrise: return [solar.todaySunrise, solar.tomorrowSunrise]
            case .sunset:  return [solar.todaySunset,  solar.tomorrowSunset]
            }
        }()

        // Lo scarto si applica prima del confronto: un'automazione «trenta
        // minuti prima del tramonto» scatta prima del tramonto, e a quell'ora
        // va confrontata.
        return candidates
            .compactMap { $0?.addingTimeInterval(offset) }
            .filter { $0 > now }
            .min()
    }
}

// MARK: - Traduzione dai trigger HomeKit

extension NextFireResolver {

    /// Riduce un trigger HomeKit a una pianificazione, quando ne ha una.
    ///
    /// Restituisce `nil` per presenza, posizione e caratteristiche: quelle
    /// automazioni esistono ma non hanno un momento: dipendono da qualcuno che
    /// rientra o da un valore che cambia.
    static func schedule(for trigger: HMTrigger) -> Schedule? {
        plan(for: trigger)?.schedule
    }

    /// Riduce un trigger HomeKit a una pianificazione **con i suoi giorni**.
    ///
    /// I giorni arrivano da `recurrences`, che HomeKit tiene sul trigger e non
    /// sull'evento: e' un elenco di `DateComponents` con il solo `weekday`, ed
    /// e' la stessa forma che l'app scrive quando crea un'automazione a giorni.
    /// Vuoto o assente vuol dire tutti i giorni.
    static func plan(for trigger: HMTrigger) -> Plan? {
        if let timer = trigger as? HMTimerTrigger {
            // I timer non hanno `recurrences`: la cadenza sta tutta in
            // `recurrence`, e l'aritmetica del calendario la rispetta gia'.
            return Plan(schedule: .timer(first: timer.fireDate, recurrence: timer.recurrence))
        }
        guard let eventTrigger = trigger as? HMEventTrigger else { return nil }

        let weekdays = activeWeekdays(from: eventTrigger.recurrences)

        for event in eventTrigger.events {
            if let solarEvent = event as? HMSignificantTimeEvent {
                let kind: SolarEvent = (solarEvent.significantEvent == .sunset) ? .sunset : .sunrise
                return Plan(schedule: .solar(kind, offset: seconds(from: solarEvent.offset)),
                            weekdays: weekdays)
            }
            if let calendarEvent = event as? HMCalendarEvent {
                return Plan(schedule: .dailyTime(calendarEvent.fireDateComponents),
                            weekdays: weekdays)
            }
        }
        return nil
    }

    /// I giorni attivi estratti dalle ricorrenze HomeKit.
    ///
    /// `nil` quando non c'e' restrizione: nessuna ricorrenza, oppure tutti e
    /// sette i giorni — che vuol dire la stessa cosa e conviene ridurre allo
    /// stesso valore, cosi' a valle non esistono due modi di dire «sempre».
    static func activeWeekdays(from recurrences: [DateComponents]?) -> Set<Int>? {
        guard let recurrences, !recurrences.isEmpty else { return nil }
        let days = Set(recurrences.compactMap(\.weekday).filter { (1...7).contains($0) })
        return (days.isEmpty || days.count == 7) ? nil : days
    }

    /// Converte lo scarto di un evento solare in secondi.
    ///
    /// HomeKit lo esprime come componenti, di solito minuti o ore, e ammette
    /// valori negativi per «prima dell'evento».
    private static func seconds(from components: DateComponents?) -> TimeInterval {
        guard let components else { return 0 }
        let hours   = TimeInterval(components.hour   ?? 0) * 3600
        let minutes = TimeInterval(components.minute ?? 0) * 60
        let seconds = TimeInterval(components.second ?? 0)
        return hours + minutes + seconds
    }
}
