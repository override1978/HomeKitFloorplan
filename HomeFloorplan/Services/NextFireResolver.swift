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
        if let timer = trigger as? HMTimerTrigger {
            return .timer(first: timer.fireDate, recurrence: timer.recurrence)
        }
        guard let eventTrigger = trigger as? HMEventTrigger else { return nil }

        for event in eventTrigger.events {
            if let solarEvent = event as? HMSignificantTimeEvent {
                let kind: SolarEvent = (solarEvent.significantEvent == .sunset) ? .sunset : .sunrise
                return .solar(kind, offset: seconds(from: solarEvent.offset))
            }
            if let calendarEvent = event as? HMCalendarEvent {
                return .dailyTime(calendarEvent.fireDateComponents)
            }
        }
        return nil
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
