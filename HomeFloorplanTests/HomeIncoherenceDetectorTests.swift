import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("HomeIncoherenceDetector — logica pura")
struct HomeIncoherenceDetectorTests {

    @Test("Luci+luminosità: scatta solo in fascia diurna e sopra soglia")
    func daylightWasteCandidate() {
        let config = HomeIncoherenceDetector.Configuration()

        // Giorno + lux alti → candidata
        #expect(HomeIncoherenceDetector.isDaylightWasteCandidate(lux: 800, hour: 12, configuration: config))
        // Giorno ma lux sotto soglia → no
        #expect(!HomeIncoherenceDetector.isDaylightWasteCandidate(lux: 300, hour: 12, configuration: config))
        // Lux alti ma di sera: sono le luci stesse a produrli → no
        #expect(!HomeIncoherenceDetector.isDaylightWasteCandidate(lux: 800, hour: 21, configuration: config))
        // Bordo finestra: start incluso, end escluso
        #expect(HomeIncoherenceDetector.isDaylightWasteCandidate(lux: 800, hour: 8, configuration: config))
        #expect(!HomeIncoherenceDetector.isDaylightWasteCandidate(lux: 800, hour: 18, configuration: config))
    }

    @Test("Soglia esatta: 500 lux è già sufficiente")
    func daylightThresholdBoundary() {
        let config = HomeIncoherenceDetector.Configuration()
        #expect(HomeIncoherenceDetector.isDaylightWasteCandidate(lux: config.daylightLuxThreshold, hour: 12, configuration: config))
    }

    @Test("Livelli CO2 derivati dalla soglia Ambiente: warning 1000 riproduce i vecchi 900/1200")
    func co2BoundsDerivedFromAmbientThreshold() {
        // Default: identico ai valori storici hardcoded (nessun cambio per chi non tocca le soglie)
        let defaults = HomeIncoherenceDetector.co2Bounds(forWarning: 1000)
        #expect(defaults.minimum == 900)
        #expect(defaults.high == 1200)

        // Utente che alza la warning a 1500: l'incoerenza segue coerentemente
        let custom = HomeIncoherenceDetector.co2Bounds(forWarning: 1500)
        #expect(custom.minimum == 1350)
        #expect(custom.high == 1800)
    }
}
