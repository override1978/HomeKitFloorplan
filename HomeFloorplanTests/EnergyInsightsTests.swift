import Foundation
import Testing
@testable import HomeFloorplan

/// I numeri «intelligenti» della dashboard, a tavolino: proiezioni, base
/// notturna, fasce, giorni critici — con la regola d'oro che dove il dato
/// non basta si risponde nil, mai un numero inventato.
@Suite("EnergyInsights — proiezioni, notti, picchi e giorni critici")
struct EnergyInsightsTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func day(_ dayOfMonth: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: dayOfMonth, hour: hour))!
    }

    @Test("Proiezione: il ritmo di metà mese proiettato a fine mese")
    func projection() {
        #expect(EnergyInsights.monthEndProjection(monthToDate: 155, dayOfMonth: 10, daysInMonth: 31) == 480.5)
        #expect(EnergyInsights.monthEndProjection(monthToDate: 0, dayOfMonth: 10, daysInMonth: 31) == nil)
        #expect(EnergyInsights.monthEndProjection(monthToDate: 100, dayOfMonth: 0, daysInMonth: 31) == nil)
    }

    @Test("Base notturna: 0,08 kWh/ora di notte = 80 W")
    func nightBase() {
        // Due notti complete a 0,08 kWh per ciascuna delle ore 01-04.
        var points: [EnergyStatsPoint] = []
        var cumulative = 100.0
        for dayOffset in [1, 2] {
            for hour in 0...5 {
                points.append(EnergyStatsPoint(
                    timestamp: calendar.date(byAdding: .day, value: -dayOffset, to: day(13, hour: hour))!,
                    cumulativeKilowattHours: cumulative
                ))
                cumulative += 0.08
            }
        }
        let watts = EnergyInsights.nightBaseWatts(points: points, days: 5,
                                                  reference: day(13, hour: 12), calendar: calendar)
        #expect(watts != nil)
        #expect(abs(watts! - 80) < 1)
    }

    @Test("Una notte sola non fa statistica: nil")
    func nightBaseNeedsTwoNights() {
        var points: [EnergyStatsPoint] = []
        var cumulative = 100.0
        for hour in 0...5 {
            points.append(EnergyStatsPoint(
                timestamp: calendar.date(byAdding: .day, value: -1, to: day(13, hour: hour))!,
                cumulativeKilowattHours: cumulative
            ))
            cumulative += 0.08
        }
        #expect(EnergyInsights.nightBaseWatts(points: points, days: 5,
                                              reference: day(13, hour: 12), calendar: calendar) == nil)
    }

    @Test("Fascia 19-22: la quota del giorno che le appartiene")
    func bandShare() {
        var hours: [EnergyDayTotal] = []
        for hour in 0..<24 {
            let value: Double = (19..<22).contains(hour) ? 2.0 : 0.5
            hours.append(EnergyDayTotal(day: day(13, hour: hour), kilowattHours: value))
        }
        let share = EnergyInsights.bandShare(hours: hours, from: 19, to: 22, calendar: calendar)
        // 6 kWh su 16,5 totali ≈ 36%.
        #expect(share != nil)
        #expect(abs(share! - 6.0 / 16.5) < 0.001)
    }

    @Test("Giorni critici: la sequenza sopra media viene trovata col suo rialzo")
    func criticalStretch() {
        var days: [EnergyDayTotal] = []
        // 10 giorni a 10 kWh, poi 3 giorni a 13 (media ≈ 10,7 → +21%).
        for dayOfMonth in 1...10 { days.append(EnergyDayTotal(day: day(dayOfMonth), kilowattHours: 10)) }
        for dayOfMonth in 11...13 { days.append(EnergyDayTotal(day: day(dayOfMonth), kilowattHours: 13)) }
        let stretch = EnergyInsights.criticalStretch(days: days)
        #expect(stretch != nil)
        #expect(stretch?.start == day(11))
        #expect(stretch?.end == day(13))
        #expect(stretch!.upliftPercent > 15)
    }

    @Test("Serie piatta: nessun giorno critico")
    func noCriticalStretch() {
        let days = (1...14).map { EnergyDayTotal(day: day($0), kilowattHours: 10) }
        #expect(EnergyInsights.criticalStretch(days: days) == nil)
    }

    @Test("Confronto col nulla: nil, non infinito")
    func percentChange() {
        #expect(abs(EnergyInsights.percentChange(110, versus: 100)! - 10) < 0.001)
        #expect(EnergyInsights.percentChange(100, versus: 0) == nil)
    }
}
