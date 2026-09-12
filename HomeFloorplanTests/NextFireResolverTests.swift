import Foundation
import Testing
@testable import HomeFloorplan

@Suite("NextFireResolver — quando scatterà")
struct NextFireResolverTests {

    // MARK: - Fixture

    /// Calendario fisso: fuso di Roma e gregoriano, così i casi di cambio d'ora
    /// sono riproducibili ovunque giri la suite.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        c.locale = Locale(identifier: "it_IT")
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: - Timer una tantum

    @Test("Un timer non ricorrente nel futuro scatta a quella data")
    func oneShotInFuture() {
        let fire = date(2026, 9, 20, 7, 30)
        let next = NextFireResolver.next(for: .timer(first: fire, recurrence: nil),
                                         after: date(2026, 9, 12, 9), calendar: cal)
        #expect(next == fire)
    }

    @Test("Un timer non ricorrente già passato non scatterà più")
    func oneShotInPast() {
        let next = NextFireResolver.next(for: .timer(first: date(2026, 9, 1, 7), recurrence: nil),
                                         after: date(2026, 9, 12, 9), calendar: cal)
        #expect(next == nil, "una tantum vuol dire una volta sola")
    }

    // MARK: - Ricorrenze

    @Test("Giornaliero: se l'ora di oggi è passata, tocca a domani")
    func dailyRollsToTomorrow() {
        let next = NextFireResolver.next(
            for: .timer(first: date(2026, 9, 10, 7), recurrence: DateComponents(day: 1)),
            after: date(2026, 9, 12, 9), calendar: cal)
        #expect(next == date(2026, 9, 13, 7))
    }

    @Test("Giornaliero: se l'ora di oggi deve ancora venire, è oggi")
    func dailyStaysToday() {
        let next = NextFireResolver.next(
            for: .timer(first: date(2026, 9, 10, 7), recurrence: DateComponents(day: 1)),
            after: date(2026, 9, 12, 6), calendar: cal)
        #expect(next == date(2026, 9, 12, 7))
    }

    @Test("Settimanale: avanza di sette giorni per volta")
    func weeklyStep() {
        let next = NextFireResolver.next(
            for: .timer(first: date(2026, 9, 7, 8), recurrence: DateComponents(weekOfYear: 1)),
            after: date(2026, 9, 12, 9), calendar: cal)
        #expect(next == date(2026, 9, 14, 8), "stesso giorno della settimana, sette giorni dopo")
    }

