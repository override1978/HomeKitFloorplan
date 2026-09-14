import Testing
import SwiftUI
@testable import HomeFloorplan

/// La palette dell'ora: quattro token cambiano, la leggibilità no.
@Suite("La palette circadiana")
struct CircadianPaletteTests {

    private func palette(light: Double) -> CircadianPalette {
        CircadianPalette.make(light: DaylightGround.Light(
            luminance: light,
            warmth: DaylightGround.warmth(solar: light),
            isRising: false))
    }

    // MARK: Il vincolo che non si negozia

    @Test("Il testo si legge a qualunque ora del giorno")
    func inkIsAlwaysReadable() {
        // È il quarto principio del design, e qui è un vincolo e non un
        // obiettivo: la palette può fare ciò che vuole con la tinta, purché il
        // testo resti leggibile anche alle 23:40 — l'ora in cui una palette che
        // insegue l'atmosfera è più tentata di sbagliare.
        for step in 0...20 {
            let p = palette(light: Double(step) / 20)
            let ratio = CircadianPalette.contrastRatio(p.ink, p.surface)
            #expect(ratio >= CircadianPalette.minimumContrast,
                    "a luce \(Double(step) / 20) il rapporto è \(ratio)")
        }
    }

    @Test("Anche il testo secondario resta sopra la soglia bassa")
    func secondaryInkIsStillReadable() {
        for step in 0...20 {
            let p = palette(light: Double(step) / 20)
            #expect(CircadianPalette.contrastRatio(p.secondaryInk, p.surface) >= 3.0)
        }
    }

    @Test("Il rapporto di contrasto è quello vero, non una media dei canali")
    func contrastIsWCAG() {
        // Bianco su nero: 21:1, il massimo possibile. Se questa non torna, la
        // formula è sbagliata e ogni altra garanzia è finta.
        #expect(abs(CircadianPalette.contrastRatio(.white, .black) - 21) < 0.1)
        #expect(abs(CircadianPalette.contrastRatio(.white, .white) - 1) < 0.001)
    }

    // MARK: Le superfici

    @Test("La superficie si stacca sempre dal fondo")
    func surfaceSeparatesFromGround() {
        for step in 0...20 {
            let p = palette(light: Double(step) / 20)
            #expect(p.surface != p.ground)
            let delta = abs(CircadianPalette.relativeLuminance(p.surface)
                            - CircadianPalette.relativeLuminance(p.ground))
            #expect(delta > 0.005, "una card invisibile è peggio di nessuna card")
        }
    }

    @Test("Di notte la superficie è più chiara del fondo, di giorno no")
    func surfaceRisesInTheDark() {
        // È il verso naturale: al buio una cosa che galleggia prende luce, alla
        // luce piena una card più chiara del bianco non esiste — lì a definirla
        // è il bordo.
        let night = palette(light: 0)
        #expect(CircadianPalette.relativeLuminance(night.surface)
                > CircadianPalette.relativeLuminance(night.ground))
        #expect(night.isDark)
        #expect(palette(light: 1).isDark == false)
    }

    @Test("Le superfici sono più calme del cielo")
    func surfacesAreQuieterThanTheSky() {
        // Tenere tutta la saturazione del fondo farebbe di una fila di pillole
        // una fila di caramelle.
        func saturation(_ color: Color) -> CGFloat {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return s
        }
        let evening = palette(light: 0.25)
        #expect(saturation(evening.surface) < saturation(evening.ground))
        #expect(saturation(evening.surface) > 0, "ma la tinta resta: è la stessa stanza")
    }

    // MARK: Ciò che non deve cambiare

    @Test("I colori di categoria non sono nella palette")
    func categoryColoursAreUntouched() {
        // Il confine del design: cambiano fondo, superficie, inchiostro e
        // bordo. Giallo luci, blu prese e rosa sicurezza sono identità, non
        // atmosfera — una casa in cui cambia il significato dei colori è un
        // posto in cui non si impara più niente. Il test esiste perché è il
        // genere di confine che si supera per comodità, un token alla volta.
        let mirror = Mirror(reflecting: palette(light: 0.3))
        let names = mirror.children.compactMap(\.label).sorted()
        #expect(names == ["border", "elevatedSurface", "ground", "ink",
                          "isDark", "secondaryInk", "surface"])
    }

    @Test("Senza palette l'interfaccia resta quella di sempre")
    func absenceIsClassicMode() {
        // La modalità classica non ha un percorso suo: è l'assenza della
        // palette, quindi non può divergere.
        let environment = EnvironmentValues()
        #expect(environment.circadianPalette == nil)
    }
}

