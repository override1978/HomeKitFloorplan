import Foundation
import Testing
@testable import HomeFloorplan

/// La scala log della barra soglia: se questa matematica sbaglia, il lux
/// torna intoccabile sotto i mille (il difetto segnalato: «se ho 150 lux è
/// praticamente impostabile») o i valori atterrano su numeri illeggibili.
@Suite("AutomationSliderScale — la barra del lux")
struct AutomationSliderScaleTests {

    /// Il campo CURATO del lux (0–5000): i metadata fisici arrivano a
    /// 100.000, ma le soglie di casa vivono qui.
    private let lux: ClosedRange<Double> = 0...5000

    /// La scala log scatta sui campi ampi: lux e CO₂ sì, VOC e umidità no.
    @Test("Log solo oltre i 1.500 di ampiezza")
    func activation() {
        #expect(AutomationSliderScale.usesLogScale(0...100_000))
        #expect(AutomationSliderScale.usesLogScale(0...5000))
        #expect(!AutomationSliderScale.usesLogScale(0...1500))
        #expect(!AutomationSliderScale.usesLogScale(0...100))
    }

    /// Andata e ritorno: 150 lux deve occupare una posizione raggiungibile
    /// (non il primo pixel) e ritornare ~150 dal drag in quella posizione.
    @Test("150 lux: raggiungibile e stabile")
    func lowValuesReachable() {
        let n = AutomationSliderScale.normalized(150, in: lux)
        #expect(n > 0.5 && n < 0.7)
        let back = AutomationSliderScale.value(fraction: n, in: lux)
        #expect(abs(back - 150) <= 10)
    }

    /// I valori del drag atterrano su due cifre significative.
    @Test("Arrotondamento a valori tondi")
    func roundValues() {
        for fraction in stride(from: 0.05, through: 0.95, by: 0.05) {
            let v = AutomationSliderScale.value(fraction: fraction, in: lux)
            guard v > 0 else { continue }
            let magnitude = pow(10, floor(log10(v)) - 1)
            // Confronto in tolleranza relativa: sotto 1 lux la magnitudine
            // scende a 0.01 e il resto in virgola mobile non è mai zero esatto.
            let snapped = (v / magnitude).rounded() * magnitude
            #expect(abs(snapped - v) < magnitude * 0.001,
                    "fraction \(fraction) → \(v) non è tondo")
        }
    }

    /// Gli estremi restano gli estremi.
    @Test("Estremi esatti")
    func bounds() {
        #expect(AutomationSliderScale.value(fraction: 0, in: lux) == 0)
        #expect(AutomationSliderScale.value(fraction: 1, in: lux) == 5000)
        #expect(AutomationSliderScale.normalized(0, in: lux) == 0)
        #expect(abs(AutomationSliderScale.normalized(5000, in: lux) - 1) < 0.0001)
    }

    /// Metà barra sta in scala umana (decine di lux), non a metà campo:
    /// è il senso stesso della scala log.
    @Test("Metà corsa in scala umana")
    func midpointIsHumanScale() {
        let v = AutomationSliderScale.value(fraction: 0.5, in: lux)
        #expect(v >= 20 && v <= 500, "metà corsa = \(v)")
    }
}
