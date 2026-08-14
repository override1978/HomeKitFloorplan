import Foundation

// MARK: - EnergyInsights

/// I numeri «intelligenti» della dashboard energia: proiezioni, basi
/// notturne, picchi, concentrazioni di fascia, giorni critici. Tutto puro e
/// derivato dagli stessi punti-contatore della pipeline — niente stime
/// tirate a caso: dove il dato non c'è, si risponde `nil` e la UI tace.
enum EnergyInsights {

    // MARK: Proiezione

    /// Fine mese proiettata dal ritmo tenuto finora: totale/giorni × giorni
    /// del mese. Grezza per scelta — è una proiezione, non una promessa.
    static func monthEndProjection(monthToDate: Double, dayOfMonth: Int, daysInMonth: Int) -> Double? {
        guard dayOfMonth > 0, daysInMonth >= dayOfMonth, monthToDate > 0 else { return nil }
        return monthToDate / Double(dayOfMonth) * Double(daysInMonth)
    }

    // MARK: Base notturna

    /// La potenza costante che la casa tira quando dorme: media delle ore
    /// 01:00–05:00 sugli ultimi giorni con granularità oraria. In Watt.
    /// `nil` se le notti coperte sono meno di 2 — una notte sola è aneddoto.
    static func nightBaseWatts(points: [EnergyStatsPoint],
                               days: Int = 14,
                               reference: Date = .now,
                               calendar: Calendar = .current) -> Double? {
        var nightHourValues: [Double] = []
        for offset in 1...days {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: reference) else { continue }
            let hours = EnergyStatsBuilder.hourlyTotals(points: points, day: day, calendar: calendar)
            let night = hours.filter { (1...4).contains(calendar.component(.hour, from: $0.day)) }
            let values = night.map(\.kilowattHours).filter { $0 > 0 }
            // La notte conta solo se è coperta per intero: 4 ore su 4.
            if values.count == 4 { nightHourValues.append(contentsOf: values) }
        }
        guard nightHourValues.count >= 8 else { return nil }
        let averageKilowattHoursPerHour = nightHourValues.reduce(0, +) / Double(nightHourValues.count)
        return averageKilowattHoursPerHour * 1_000
    }

    // MARK: Picchi

    /// L'ora più energivora di un giorno, come potenza media di quell'ora.
    static func peakHour(hours: [EnergyDayTotal]) -> (hour: Date, kilowatts: Double)? {
        guard let peak = hours.max(by: { $0.kilowattHours < $1.kilowattHours }),
              peak.kilowattHours > 0 else { return nil }
        return (peak.day, peak.kilowatts)
    }

    /// Il giorno più energivoro di una serie.
    static func peakDay(days: [EnergyDayTotal]) -> EnergyDayTotal? {
        guard let peak = days.max(by: { $0.kilowattHours < $1.kilowattHours }),
              peak.kilowattHours > 0 else { return nil }
        return peak
    }

    // MARK: Fasce

    /// Quanta parte del giorno si concentra nella fascia oraria [from, to):
    /// 0...1. `nil` se il giorno non ha forma oraria.
    static func bandShare(hours: [EnergyDayTotal],
                          from: Int, to: Int,
                          calendar: Calendar = .current) -> Double? {
        let total = hours.map(\.kilowattHours).reduce(0, +)
        guard total > 0 else { return nil }
        let band = hours
            .filter { (from..<to).contains(calendar.component(.hour, from: $0.day)) }
            .map(\.kilowattHours)
            .reduce(0, +)
        return band / total
    }

    /// Il profilo medio delle 24 ore su un insieme di giorni: kW medi per
    /// ora. Contano solo i giorni con forma oraria vera (≥ 20 ore attive di
    /// campioni non fa testo qui: basta che il totale del giorno sia > 0 e le
    /// ore siano distribuite, il chiamante passa giorni della finestra oraria).
    static func averageDayProfile(points: [EnergyStatsPoint],
                                  days: [Date],
                                  calendar: Calendar = .current) -> [Double]? {
        var sums = [Double](repeating: 0, count: 24)
        var coveredDays = 0
        for day in days {
            let hours = EnergyStatsBuilder.hourlyTotals(points: points, day: day, calendar: calendar)
            let activeHours = hours.filter { $0.kilowattHours > 0 }.count
            guard activeHours >= 12 else { continue }   // mezza giornata di forma, minimo
            coveredDays += 1
            for hour in hours {
                let index = calendar.component(.hour, from: hour.day)
                if sums.indices.contains(index) { sums[index] += hour.kilowattHours }
            }
        }
        guard coveredDays >= 2 else { return nil }
        return sums.map { $0 / Double(coveredDays) }   // kWh/h = kW medi
    }

    // MARK: Giorni critici

    struct CriticalStretch: Equatable {
        let start: Date
        let end: Date
        let upliftPercent: Double
    }

    /// La sequenza più lunga (≥ 2 giorni consecutivi) sopra la media del
    /// periodo di almeno il 10%: «tra il 27 e il 31 i consumi sono saliti
    /// del 18% rispetto alla media».
    static func criticalStretch(days: [EnergyDayTotal]) -> CriticalStretch? {
        let active = days.filter { $0.kilowattHours > 0 }
        guard active.count >= 5 else { return nil }
        let average = active.map(\.kilowattHours).reduce(0, +) / Double(active.count)
        guard average > 0 else { return nil }

        var best: (range: [EnergyDayTotal], uplift: Double)?
        var current: [EnergyDayTotal] = []
        for day in days {
            if day.kilowattHours >= average * 1.10 {
                current.append(day)
            } else {
                evaluate(&best, candidate: current, average: average)
                current = []
            }
        }
        evaluate(&best, candidate: current, average: average)

        guard let best, best.range.count >= 2,
              let first = best.range.first, let last = best.range.last else { return nil }
        return CriticalStretch(start: first.day, end: last.day, upliftPercent: best.uplift * 100)
    }

    private static func evaluate(_ best: inout (range: [EnergyDayTotal], uplift: Double)?,
                                 candidate: [EnergyDayTotal],
                                 average: Double) {
        guard candidate.count >= 2 else { return }
        let candidateAverage = candidate.map(\.kilowattHours).reduce(0, +) / Double(candidate.count)
        let uplift = candidateAverage / average - 1
        if best == nil || candidate.count > best!.range.count {
            best = (candidate, uplift)
        }
    }

    // MARK: Confronti

    /// Variazione percentuale rispetto a un riferimento: `nil` se il
    /// riferimento non esiste — un confronto col nulla non è un confronto.
    static func percentChange(_ value: Double, versus reference: Double) -> Double? {
        guard reference > 0 else { return nil }
        return (value / reference - 1) * 100
    }
}

extension EnergyDayTotal {
    /// Un'ora letta come potenza media: kWh in un'ora = kW.
    var kilowatts: Double { kilowattHours }
}
