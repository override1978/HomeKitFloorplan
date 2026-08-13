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
