import Testing
import SwiftUI
@testable import HomeFloorplan

/// Il fondo che segue il sole.
///
/// Due promesse da mantenere: di notte non deve succedere niente — il colore
/// scelto dall'utente resta quello — e di giorno non deve mettersi a
/// competere col colore che nell'app significa «attenzione».
@Suite("Il fondo respira col giorno")
struct DaylightGroundTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 13
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    private var sunrise: Date { time(7, 0) }
    private var sunset: Date { time(19, 30) }

    private func light(_ hour: Int, _ minute: Int = 0) -> Double {
        DaylightGround.daylight(at: time(hour, minute), sunrise: sunrise, sunset: sunset)
    }

    // MARK: La curva

    @Test("A mezzanotte e alle tre non c'è luce")
    func nightIsDark() {
        #expect(light(0) == 0)
        #expect(light(3) == 0)
        #expect(light(23) == 0)
    }

    @Test("Mezzogiorno è il massimo della giornata")
    func noonIsBrightest() {
        let noon = light(13, 15)  // mezzo fra alba e tramonto
        #expect(noon > light(9))
        #expect(noon > light(17))
        #expect(noon > 0.95)
    }

    @Test("Il crepuscolo comincia prima dell'alba e finisce dopo il tramonto")
    func twilightExtendsBeyondTheHorizon() {
        // Venti minuti prima dell'alba si vede già qualcosa.
        #expect(light(6, 40) > 0)
        // Un'ora prima no.
        #expect(light(6, 0) == 0)
        #expect(light(19, 50) > 0)
        #expect(light(20, 30) == 0)
    }

    @Test("All'alba c'è poca luce, non zero e non tanta")
    func sunriseIsDim() {
        let dawn = light(7, 0)
        #expect(dawn > 0.05)
        #expect(dawn < 0.35)
    }

    @Test("La curva sale e scende senza salti")
    func curveIsMonotonicOnEachSide() {
        var previous = light(7)
        for hour in 8...13 {
            let current = light(hour)
            #expect(current >= previous, "la mattina deve salire (\(hour))")
            previous = current
        }
        previous = light(14)
        for hour in 15...19 {
            let current = light(hour)
            #expect(current <= previous, "la sera deve scendere (\(hour))")
            previous = current
        }
    }

    @Test("Senza dati solari non si inventa niente")
    func noSolarDataMeansNight() {
        #expect(DaylightGround.daylight(at: time(12), sunrise: nil, sunset: nil) == 0)
        #expect(DaylightGround.daylight(at: time(12), sunrise: sunset, sunset: sunrise) == 0)
    }

    // MARK: Il colore

    private func hsb(_ color: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    @Test("A luce zero il colore scelto torna intatto")
    func nightKeepsTheChosenColor() {
        let base = Color(hue: 0.6, saturation: 0.2, brightness: 0.12)
        let ground = DaylightGround.ground(base: base, daylight: 0)
        #expect(hsb(ground).b == hsb(base).b)
        #expect(hsb(ground).s == hsb(base).s)
    }

    @Test("Di giorno il fondo schiarisce davvero, anche partendo dal buio")
    func dayLiftsEvenADarkBase() {
        let base = Color(hue: 0.6, saturation: 0.2, brightness: 0.12)
        let day = DaylightGround.ground(base: base, daylight: 1)
        #expect(hsb(day).b > 0.8, "un fondo scuro che resta scuro renderebbe l'idea invisibile")
    }

    @Test("Il fondo non diventa mai bianco pieno")
    func neverPureWhite() {
        let base = Color(hue: 0, saturation: 0, brightness: 0.1)
        #expect(hsb(DaylightGround.ground(base: base, daylight: 1)).b < 0.95)
    }

    @Test("Salendo di luce il fondo si smorza invece di accendersi")
    func brighterMeansLessSaturated() {
        let base = Color(hue: 0.08, saturation: 0.5, brightness: 0.15)
        let night = hsb(DaylightGround.ground(base: base, daylight: 0.02))
        let noon = hsb(DaylightGround.ground(base: base, daylight: 1))
        #expect(noon.s < night.s, "un fondo chiaro E saturo competerebbe con gli allarmi")
    }

    @Test("Il caldo sta all'orizzonte e da nessun'altra parte")
    func warmthOnlyNearTheHorizon() {
        #expect(DaylightGround.warmth(daylight: 0.25) > 0.9)
        #expect(DaylightGround.warmth(daylight: 1) == 0)
        #expect(DaylightGround.warmth(daylight: 0) < 0.4)
    }

    @Test("Anche al massimo del caldo la saturazione resta bassa")
    func warmthNeverShouts() {
        let base = Color(hue: 0, saturation: 0, brightness: 0.1)
        let golden = DaylightGround.ground(base: base, daylight: 0.25)
        #expect(hsb(golden).s < 0.12, "l'arancione satura nell'app vuol dire attenzione")
    }

    @Test("La luminanza attraversa la soglia che ribalta il tema della chrome")
    func chromeWillFlip() {
        // Non è un dettaglio: sotto e sopra 0.5 la chrome cambia tema da sola,
        // ed è ciò che tiene leggibile il testo mentre il fondo si muove.
        let base = Color(hue: 0.6, saturation: 0.2, brightness: 0.12)
        #expect(hsb(DaylightGround.ground(base: base, daylight: 0)).b < 0.5)
        #expect(hsb(DaylightGround.ground(base: base, daylight: 1)).b > 0.5)
    }
}
