import Foundation
import Testing
@testable import HomeFloorplan

@Suite("Aggregati giornalieri — media pesata sul tempo")
struct DailySummaryWeightingTests {

    static let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

    /// Lettura al minuto `minutes` dopo l'inizio della giornata.
    /// `seconds` serve a simulare due sensori letti nello stesso giro di
    /// campionamento, a frazioni di secondo l'uno dall'altro.
    func reading(_ value: Double, at minutes: Double, sensor: String = "A", seconds: Double = 0) -> SensorReading {
        SensorReading(
            accessoryUUID: sensor,
            serviceType: .temperature,
            roomName: "Soggiorno",
            value: value,
            timestamp: Self.dayStart.addingTimeInterval(minutes * 60 + seconds)
        )
    }

    func stats(_ rds: [SensorReading]) -> (average: Double, standardDeviation: Double) {
        DataLifecycleService.timeWeightedStats(rds, dayStart: Self.dayStart, calendar: Calendar.current)
    }

    // MARK: - Invarianza rispetto al campionamento

    /// Il punto di tutto l'esercizio: lo stesso andamento reale deve produrre
    /// la stessa media, che sia stato campionato fitto o ridotto a poche righe.
    @Test("Campionamento fitto e deduplicato danno la stessa media")
    func weightingIsSamplingInvariant() {
        // 20° dalle 00:00 alle 04:00, poi 30° dalle 04:00 alle 08:00.
        let dense = stride(from: 0.0, to: 240.0, by: 15).map { reading(20, at: $0) }
                  + stride(from: 240.0, to: 480.0, by: 15).map { reading(30, at: $0) }

        // Stesso andamento, scritto solo quando cambia (più il battito orario).
        let deduped = [reading(20, at: 0), reading(20, at: 60), reading(20, at: 120), reading(20, at: 180),
                       reading(30, at: 240), reading(30, at: 300), reading(30, at: 360), reading(30, at: 420)]

        let a = stats(dense).average
        let b = stats(deduped).average
        #expect(abs(a - b) < 0.5, "fitto \(a) vs deduplicato \(b): devono coincidere")
    }

    /// Il caso che la media semplice sbagliava: poche righe per la notte
    /// tranquilla, tante per il pomeriggio agitato.
    @Test("Un periodo agitato non trascina la media")
    func volatilePeriodDoesNotDominate() {
        // 8 ore ferme a 18°, una sola riga l'ora (battito).
        var rds = (0..<8).map { reading(18, at: Double($0) * 60) }
        // 2 ore a 28°, campionate ogni 15 minuti perché il valore si muoveva.
        rds += stride(from: 480.0, to: 600.0, by: 15).map { reading(28, at: $0) }

        let simple = rds.map(\.value).reduce(0, +) / Double(rds.count)
        let weighted = stats(rds).average

        // 8 ore a 18° e 2 ore a 28° stanno intorno ai 20°.
        #expect(abs(weighted - 20.0) < 1.0, "la media pesata dovrebbe stare intorno a 20°, è \(weighted)")
        #expect(simple > weighted + 1.0, "la media semplice (\(simple)) era gonfiata dalle righe fitte")
    }

    // MARK: - Più sensori nella stessa stanza

    /// Gli aggregati raggruppano per (stanza, tipo): due termometri nella stessa
    /// stanza finiscono insieme, con letture separate da un secondo. Pesando il
    /// tempo sul gruppo mescolato, il primo dei due avrebbe pesato un secondo e
    /// il secondo si sarebbe preso tutti i 15 minuti — cancellandone uno.
    @Test("Due sensori nella stessa stanza pesano uguale")
    func twoSensorsInOneRoomBothCount() {
        var rds: [SensorReading] = []
        for minute in stride(from: 0.0, to: 480.0, by: 15) {
            rds.append(reading(21, at: minute, sensor: "A"))
            rds.append(reading(25, at: minute, sensor: "B", seconds: 1))
        }

        let avg = stats(rds).average
        #expect(abs(avg - 23.0) < 0.5, "media \(avg): dovrebbe stare a metà tra 21° e 25°")
    }

    @Test("Un sensore che smette di rispondere non falsa la media dell'altro")
    func silentSensorDoesNotDominate() {
        // A parla tutto il giorno a 20°, B dice 30° solo per la prima mezz'ora.
        var rds = stride(from: 0.0, to: 480.0, by: 15).map { reading(20, at: $0, sensor: "A") }
        rds += [reading(30, at: 0, sensor: "B", seconds: 1),
                reading(30, at: 15, sensor: "B", seconds: 1)]

        // B conta per il tempo in cui ha parlato — mezz'ora più un battito di
        // coda — non quanto A che ha coperto tutta la giornata.
        let avg = stats(rds).average
        #expect(avg > 20.0, "media \(avg): B esiste e deve contare qualcosa")
        #expect(avg < 22.5, "media \(avg): B ha parlato poco, non può valere metà giornata")
    }

    // MARK: - Casi limite

    @Test("Una sola lettura non fa esplodere il calcolo")
    func singleReading() {
        let s = stats([reading(21.5, at: 120)])
        #expect(abs(s.average - 21.5) < 0.001)
        #expect(s.standardDeviation == 0)
    }

    @Test("Due sensori letti nello stesso istante fanno media semplice")
    func simultaneousSensors() {
        let s = stats([reading(10, at: 60, sensor: "A"), reading(20, at: 60, sensor: "B")])
        #expect(abs(s.average - 15.0) < 0.001)
    }

    @Test("Nessuna lettura restituisce zero senza schiantarsi")
    func emptyInput() {
        let s = stats([])
        #expect(s.average == 0)
        #expect(s.standardDeviation == 0)
    }

    /// Se il dispositivo smette di scrivere a metà giornata, l'ultimo valore non
    /// deve reclamare tutte le ore rimaste: pesa al massimo un battito.
    @Test("L'ultima lettura non si prende il resto della giornata")
    func tailIsCappedAtOneHeartbeat() {
        // 2 ore a 10°, poi una lettura isolata a 30° e silenzio fino a mezzanotte.
        var rds = (0..<2).map { reading(10, at: Double($0) * 60) }
        rds.append(reading(30, at: 120))

        let s = stats(rds)
        // La coda vale 1 ora, non 22: 2 ore a 10° + 1 ora a 30° ≈ 16,7°.
        #expect(s.average < 20.0, "media \(s.average): la coda si è presa troppo peso")
        #expect(s.average > 13.0, "media \(s.average): la coda è stata schiacciata troppo")
    }

    @Test("Un valore costante ha deviazione standard nulla")
    func constantValueHasNoDeviation() {
        let rds = (0..<6).map { reading(21.0, at: Double($0) * 60) }
        #expect(stats(rds).standardDeviation < 0.001)
    }
}
