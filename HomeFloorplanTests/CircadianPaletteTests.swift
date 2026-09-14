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