/// La luce che entra dalle finestre, e quella che nasce dalle lampade.
@Suite("I fuochi di luce")
struct CircadianGlowTests {

    private let southWest: Double = 225

    private func admittance(sun: Double, altitude: Double = 40) -> Double {
        CircadianGlow.admittance(sunAzimuth: sun, openingBearing: southWest, sunAltitude: altitude)
    }

    @Test("Un balcone a sud-ovest è in ombra la mattina")
    func southWestIsShadedInTheMorning() {
        // Sole a est (90°): guarda la parete opposta.
        #expect(admittance(sun: 90) == 0)
        #expect(admittance(sun: 110) == 0)
    }

    @Test("E prende tutto il pomeriggio")
    func southWestTakesTheAfternoon() {
        #expect(admittance(sun: 180) > 0.3, "a mezzogiorno il sole è già di sbieco")
        #expect(admittance(sun: 225) > 0.9, "allineato in pieno")
        #expect(admittance(sun: 260) > 0.5)
    }

    @Test("Il massimo cade quando il sole sta davanti all'apertura")
    func peakIsWhenFacing() {
        let aligned = admittance(sun: southWest)
        for offset in stride(from: -80.0, through: 80.0, by: 20) where offset != 0 {
            #expect(admittance(sun: southWest + offset) <= aligned)
        }
    }

    @Test("Di notte non entra niente, per quanto sia allineato")
    func noSunNoLight() {
        #expect(admittance(sun: 225, altitude: -5) == 0)
        #expect(admittance(sun: 225, altitude: 0) == 0)
    }

    @Test("Un sole radente porta meno luce di uno alto")
    func lowSunGivesLess() {
        #expect(admittance(sun: 225, altitude: 5) < admittance(sun: 225, altitude: 40))
    }

