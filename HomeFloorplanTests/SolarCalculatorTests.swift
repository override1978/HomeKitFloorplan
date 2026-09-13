import Testing
import Foundation
@testable import HomeFloorplan

/// Alba e tramonto calcolati, confrontati con valori noti.
///
/// La tolleranza è di tre minuti: la formula chiusa non tiene conto di
/// elevazione e condizioni locali, e su un asse largo ottocento punti tre
/// minuti sono due punti. Serve che sia giusta, non che sia un almanacco.
@Suite("Il sole per un giorno qualunque")
struct SolarCalculatorTests {

    private let rome = SolarCalculator.Coordinates(latitude: 41.9028, longitude: 12.4964)
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        return calendar.date(from: components)!
    }

    private func localTime(_ date: Date) -> (hour: Int, minute: Int) {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? -1, c.minute ?? -1)
    }

    private func minutes(_ date: Date) -> Int {
        let t = localTime(date)
        return t.hour * 60 + t.minute
    }

    @Test("Equinozio di settembre a Roma: giorno e notte quasi pari")
    func septemberEquinox() throws {
        let events = SolarCalculator.events(on: day(2026, 9, 22), at: rome, calendar: calendar)
        let sunrise = try #require(events.sunrise)
        let sunset = try #require(events.sunset)
        // Riferimento: alba ~06:58, tramonto ~19:08 (CEST).
        #expect(abs(minutes(sunrise) - (6 * 60 + 58)) <= 3)
        #expect(abs(minutes(sunset) - (19 * 60 + 8)) <= 3)
    }

    @Test("Solstizio d'estate: il giorno più lungo")
    func summerSolstice() throws {
        let events = SolarCalculator.events(on: day(2026, 6, 21), at: rome, calendar: calendar)
        let sunrise = try #require(events.sunrise)
        let sunset = try #require(events.sunset)
        // Riferimento: alba ~05:35, tramonto ~20:48 (CEST).
        #expect(abs(minutes(sunrise) - (5 * 60 + 35)) <= 3)
        #expect(abs(minutes(sunset) - (20 * 60 + 48)) <= 3)
    }

    @Test("Solstizio d'inverno: il giorno più corto")
    func winterSolstice() throws {
        let events = SolarCalculator.events(on: day(2026, 12, 21), at: rome, calendar: calendar)
        let sunrise = try #require(events.sunrise)
        let sunset = try #require(events.sunset)
        // Riferimento: alba ~07:35, tramonto ~16:43 (CET, ora solare).
        #expect(abs(minutes(sunrise) - (7 * 60 + 35)) <= 3)
        #expect(abs(minutes(sunset) - (16 * 60 + 43)) <= 3)
    }

    @Test("L'alba precede sempre il tramonto, e cadono nel giorno giusto")
    func orderAndDay() throws {
        for offset in -30...7 {
            let target = calendar.date(byAdding: .day, value: offset, to: day(2026, 9, 13))!
            let events = SolarCalculator.events(on: target, at: rome, calendar: calendar)
            let sunrise = try #require(events.sunrise)
            let sunset = try #require(events.sunset)
            #expect(sunrise < sunset)
            #expect(calendar.isDate(sunrise, inSameDayAs: target))
            #expect(calendar.isDate(sunset, inSameDayAs: target))
        }
    }

    @Test("Il giorno si allunga avvicinandosi al solstizio")
    func daysGrowTowardSolstice() throws {
        func length(_ date: Date) throws -> TimeInterval {
            let events = SolarCalculator.events(on: date, at: rome, calendar: calendar)
            return try #require(events.sunset).timeIntervalSince(try #require(events.sunrise))
        }
        #expect(try length(day(2026, 3, 1)) < length(day(2026, 5, 1)))
        #expect(try length(day(2026, 5, 1)) < length(day(2026, 6, 21)))
    }

    @Test("Oltre il circolo polare, in estate, non c'è tramonto")
    func polarDayHasNoAnswer() {
        let tromso = SolarCalculator.Coordinates(latitude: 69.65, longitude: 18.96)
        let events = SolarCalculator.events(on: day(2026, 6, 21), at: tromso, calendar: calendar)
        #expect(events.sunrise == nil)
        #expect(events.sunset == nil)
    }

    @Test("Il giorno giuliano fa avanti e indietro")
    func julianRoundTrip() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let back = SolarCalculator.date(fromJulian: SolarCalculator.julian(from: now))
        #expect(abs(back.timeIntervalSince(now)) < 0.001)
    }
}
