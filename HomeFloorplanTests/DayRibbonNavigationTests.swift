import Testing
import Foundation
@testable import HomeFloorplan

/// L'etichetta del giorno quando non si guarda oggi.
///
/// È l'unica via di ritorno, quindi deve dire sempre qualcosa di leggibile:
/// una data cruda al posto di «Ieri» è già un piccolo fallimento.
@Suite("Avanti e indietro nei giorni")
struct DayRibbonNavigationTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func day(_ offset: Int, from anchor: Date) -> Date {
        calendar.date(byAdding: .day, value: offset, to: anchor)!
    }

    private var anchor: Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 13
        components.hour = 12
        return calendar.date(from: components)!
    }

    @Test("I giorni vicini hanno un nome, non una data")
    func nearbyDaysAreNamed() {
        #expect(DayRibbonView.dayLabel(offset: 0, day: anchor) == "Oggi")
        #expect(DayRibbonView.dayLabel(offset: -1, day: day(-1, from: anchor)) == "Ieri")
        #expect(DayRibbonView.dayLabel(offset: 1, day: day(1, from: anchor)) == "Domani")
    }

    @Test("I giorni lontani mostrano la data")
    func distantDaysShowTheDate() {
        let label = DayRibbonView.dayLabel(offset: -5, day: day(-5, from: anchor))
        #expect(label != "Oggi")
        #expect(label != "Ieri")
        // Deve contenere il numero del giorno: l'8 settembre 2026.
        #expect(label.contains("8"))
    }

    @Test("Ogni giorno nella finestra ha un'etichetta non vuota")
    func everyDayInRangeIsLabelled() {
        for offset in -30...7 {
            let label = DayRibbonView.dayLabel(offset: offset, day: day(offset, from: anchor))
            #expect(!label.trimmingCharacters(in: .whitespaces).isEmpty,
                    "offset \(offset) senza etichetta")
        }
    }

    @Test("Il nastro di un giorno passato colloca i momenti nel giorno giusto")
    func placementsFollowTheVisibleDay() {
        // La frazione è relativa all'intervallo mostrato, non a oggi: è ciò che
        // permette allo stesso disegno di servire qualunque giorno.
        let yesterday = AutomationsView.dayInterval(containing: day(-1, from: anchor),
                                                    calendar: calendar)
        let noon = yesterday.start.addingTimeInterval(12 * 3600)
        let fraction = CGFloat(noon.timeIntervalSince(yesterday.start) / yesterday.duration)
        #expect(abs(fraction - 0.5) < 0.01)
    }
}