    @Test("Un primo scatto dimenticato anni indietro si risolve lo stesso")
    func veryOldFireDateStillResolves() throws {
        let next = try #require(NextFireResolver.next(
            for: .timer(first: date(2024, 1, 1, 6, 45), recurrence: DateComponents(day: 1)),
            after: date(2026, 9, 12, 9), calendar: cal))
        #expect(next == date(2026, 9, 13, 6, 45))
    }

    @Test("Una ricorrenza che non avanza non manda in ciclo: risponde nil")
    func zeroRecurrenceDoesNotLoop() {
        let next = NextFireResolver.next(
            for: .timer(first: date(2026, 9, 1, 7), recurrence: DateComponents()),
            after: date(2026, 9, 12, 9), calendar: cal)
        #expect(next == nil, "meglio ammettere di non saperlo che girare a vuoto")
    }

    @Test("Attraverso il cambio d'ora il timer resta alla stessa ora di orologio")
    func survivesDaylightSavingChange() {
        // In Italia l'ora solare torna domenica 25 ottobre 2026.
        let next = NextFireResolver.next(
            for: .timer(first: date(2026, 10, 24, 7), recurrence: DateComponents(day: 1)),
            after: date(2026, 10, 24, 9), calendar: cal)
        #expect(next == date(2026, 10, 25, 7),
                "è il motivo per cui si avanza col calendario invece di sommare 86.400 secondi")
    }

    // MARK: - Sole

    @Test("Tramonto: se deve ancora venire, è quello di oggi")
    func sunsetToday() {
        let solar = NextFireResolver.SolarTimes(
            todaySunset: date(2026, 9, 12, 19, 32),
            tomorrowSunset: date(2026, 9, 13, 19, 30))
        let next = NextFireResolver.next(for: .solar(.sunset, offset: 0),
                                         after: date(2026, 9, 12, 15),
                                         solar: solar, calendar: cal)
        #expect(next == date(2026, 9, 12, 19, 32))
    }

    @Test("Tramonto: se è già passato, è quello di domani")
    func sunsetRollsToTomorrow() {
        let solar = NextFireResolver.SolarTimes(
            todaySunset: date(2026, 9, 12, 19, 32),
            tomorrowSunset: date(2026, 9, 13, 19, 30))
        let next = NextFireResolver.next(for: .solar(.sunset, offset: 0),
                                         after: date(2026, 9, 12, 21),
                                         solar: solar, calendar: cal)
        #expect(next == date(2026, 9, 13, 19, 30),
                "e non il tramonto di oggi più ventiquattro ore: i minuti non coincidono")
    }

    @Test("Lo scarto si applica prima del confronto")
    func offsetIsAppliedBeforeComparing() {
        let solar = NextFireResolver.SolarTimes(todaySunset: date(2026, 9, 12, 19, 30))
        // «Trenta minuti prima del tramonto», guardato alle 19:15: è già passato.
        let past = NextFireResolver.next(for: .solar(.sunset, offset: -30 * 60),
                                         after: date(2026, 9, 12, 19, 15),
                                         solar: solar, calendar: cal)
        #expect(past == nil, "senza il tramonto di domani non c'è più nulla da promettere")

        let upcoming = NextFireResolver.next(for: .solar(.sunset, offset: -30 * 60),
                                             after: date(2026, 9, 12, 18),
                                             solar: solar, calendar: cal)
        #expect(upcoming == date(2026, 9, 12, 19), "trenta minuti prima delle 19:30")
    }

    @Test("Alba e tramonto non si confondono")
    func sunriseAndSunsetAreDistinct() {
        let solar = NextFireResolver.SolarTimes(
            todaySunrise: date(2026, 9, 12, 6, 58),
            todaySunset:  date(2026, 9, 12, 19, 32))
        let atDawn = NextFireResolver.next(for: .solar(.sunrise, offset: 0),
                                           after: date(2026, 9, 12, 3),
                                           solar: solar, calendar: cal)
        #expect(atDawn == date(2026, 9, 12, 6, 58))
    }

    @Test("Senza istanti solari non si indovina")
    func noSolarDataMeansNoAnswer() {
        let next = NextFireResolver.next(for: .solar(.sunset, offset: 0),
                                         after: date(2026, 9, 12, 15),
                                         solar: NextFireResolver.SolarTimes(), calendar: cal)
        #expect(next == nil)
    }

    // MARK: - Ora fissa

    @Test("Ora del giorno fissa: la prossima occorrenza")
    func dailyTimeFindsNextOccurrence() {
        let next = NextFireResolver.next(for: .dailyTime(DateComponents(hour: 23, minute: 0)),
                                         after: date(2026, 9, 12, 9), calendar: cal)
        #expect(next == date(2026, 9, 12, 23))

        let tomorrow = NextFireResolver.next(for: .dailyTime(DateComponents(hour: 23, minute: 0)),
                                             after: date(2026, 9, 12, 23, 30), calendar: cal)
        #expect(tomorrow == date(2026, 9, 13, 23))
    }
}

// MARK: - Pulizia del nome

@Suite("ScheduledFire — il nome non ripete l'ora già in colonna")
struct ScheduledFireNameTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    private func fire(_ h: Int, _ m: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: h, minute: m))!
    }

    private func strip(_ name: String, _ h: Int, _ m: Int) -> String {
        HomeKitAutomationsService.strippingRedundantTime(from: name, firingAt: fire(h, m), calendar: cal)
    }

    @Test("«Alle 20:30 Chiudi la Tenda» diventa «Chiudi la Tenda»")
    func stripsItalianPrefix() {
        #expect(strip("Alle 20:30 Chiudi la Tenda in Cucina", 20, 30) == "Chiudi la Tenda in Cucina")
    }

    @Test("Funziona anche senza parola di servizio davanti")
    func stripsBareTime() {
        #expect(strip("22:00 Attivo Antifurto", 22, 0) == "Attivo Antifurto")
    }

    @Test("Tollera i separatori dopo l'ora")
    func stripsSeparators() {
        #expect(strip("Alle 23:00 - Spegni Purificatore", 23, 0) == "Spegni Purificatore")
        #expect(strip("23.00 — Spegni Purificatore", 23, 0) == "Spegni Purificatore")
    }

    @Test("Se l'ora nel nome non è quella dello scatto non si tocca niente")
    func leavesMismatchedTimeAlone() {
        #expect(strip("Alle 07:00 Sveglia", 20, 30) == "Alle 07:00 Sveglia",
                "togliere un orario diverso cancellerebbe informazione vera")
    }

    @Test("Un nome senza orario resta intatto")
    func leavesPlainNameAlone() {
        #expect(strip("Modalità Notturna", 22, 30) == "Modalità Notturna")
    }

    @Test("Un nome fatto solo dell'ora si tiene com'è")
    func keepsTimeOnlyName() {
        #expect(strip("Alle 22:30", 22, 30) == "Alle 22:30",
                "svuotarlo lascerebbe una riga senza titolo")
    }

    @Test("Se dopo l'ora la frase continua in minuscolo non si taglia niente")
    func doesNotMutilateSentences() {
        // Nomi generati dall'app Casa: l'ora è incastrata nella frase.
        #expect(strip("Alle 9:00 di ogni giorno Attiva Purificatore", 9, 0)
                == "Alle 9:00 di ogni giorno Attiva Purificatore",
                "togliere solo l'ora lascerebbe «di ogni giorno Attiva Purificatore»")
        #expect(strip("Alle 2:00 del mattino imposta la Buonanotte", 2, 0)
                == "Alle 2:00 del mattino imposta la Buonanotte")
    }

    @Test("Il formato a dodici ore non combacia e passa indenne")
    func twelveHourFormatUntouched() {
        #expect(strip("At 8:30 PM Close the blinds", 20, 30) == "At 8:30 PM Close the blinds")
    }
}

