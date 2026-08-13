import Foundation
import Testing
@testable import HomeFloorplan

/// La matematica dei delta del contatore, inchiodata prima della UI: reset,
/// buchi notturni, giorni vuoti — i tre casi che sporcano ogni storico energia.
@Suite("EnergyStatsBuilder — dai contatori ai giorni")
struct EnergyStatsBuilderTests {

    /// Calendario fisso: i test non devono dipendere dal fuso della macchina.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    /// Il 13/08/2026 come «oggi» dei test.
    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                           hour: hour, minute: minute))!
    }

    private var reference: Date { date(day: 13, hour: 15) }

    private func point(day: Int, hour: Int, minute: Int = 0, kWh: Double?) -> EnergyStatsPoint {
        EnergyStatsPoint(timestamp: date(day: day, hour: hour, minute: minute),
                         cumulativeKilowattHours: kWh)
    }

    @Test("Due letture nello stesso giorno: il delta è del giorno")
    func sameDayDelta() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 9, kWh: 100.0),
                     point(day: 13, hour: 12, kWh: 100.6)],
            days: 7, reference: reference, calendar: calendar)
        #expect(totals.count == 7)
        #expect(abs(totals.last!.kilowattHours - 0.6) < 0.0001)
        #expect(totals.dropLast().allSatisfy { $0.kilowattHours == 0 })
    }

    /// Il caso che giustifica lo smear: l'app chiusa di notte non perde
    /// energia, e la notte va pagata dai giorni giusti in proporzione.
    @Test("Intervallo a cavallo della mezzanotte: il delta si spalma pro-rata")
    func overnightSmear() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 12, hour: 22, kWh: 50.0),
                     point(day: 13, hour: 2, kWh: 50.4)],
            days: 7, reference: reference, calendar: calendar)
        // 4 ore totali: 2 di ieri, 2 di oggi → metà e metà.
        let yesterday = totals[totals.count - 2].kilowattHours
        let today = totals[totals.count - 1].kilowattHours
        #expect(abs(yesterday - 0.2) < 0.0001)
        #expect(abs(today - 0.2) < 0.0001)
    }

    /// ⚠️ Il contatore che SCENDE è un reset (ri-pairing): quell'intervallo è
    /// inconoscibile e va scartato — né energia negativa, né valori assoluti.
    /// I delta dopo il reset ripartono dal nuovo zero da soli.
    @Test("Reset del contatore: l'intervallo si scarta, il seguito riparte")
    func counterReset() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 8, kWh: 5.0),
                     point(day: 13, hour: 10, kWh: 5.2),
                     point(day: 13, hour: 11, kWh: 0.1),   // reset!
                     point(day: 13, hour: 13, kWh: 0.3)],
            days: 7, reference: reference, calendar: calendar)
        // 0.2 prima del reset + 0.2 dopo: il salto 5.2→0.1 non conta.
        #expect(abs(totals.last!.kilowattHours - 0.4) < 0.0001)
    }

    @Test("Una lettura sola: nessun delta, giorni tutti a zero ma tutti presenti")
    func singleSample() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 9, kWh: 42.0)],
            days: 7, reference: reference, calendar: calendar)
        #expect(totals.count == 7)
        #expect(totals.allSatisfy { $0.kilowattHours == 0 })
    }

    @Test("Nessuna lettura: la finestra esiste comunque, a zero")
    func emptyInput() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [], days: 7, reference: reference, calendar: calendar)
        #expect(totals.count == 7)
        #expect(totals.allSatisfy { $0.kilowattHours == 0 })
    }

    @Test("L'ordine d'arrivo non conta: il builder ordina da sé")
    func unorderedInput() {
        let ordered = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 9, kWh: 10.0),
                     point(day: 13, hour: 11, kWh: 10.3),
                     point(day: 13, hour: 14, kWh: 10.5)],
            days: 7, reference: reference, calendar: calendar)
        let shuffled = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 14, kWh: 10.5),
                     point(day: 13, hour: 9, kWh: 10.0),
                     point(day: 13, hour: 11, kWh: 10.3)],
            days: 7, reference: reference, calendar: calendar)
        #expect(ordered == shuffled)
        #expect(abs(ordered.last!.kilowattHours - 0.5) < 0.0001)
    }

    /// Un campione di sola potenza (contatore nil) in mezzo a due letture del
    /// contatore non deve spezzare la coppia che porta il delta.
    @Test("I punti senza contatore non spezzano i delta")
    func powerOnlyPointsAreTransparent() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 9, kWh: 20.0),
                     point(day: 13, hour: 10, kWh: nil),
                     point(day: 13, hour: 12, kWh: 20.8)],
            days: 7, reference: reference, calendar: calendar)
        #expect(abs(totals.last!.kilowattHours - 0.8) < 0.0001)
    }

    @Test("La finestra è sempre lunga `days`, dal giorno più vecchio a oggi")
    func windowShape() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 13, hour: 9, kWh: 1.0),
                     point(day: 13, hour: 10, kWh: 1.1)],
            days: 3, reference: reference, calendar: calendar)
        #expect(totals.count == 3)
        #expect(totals.first!.day == calendar.startOfDay(for: date(day: 11, hour: 0)))
        #expect(totals.last!.day == calendar.startOfDay(for: date(day: 13, hour: 0)))
    }

    /// I mensili: stessa matematica dei giornalieri, raggruppata. Un delta
    /// a cavallo di due mesi si divide fra i due in proporzione al tempo.
    @Test("Mensili: finestra sempre piena e delta a cavallo del mese diviso")
    func monthlyTotals() {
        // 31/07 23:00 → 01/08 01:00: 0.4 kWh su 2 ore, metà per mese.
        let july31 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 23))!
        let aug1 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 1))!
        let months = EnergyStatsBuilder.monthlyTotals(
            points: [EnergyStatsPoint(timestamp: july31, cumulativeKilowattHours: 100.0),
                     EnergyStatsPoint(timestamp: aug1, cumulativeKilowattHours: 100.4)],
            months: 12, reference: reference, calendar: calendar)
        #expect(months.count == 12)
        let byMonth = Dictionary(uniqueKeysWithValues: months.map { ($0.day, $0.kilowattHours) })
        let july = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let august = calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        #expect(abs(byMonth[july]! - 0.2) < 0.0001)
        #expect(abs(byMonth[august]! - 0.2) < 0.0001)
    }

    /// Un buco di più giorni: l'energia si distribuisce su TUTTI i giorni
    /// attraversati, non solo sul primo e l'ultimo.
    @Test("Buco di tre giorni: ogni giorno attraversato riceve la sua parte")
    func multiDayGap() {
        let totals = EnergyStatsBuilder.dailyTotals(
            points: [point(day: 10, hour: 0, kWh: 30.0),
                     point(day: 13, hour: 0, kWh: 33.0)],
            days: 7, reference: reference, calendar: calendar)
        // 3.0 kWh su 72 ore esatte → 1.0 al giorno per il 10, 11, 12.
        let byDay = Dictionary(uniqueKeysWithValues: totals.map { ($0.day, $0.kilowattHours) })
        #expect(abs(byDay[calendar.startOfDay(for: date(day: 10, hour: 0))]! - 1.0) < 0.0001)
        #expect(abs(byDay[calendar.startOfDay(for: date(day: 11, hour: 0))]! - 1.0) < 0.0001)
        #expect(abs(byDay[calendar.startOfDay(for: date(day: 12, hour: 0))]! - 1.0) < 0.0001)
        #expect(byDay[calendar.startOfDay(for: date(day: 13, hour: 0))]! < 0.0001)
    }
}
