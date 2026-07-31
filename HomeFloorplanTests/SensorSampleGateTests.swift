import Foundation
import Testing
@testable import HomeFloorplan

@Suite("SensorSampleGate — deduplica in scrittura")
struct SensorSampleGateTests {

    static let sensor = "AAAA-BBBB"
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Comportamento di base

    @Test("La prima lettura di un sensore si scrive sempre")
    func firstReadingAlwaysWrites() {
        var gate = SensorSampleGate()
        let wrote = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.4, now: Self.t0)
        #expect(wrote)
    }

    /// Un valore fermo, con o senza rumore sull'ultima cifra, non produce
    /// righe fino al battito. Prima faceva eccezione il valore *identico*
    /// ripetuto, che veniva riscritto per alimentare il check "sensore
    /// bloccato": quel controllo non esiste più, perché segnalava come guasti i
    /// dispositivi a risoluzione grossolana e costava il 60% delle scritture.
    @Test("Un valore stabile non produce righe")
    func stableValueIsSkipped() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.40, now: Self.t0)

        // Tre giri da 15 minuti: nessuno merita una riga. Non quattro — quelli
        // farebbero 60 minuti tondi, cioè il battito, e lì la scrittura è
        // giusta. Il confine ha un test suo (`heartbeatWritesAfterMaxGap`).
        for (step, value) in [21.45, 21.42, 21.46].enumerated() {
            let later = Self.t0.addingTimeInterval(Double(step + 1) * 900)
            let wrote = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: value, now: later)
            #expect(!wrote)
        }
    }

    @Test("Una variazione oltre soglia si scrive subito")
    func significantChangeWrites() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.4, now: Self.t0)

        let later = Self.t0.addingTimeInterval(900)
        let wrote = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.8, now: later)
        #expect(wrote)
    }

    @Test("Il rumore sull'ultima cifra non si scrive")
    func noiseIsSkipped() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.40, now: Self.t0)

        let later = Self.t0.addingTimeInterval(900)
        let wrote = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.41, now: later)
        #expect(!wrote)
    }

    // MARK: - La deriva lenta non deve sparire

    /// Il rischio vero della deduplica: tanti passi sotto soglia che il gate
    /// scarta uno per uno, mentre il valore nel frattempo è cambiato parecchio.
    /// Non succede perché il confronto è sempre contro l'ultima riga *scritta*,
    /// non contro la lettura precedente.
    @Test("Una deriva lenta viene comunque catturata")
    func slowDriftIsCaptured() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 20.0, now: Self.t0)

        var wrote = false
        for step in 1...5 {                                   // +0,1° per giro
            let later = Self.t0.addingTimeInterval(Double(step) * 900)
            if gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature,
                                value: 20.0 + Double(step) * 0.1, now: later) {
                wrote = true
            }
        }
        #expect(wrote, "cinque passi da 0,1° fanno 0,5°: deve essere finito in archivio")
    }

    // MARK: - Battito

    /// I valori si muovono di pochissimo — sotto la soglia di significatività,
    /// ma quanto basta a non essere lo stesso numero. Così si prova il battito
    /// e non la regola sui sensori bloccati.
    @Test("Oltre il tetto massimo si scrive anche se il valore non è cambiato")
    func heartbeatWritesAfterMaxGap() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.40, now: Self.t0)

        let justBefore = Self.t0.addingTimeInterval(SensorSampleGate.maxGap - 1)
        let early = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.45, now: justBefore)
        #expect(!early)

        let atGap = Self.t0.addingTimeInterval(SensorSampleGate.maxGap)
        let beat = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.42, now: atGap)
        #expect(beat)
    }

    /// Il vincolo che la deduplica aveva rotto in silenzio: con battito e soglia
    /// di staleness uguali, ogni sensore stabile veniva dichiarato fermo — e
    /// `EnvironmentPreProcessor` salta il controllo anomalie sui sensori fermi.
    @Test("Il battito resta ben sotto la soglia di staleness")
    func heartbeatStaysBelowStaleThreshold() {
        let heartbeatMinutes = SensorSampleGate.maxGap / 60
        #expect(Double(EnvironmentPreProcessor.staleThresholdMinutes) > heartbeatMinutes,
                "un sensore stabile scrive ogni \(heartbeatMinutes) min e non deve mai risultare fermo")
    }

    // MARK: - Sensori indipendenti

    @Test("Sensori e tipi diversi non si influenzano")
    func perSensorAndPerTypeState() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: "A", type: .temperature, value: 21.0, now: Self.t0)

        let later = Self.t0.addingTimeInterval(60)
        // Stesso valore, altro accessorio: mai visto, si scrive.
        let otherSensor = gate.shouldWrite(accessoryUUID: "B", type: .temperature, value: 21.0, now: later)
        #expect(otherSensor)
        // Stesso accessorio, altro tipo: idem.
        let otherType = gate.shouldWrite(accessoryUUID: "A", type: .humidity, value: 21.0, now: later)
        #expect(otherType)
    }

    // MARK: - Soglie per tipo

    @Test("Gli allarmi booleani passano a ogni transizione")
    func booleanAlertsAlwaysPass() {
        #expect(SensorSampleGate.isSignificantChange(.smoke, from: 0, to: 1))
        #expect(!SensorSampleGate.isSignificantChange(.smoke, from: 0, to: 0))
    }

    @Test("La qualità dell'aria reagisce a ogni gradino")
    func airQualityStepsMatter() {
        #expect(SensorSampleGate.isSignificantChange(.airQuality, from: 2, to: 3))
        #expect(!SensorSampleGate.isSignificantChange(.airQuality, from: 2, to: 2.4))
    }

    /// La luce è l'unico tipo con soglia relativa: lo stesso salto assoluto
    /// conta al buio e non conta in pieno giorno.
    @Test("La soglia della luce è relativa al livello")
    func lightThresholdIsRelative() {
        #expect(SensorSampleGate.isSignificantChange(.lightSensor, from: 10, to: 20))
        #expect(!SensorSampleGate.isSignificantChange(.lightSensor, from: 8000, to: 8010))
    }

    @Test("Vicino allo zero la luce usa comunque un minimo assoluto")
    func lightHasAbsoluteFloor() {
        // Il 15% di 1 lux sarebbe 0,15: senza minimo assoluto ogni sfarfallio
        // in una stanza buia scriverebbe una riga.
        #expect(!SensorSampleGate.isSignificantChange(.lightSensor, from: 1, to: 3))
        #expect(SensorSampleGate.isSignificantChange(.lightSensor, from: 1, to: 7))
    }

    // MARK: - Reset

    @Test("Dopo il reset il gate riparte da zero")
    func resetForgetsEverything() {
        var gate = SensorSampleGate()
        _ = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.4, now: Self.t0)
        #expect(gate.trackedCount == 1)

        gate.reset()
        #expect(gate.trackedCount == 0)

        let later = Self.t0.addingTimeInterval(60)
        let wrote = gate.shouldWrite(accessoryUUID: Self.sensor, type: .temperature, value: 21.4, now: later)
        #expect(wrote)
    }
}
