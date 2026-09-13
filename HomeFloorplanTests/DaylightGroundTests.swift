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

    private var noonLight: DaylightGround.Light {
        DaylightGround.Light(luminance: 1, warmth: 0)
    }

    private func light(_ hour: Int, _ minute: Int = 0) -> Double {
        DaylightGround.daylight(at: time(hour, minute), sunrise: sunrise, sunset: sunset)
    }

    // MARK: La curva

    @Test("A notte fonda non c'è luce")
    func nightIsDark() {
        #expect(light(3) == 0)
        #expect(light(5) == 0)
        // Le undici di sera no: lì la casa è ancora accesa.
        #expect(light(23) > 0)
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
        // Un'ora prima no: prima dell'alba la casa dorme, e il fondo è nero.
        #expect(light(6, 0) == 0)
    }

    @Test("La sera non crolla a zero quando finisce il crepuscolo")
    func eveningHoldsAfterTwilight() {
        // Il difetto da cui nasce tutto questo: alle 20:50 lo schermo era già
        // notte piena, mentre in casa c'erano le lampade accese.
        let evening = light(20, 50)
        #expect(evening > 0.15, "in casa c'è ancora qualcuno sveglio")
        #expect(evening < light(19, 0), "ma meno che al tramonto")
    }

    @Test("La giornata è asimmetrica, come lo è davvero")
    func morningAndEveningDiffer() {
        // Stessa distanza dall'orizzonte: buio al mattino, ancora luce la sera.
        // Al mattino c'è solo il sole; la sera ci sono anche le lampade.
        #expect(light(6, 10) == 0)
        #expect(light(20, 20) > 0)
    }

    @Test("A notte fonda si arriva davvero a zero")
    func deepNightReachesZero() {
        #expect(light(1, 0) == 0)
        #expect(light(3, 0) == 0)
    }

    @Test("Fra il tramonto e la notte fonda non ci sono salti")
    func eveningDescendsWithoutSteps() {
        var previous = light(19, 0)
        for minutes in stride(from: 19 * 60 + 15, through: 24 * 60 + 30, by: 15) {
            let current = light(minutes / 60 % 24, minutes % 60)
            #expect(current <= previous + 0.0001, "risalita a \(minutes / 60):\(minutes % 60)")
            #expect(previous - current < 0.12, "salto a \(minutes / 60):\(minutes % 60)")
            previous = current
        }
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

    @Test("A luce zero un colore scelto torna intatto")
    func nightKeepsTheChosenColor() {
        // Saturazione sopra la soglia: è una tinta voluta, e resta tale.
        let base = Color(hue: 0.6, saturation: 0.2, brightness: 0.12)
        let ground = DaylightGround.ground(base: base, light: .night)
        #expect(abs(hsb(ground).b - hsb(base).b) < 0.001)
        #expect(abs(hsb(ground).s - hsb(base).s) < 0.001)
        #expect(abs(hsb(ground).h - hsb(base).h) < 0.001)
    }

    @Test("Un fondo neutro invece la notte si scalda, come una lampada")
    func neutralBaseWarmsAtNight() {
        let base = Color(hue: 0, saturation: 0, brightness: 0.12)
        let night = hsb(DaylightGround.ground(base: base, light: .night))
        #expect(night.s > 0.05, "la notte circadiana è ambra, non grigio")
        #expect(night.s < 0.2, "ma un'ambra scurissima, non un allarme")
        #expect(abs(night.b - 0.12) < 0.001, "e la luminosità resta quella scelta")
    }

    @Test("Di giorno il fondo schiarisce davvero, anche partendo dal buio")
    func dayLiftsEvenADarkBase() {
        let base = Color(hue: 0.6, saturation: 0.2, brightness: 0.12)
        let day = hsb(DaylightGround.ground(base: base, light: noonLight))
        // Più che triplicato rispetto alla base: si vede benissimo. Ma non si
        // arriva alla carta, perché il disegno della planimetria è un raster
        // scuro che non può seguire fin lassù, e resterebbe un rettangolo
        // d'inchiostro su una tovaglia.
        #expect(day.b > 0.35, "un fondo scuro che resta scuro renderebbe l'idea invisibile")
        #expect(day.b < 0.55, "oltre, il disegno non riesce a starle dietro")
    }

    @Test("Il fondo non diventa mai bianco pieno")
    func neverPureWhite() {
        let base = Color(hue: 0, saturation: 0, brightness: 0.1)
        #expect(hsb(DaylightGround.ground(base: base, light: noonLight)).b < 0.6)
    }

    @Test("Anche il disegno riceve la luce, ma con misura")
    func theDrawingIsLitToo() {
        // Senza questo il raster resta fermo mentre il fondo si muove, e
        // diventa un rettangolo scuro che galleggia.
        #expect(noonLight.imageBrightness > 0.1)
        #expect(DaylightGround.Light.night.imageBrightness == 0,
                "di notte il disegno è quello che hai esportato, intatto")
        // Di giorno la tinta è l'identità: moltiplicare per bianco non fa nulla.
        #expect(noonLight.imageTint == Color(red: 1, green: 1, blue: 1))
    }

    @Test("Salendo di luce il fondo si smorza invece di accendersi")
    func brighterMeansLessSaturated() {
        let base = Color(hue: 0.08, saturation: 0.5, brightness: 0.15)
        let night = hsb(DaylightGround.ground(base: base, light: .night))
        let noon = hsb(DaylightGround.ground(base: base, light: noonLight))
        #expect(noon.s < night.s, "un fondo chiaro E saturo competerebbe con gli allarmi")
    }

    @Test("Il caldo segue il sole al contrario: massimo di notte")
    func warmthIsCircadian() {
        #expect(DaylightGround.warmth(solar: 0) == 1)
        #expect(DaylightGround.warmth(solar: 1) == 0)
        // Monotona: non deve esistere un punto in cui risalendo il sole
        // il fondo si riscalda.
        var previous = DaylightGround.warmth(solar: 0)
        for step in 1...20 {
            let current = DaylightGround.warmth(solar: Double(step) / 20)
            #expect(current <= previous)
            previous = current
        }
    }

    @Test("A metà giornata il caldo è già quasi sparito")
    func warmthFadesEarly() {
        #expect(DaylightGround.warmth(solar: 0.5) < 0.35,
                "un fondo beige tutto il giorno è gusto, non informazione")
    }

    @Test("Anche al massimo del caldo la saturazione resta bassa")
    func warmthNeverShouts() {
        let base = Color(hue: 0, saturation: 0, brightness: 0.1)
        let golden = DaylightGround.ground(base: base,
                                           light: DaylightGround.Light(luminance: 0.28, warmth: 0.6))
        #expect(hsb(golden).s < 0.12, "l'arancione satura nell'app vuol dire attenzione")
    }

    @Test("Il fondo resta sotto la soglia che ribalta il tema della chrome")
    func chromeStaysDark() {
        let base = Color(hue: 0.6, saturation: 0.2, brightness: 0.12)
        #expect(hsb(DaylightGround.ground(base: base, light: .night)).b < 0.5)
        // A 0,42 la chrome resta sul tema scuro tutto il giorno: è una
        // conseguenza voluta del tetto più basso, non una svista. Il pannello
        // non ribalta più il tema a metà mattina, e il testo non deve
        // riadattarsi due volte al giorno.
        #expect(hsb(DaylightGround.ground(base: base, light: noonLight)).b < 0.5)
    }
}