// MARK: - La giornata intera

@Suite("NextFireResolver — tutti gli scatti di una giornata")
struct NextFireOccurrencesTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }

    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h, minute: m))!
    }

    private var today: DateInterval {
        DateInterval(start: date(12, 0), end: date(13, 0))
    }

    @Test("Un giornaliero compare una volta, anche se il primo scatto è di mesi fa")
    func dailyAppearsOnceInTheDay() {
        let fires = NextFireResolver.occurrences(
            for: .timer(first: date(1, 7, 15), recurrence: DateComponents(day: 1)),
            in: today, calendar: cal)
        #expect(fires == [date(12, 7, 15)])
    }

    @Test("Il mattino non sparisce solo perché è pomeriggio")
    func pastOccurrencesAreIncluded() {
        let fires = NextFireResolver.occurrences(
            for: .timer(first: date(12, 7, 0), recurrence: DateComponents(day: 1)),
            in: today, calendar: cal)
        #expect(fires.first == date(12, 7, 0),
                "guardando solo avanti alle 16 questa riga non esisterebbe")
    }

    @Test("Una ricorrenza oraria produce tutte le sue occorrenze del giorno")
    func hourlyFillsTheDay() {
        let fires = NextFireResolver.occurrences(
            for: .timer(first: date(12, 0), recurrence: DateComponents(hour: 6)),
            in: today, calendar: cal)
        #expect(fires == [date(12, 0), date(12, 6), date(12, 12), date(12, 18), date(13, 0)])
    }

    @Test("Un settimanale che non cade oggi non compare")
    func weeklyOutsideTheDayIsAbsent() {
        let fires = NextFireResolver.occurrences(
            for: .timer(first: date(7, 8), recurrence: DateComponents(weekOfYear: 1)),
            in: today, calendar: cal)
        #expect(fires.isEmpty, "il prossimo è il 14, non oggi")
    }

    @Test("Una tantum: compare solo se cade dentro la giornata")
    func oneShotInsideAndOutside() {
        #expect(NextFireResolver.occurrences(
            for: .timer(first: date(12, 9, 30), recurrence: nil),
            in: today, calendar: cal) == [date(12, 9, 30)])
        #expect(NextFireResolver.occurrences(
            for: .timer(first: date(20, 9, 30), recurrence: nil),
            in: today, calendar: cal).isEmpty)
    }

    @Test("Il tramonto di oggi compare anche quando è già passato")
    func sunsetOfTodayIsListed() {
        let solar = NextFireResolver.SolarTimes(
            todaySunset: date(12, 19, 32),
            tomorrowSunset: date(13, 19, 30))
        let fires = NextFireResolver.occurrences(for: .solar(.sunset, offset: 0),
                                                 in: today, solar: solar, calendar: cal)
        #expect(fires == [date(12, 19, 32)], "quello di domani è fuori dalla finestra")
    }

    @Test("Un'ora fissa del giorno compare una volta")
    func dailyTimeAppearsOnce() {
        let fires = NextFireResolver.occurrences(
            for: .dailyTime(DateComponents(hour: 23, minute: 0)),
            in: today, calendar: cal)
        #expect(fires == [date(12, 23, 0)])
    }

    @Test("Una ricorrenza al minuto viene troncata invece di produrre un log")
    func pathologicalRecurrenceIsCapped() {
        let fires = NextFireResolver.occurrences(
            for: .timer(first: date(12, 0), recurrence: DateComponents(minute: 1)),
            in: today, calendar: cal)
        #expect(fires.count <= 500)
        #expect(fires.count > 0)
    }

    @Test("Una ricorrenza che non avanza non manda in ciclo")
    func zeroRecurrenceIsSafe() {
        let fires = NextFireResolver.occurrences(
            for: .timer(first: date(12, 8), recurrence: DateComponents()),
            in: today, calendar: cal)
        #expect(fires == [date(12, 8)], "senza passo resta il solo primo scatto")
    }
}