    @Test("Più il sole è basso più la luce che passa è calda")
    func lowSunIsWarmer() throws {
        func saturation(_ warmth: Double) throws -> CGFloat {
            let glow = try #require(CircadianGlow.sunlight(through: .center, bearing: southWest,
                                                           sunAzimuth: 225, sunAltitude: 20,
                                                           warmth: warmth))
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(glow.color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return s
        }
        #expect(try saturation(1) > saturation(0))
    }

    // MARK: Le lampade

    @Test("Di giorno le lampade non si vedono")
    func lampsLoseAgainstTheSun() {
        // Competono col sole e perdono: disegnarle comunque farebbe un alone
        // che non corrisponde a niente di visibile.
        #expect(CircadianGlow.lamps(byRoom: [[.center]], daylight: 1).isEmpty)
        #expect(CircadianGlow.lamps(byRoom: [[.center]], daylight: 0.5).isEmpty)
        #expect(CircadianGlow.lamps(byRoom: [[.center]], daylight: 0.05).isEmpty == false)
    }

    @Test("Due stanze accese fanno due pozze, non una in mezzo")
    func twoRoomsMakeTwoPools() {
        // Il difetto che questa forma corregge: con un solo bagliore al
        // baricentro, soggiorno e cucina accesi producevano un alone nel
        // corridoio fra i due, dove non è acceso niente.
        let glows = CircadianGlow.lamps(byRoom: [[UnitPoint(x: 0.2, y: 0.5)],
                                                 [UnitPoint(x: 0.8, y: 0.5)]],
                                        daylight: 0)
        #expect(glows.count == 2)
        #expect(glows.contains { $0.centre.x < 0.3 })
        #expect(glows.contains { $0.centre.x > 0.7 })
        #expect(glows.allSatisfy { abs($0.centre.x - 0.5) > 0.2 },
                "nessuna pozza dove non c'è nessuna lampada")
    }

    @Test("Dentro una stanza le lampade si mediano")
    func lampsWithinARoomAverage() throws {
        let glows = CircadianGlow.lamps(byRoom: [[UnitPoint(x: 0.2, y: 0.5),
                                                  UnitPoint(x: 0.4, y: 0.5)]],
                                        daylight: 0)
        let glow = try #require(glows.first)
        #expect(abs(glow.centre.x - 0.3) < 0.01)
    }

    @Test("Più luci in una stanza, più bagliore — ma non all'infinito")
    func moreLampsSaturate() throws {
        func intensity(_ count: Int) throws -> Double {
            let points = (0..<count).map { _ in UnitPoint.center }
            return try #require(CircadianGlow.lamps(byRoom: [points], daylight: 0).first).intensity
        }
        #expect(try intensity(1) < intensity(3))
        #expect(try abs(intensity(3) - intensity(9)) < 0.001)
    }

    @Test("Nessuna luce accesa, nessun bagliore")
    func noLampsNoGlow() {
        #expect(CircadianGlow.lamps(byRoom: [], daylight: 0).isEmpty)
        #expect(CircadianGlow.lamps(byRoom: [[]], daylight: 0).isEmpty)
    }

    @Test("Una lampada illumina una stanza, non un piano")
    func lampsAreTighterThanTheSun() throws {
        // È la correzione rispetto al mockup: la luce larga metà schermo non
        // somiglia a una lampada, somiglia a una vignettatura — ed è quella che
        // va a sbattere contro i bordi.
        let lamp = try #require(CircadianGlow.lamps(byRoom: [[.center]], daylight: 0).first)
        let sun = try #require(CircadianGlow.sunlight(through: .center, bearing: 225,
                                                      sunAzimuth: 225, sunAltitude: 40,
                                                      warmth: 0.5))
        #expect(lamp.radius < sun.radius)
        #expect(sun.radius < 0.5, "e nemmeno il sole arriva ai bordi")
    }
}

/// Dal punto sulla planimetria al punto sulla schermata.
@Suite("Dove cade il bagliore")
struct GlowPlacementTests {

    private func glow(_ x: CGFloat, _ y: CGFloat) -> CircadianGlow {
        CircadianGlow(centre: UnitPoint(x: x, y: y), intensity: 0.3, radius: 0.2, color: .orange)
    }

    @Test("Il centro dell'immagine resta il centro dell'immagine")
    func imageCentreMapsToImageCentre() {
        // La planimetria occupa la metà destra di una superficie larga il
        // doppio: il suo centro cade a tre quarti dello schermo.
        let rect = CGRect(x: 100, y: 0, width: 100, height: 100)
        let point = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: rect,
                             container: CGSize(width: 200, height: 100))
        #expect(abs(point.x - 0.75) < 0.001)
        #expect(abs(point.y - 0.5) < 0.001)
    }

    @Test("Un angolo della planimetria resta quell'angolo")
    func cornersMapToCorners() {
        let rect = CGRect(x: 50, y: 20, width: 100, height: 60)
        let container = CGSize(width: 200, height: 100)
        let topLeft = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0, 0), imageRect: rect, container: container)
        #expect(abs(topLeft.x - 0.25) < 0.001)
        #expect(abs(topLeft.y - 0.20) < 0.001)
    }

    @Test("La sorgente non scivola quando l'immagine cambia misura")
    func sourceDoesNotDriftWithImageSize() {
        // È la ragione per cui la conversione esiste: il balcone sta dove sta
        // sulla planimetria, non dove capita sullo schermo.
        let container = CGSize(width: 400, height: 300)
        let small = CGRect(x: 100, y: 75, width: 200, height: 150)
        let large = CGRect(x: 0, y: 0, width: 400, height: 300)
        let a = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: small, container: container)
        let b = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: large, container: container)
        #expect(abs(a.x - b.x) < 0.001, "il centro della planimetria è lo stesso punto")
    }

    @Test("Una superficie degenere non produce coordinate assurde")
    func degenerateContainerIsSafe() {
        let point = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: .zero, container: .zero)
        #expect(point == .center)
    }
}
