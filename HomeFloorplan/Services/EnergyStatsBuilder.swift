import Foundation

// MARK: - EnergyStatsBuilder

/// Un punto di storico energia, già slegato da SwiftData: il builder si testa
/// a tavolino, senza container.
struct EnergyStatsPoint: Equatable {
    var timestamp: Date
    var cumulativeKilowattHours: Double?
}

/// Il totale di un giorno (mezzanotte locale), in kWh.
struct EnergyDayTotal: Equatable, Identifiable {
    var id: Date { day }
    var day: Date
    var kilowattHours: Double
}

/// Dal grezzo (letture del contatore cumulativo) alle serie giornaliere.
///
/// Il principio: l'energia consumata fra due letture è il **delta del
/// contatore**, e appartiene all'intervallo di tempo fra le due — se
/// l'intervallo scavalca la mezzanotte, il delta si spalma sui giorni in
/// proporzione al tempo. È così che i buchi di campionamento non perdono
/// energia: il delta del mattino contiene la notte, e la notte la paga
/// (in parte) il giorno giusto.
///
/// ⚠️ Il contatore può SCENDERE (reset/ri-pairing del device): quell'intervallo
/// è inconoscibile e si scarta — non si inventa energia negativa né si somma
/// il valore assoluto. I delta successivi ripartono dal nuovo zero da soli,
/// perché ogni coppia di letture fa storia a sé.
enum EnergyStatsBuilder {

    /// Totali giornalieri per gli ultimi `days` giorni, l'ultimo è il giorno
    /// di `reference`. Sempre esattamente `days` elementi, dal più vecchio,
    /// zero dove non c'è energia attribuita.
    static func dailyTotals(
        points: [EnergyStatsPoint],
        days: Int,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> [EnergyDayTotal] {
        let endDay = calendar.startOfDay(for: reference)
        guard days > 0,
              let startDay = calendar.date(byAdding: .day, value: -(days - 1), to: endDay) else {
            return []
        }

        // Solo i punti col contatore: un campione di sola potenza in mezzo a
        // due letture del contatore non deve spezzare la coppia.
        let sorted = points
            .filter { $0.cumulativeKilowattHours != nil }
            .sorted { $0.timestamp < $1.timestamp }

        var totalsByDay: [Date: Double] = [:]
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            guard let before = previous.cumulativeKilowattHours,
                  let after = current.cumulativeKilowattHours else { continue }
            let delta = after - before
            guard delta > 0 else { continue }   // 0 = niente da attribuire; <0 = reset, intervallo scartato
            smear(delta: delta,
                  from: previous.timestamp,
                  to: current.timestamp,
                  calendar: calendar,
                  into: &totalsByDay)
        }

        var result: [EnergyDayTotal] = []
        var day = startDay
        while day <= endDay {
            result.append(EnergyDayTotal(day: day, kilowattHours: totalsByDay[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// Totali mensili (primo del mese) per gli ultimi `months` mesi,
    /// l'ultimo è il mese di `reference`. Stessa matematica dei giornalieri
    /// — delta fra letture, smear, reset scartati — poi raggruppati per mese.
    static func monthlyTotals(
        points: [EnergyStatsPoint],
        months: Int,
        reference: Date = .now,
        calendar: Calendar = .current
    ) -> [EnergyDayTotal] {
        guard months > 0,
              let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: reference)),
              let windowStart = calendar.date(byAdding: .month, value: -(months - 1), to: currentMonth) else {
            return []
        }
        let coveringDays = (calendar.dateComponents([.day], from: windowStart, to: reference).day ?? 0) + 1
        let daily = dailyTotals(points: points, days: coveringDays, reference: reference, calendar: calendar)

        var byMonth: [Date: Double] = [:]
        for day in daily {
            guard let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day.day)) else { continue }
            byMonth[month, default: 0] += day.kilowattHours
        }

        var result: [EnergyDayTotal] = []
        var month = windowStart
        while month <= currentMonth {
            result.append(EnergyDayTotal(day: month, kilowattHours: byMonth[month] ?? 0))
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            month = next
        }
        return result
    }

    /// Le 24 ore di UN giorno: stessa matematica dei giornalieri, con i
    /// bucket orari e l'intervallo ritagliato sul giorno richiesto — la
    /// parte di un delta che cade fuori dal giorno resta fuori, in
    /// proporzione al tempo, come sempre.
    static func hourlyTotals(
        points: [EnergyStatsPoint],
        day: Date,
        calendar: Calendar = .current
    ) -> [EnergyDayTotal] {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }

        let sorted = points
            .filter { $0.cumulativeKilowattHours != nil }
            .sorted { $0.timestamp < $1.timestamp }

        var byHour: [Date: Double] = [:]
        for (previous, current) in zip(sorted, sorted.dropFirst()) {
            guard let before = previous.cumulativeKilowattHours,
                  let after = current.cumulativeKilowattHours else { continue }
            let delta = after - before
            guard delta > 0 else { continue }
            let start = previous.timestamp
            let end = current.timestamp
            let duration = end.timeIntervalSince(start)
            guard duration > 0, start < dayEnd, end > dayStart else { continue }

            var cursor = max(start, dayStart)
            let clippedEnd = min(end, dayEnd)
            while cursor < clippedEnd {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor)?.start,
                      let nextHour = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
                let segmentEnd = min(nextHour, clippedEnd)
                let fraction = segmentEnd.timeIntervalSince(cursor) / duration
                byHour[hour, default: 0] += delta * fraction
                cursor = segmentEnd
            }
        }

        var result: [EnergyDayTotal] = []
        var hour = dayStart
        while hour < dayEnd {
            result.append(EnergyDayTotal(day: hour, kilowattHours: byHour[hour] ?? 0))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return result
    }

    /// Attribuisce `delta` ai giorni toccati dall'intervallo, in proporzione
    /// al tempo trascorso in ciascuno.
    private static func smear(
        delta: Double,
        from start: Date,
        to end: Date,
        calendar: Calendar,
        into totalsByDay: inout [Date: Double]
    ) {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else {
            totalsByDay[calendar.startOfDay(for: end), default: 0] += delta
            return
        }

        var cursor = start
        while cursor < end {
            let day = calendar.startOfDay(for: cursor)
            guard let nextMidnight = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            let segmentEnd = min(nextMidnight, end)
            let fraction = segmentEnd.timeIntervalSince(cursor) / duration
            totalsByDay[day, default: 0] += delta * fraction
            cursor = segmentEnd
        }
    }
}
