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
        #expect(noon >= light(9))
        #expect(noon >= light(17))
        #expect(noon > 0.95)
    }

    @Test("Alle nove del mattino la stanza è già bianca")
    func morningIsWhiteNotGrey() {
        // Il difetto che ha fatto riscrivere la curva: la curva solare nuda
        // passa la mattina nei valori intermedi, e i valori intermedi di una
        // scala neutra sono grigio. Nessuna stanza è grigia alle nove.
        let ground = DaylightGround.circadianGround(
            light: DaylightGround.light(at: time(9, 9), sunrise: sunrise, sunset: sunset))
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(ground).getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        #expect(b > 0.85, "alle nove deve leggersi bianco, non grigio")
    }

    @Test("Il bianco del mattino ha un riflesso caldo, quello di mezzogiorno no")
    func morningWhiteIsWarm() {
        func saturation(_ hour: Int, _ minute: Int) -> CGFloat {
            let ground = DaylightGround.circadianGround(
                light: DaylightGround.light(at: time(hour, minute),
                                            sunrise: sunrise, sunset: sunset))
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(ground).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return s
        }
        // Chiaro E caldo insieme è la luce del primo mattino; chiaro e saturo
        // urlerebbe, quindi resta un bianco appena crema.
        #expect(saturation(7, 30) > saturation(13, 15))
        #expect(saturation(7, 30) < 0.12)
    }

    @Test("La stanza si illumina prima di quanto salga il sole")
    func roomRespondsFasterThanTheSun() {
        // A metà altezza del sole la stanza è già quasi al massimo: è la
        // differenza fra «quanto è alto il sole» e «quanto è illuminata una
        // stanza», che è ciò che la curva nuda sbagliava.
        #expect(DaylightGround.roomResponse(solar: 0.3) > 0.6)
        #expect(DaylightGround.roomResponse(solar: 0.55) == 1)
        #expect(DaylightGround.roomResponse(solar: 1) == 1)
        #expect(DaylightGround.roomResponse(solar: 0) == 0)
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

    @Test("All'alba la stanza è a metà strada: né buia né bianca")
    func sunriseIsHalfLit() {
        // Non più «poca luce»: una stanza all'alba è già ben visibile, ed è il
        // motivo per cui la risposta è ripida. Ma non è ancora il giorno.
        let dawn = light(7, 0)
        #expect(dawn > 0.3)
        #expect(dawn < 0.8)
        #expect(dawn > light(6, 20), "e più chiara di mezz'ora prima")
        #expect(dawn < light(9, 0), "e meno delle nove")
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
    }

    @Test("Il fondo non diventa mai bianco assoluto")
    func neverPureWhite() {
        // Sotto i muri di una planimetria il bianco pieno abbaglia e mangia i
        // contorni — ma deve mancarci poco, o si legge grigio chiaro.
        #expect(hsb(DaylightGround.circadianGround(light: noonLight)).b < 0.99)
        #expect(hsb(DaylightGround.circadianGround(light: noonLight)).b > 0.9)
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

    @Test("La luce è del momento, non del documento")
    func groundIsAbsolute() {
        // Il difetto che ha fatto nascere questa funzione: due planimetrie
        // aperte alle 21:44 avevano due luci diverse — una scura e una crema —
        // perché ognuna restava ancorata alla propria palette. Alla stessa ora
        // la luce deve essere una sola.
        let evening = DaylightGround.Light(luminance: 0.19, warmth: 1)
        let ground = DaylightGround.circadianGround(light: evening)
        #expect(hsb(ground).b > 0.2)
        #expect(hsb(ground).b < 0.35)
    }

    @Test("La scala assoluta va dal quasi nero alla carta")
    func absoluteRange() {
        let night = hsb(DaylightGround.circadianGround(light: .night))
        let noon = hsb(DaylightGround.circadianGround(light: noonLight))
        #expect(night.b < 0.15)
        #expect(noon.b > 0.9)
        #expect(noon.b < 0.99, "il bianco pieno sotto i muri abbaglia")
    }

    @Test("Il fondo attraversa la soglia che ribalta il tema della chrome")
    func chromeFlips() {
        // Non è un dettaglio: sotto e sopra 0.5 la chrome cambia tema da sola,
        // ed è ciò che tiene leggibile il testo mentre il fondo si muove.
        #expect(hsb(DaylightGround.circadianGround(light: .night)).b < 0.5)
        #expect(hsb(DaylightGround.circadianGround(light: noonLight)).b > 0.5)
    }

    @Test("Di notte il fondo assoluto è caldo, a mezzogiorno neutro")
    func absoluteGroundIsCircadian() {
        #expect(hsb(DaylightGround.circadianGround(light: .night)).s > 0.08,
                "la notte circadiana è ambra, non grigio")
        #expect(hsb(DaylightGround.circadianGround(light: .night)).s < 0.2,
                "ma un'ambra scurissima, non un allarme")
        #expect(hsb(DaylightGround.circadianGround(light: noonLight)).s < 0.02,
                "chiaro e saturo insieme urlano")
    }

    @Test("Salendo di luce il fondo assoluto non torna mai indietro")
    func absoluteGroundIsMonotonic() {
        var previous = hsb(DaylightGround.circadianGround(light: .night)).b
        for step in 1...20 {
            let level = Double(step) / 20
            let current = hsb(DaylightGround.circadianGround(
                light: DaylightGround.Light(luminance: level,
                                            warmth: DaylightGround.warmth(solar: level)))).b
            #expect(current > previous)
            previous = current
        }
    }
}

/// L'incrocio fra le due varianti del disegno.
///
/// Fra chiaro e scuro non c'è una regolazione ma due disegni diversi — muri
/// scuri su fondo chiaro, o il contrario — quindi il passaggio è una
/// dissolvenza e non un interruttore.
@Suite("Le quattro fasi della giornata")
struct CircadianPhaseTests {

    private func opacity(_ luminance: Double) -> Double {
        DaylightGround.Light(luminance: luminance,
                             warmth: DaylightGround.warmth(solar: luminance)).darkVariantOpacity
    }

    @Test("Di giorno si vede solo il disegno chiaro")
    func dayShowsTheLightDrawing() {
        #expect(opacity(1) == 0)
        #expect(opacity(0.6) == 0)
        #expect(opacity(0.42) == 0)
    }

    @Test("Di notte si vede solo il disegno scuro")
    func nightShowsTheDarkDrawing() {
        #expect(opacity(0) == 1)
        #expect(opacity(0.1) == 1)
        #expect(opacity(0.16) == 1)
    }

    @Test("In mezzo si attraversano, senza scatti")
    func theyCrossWithoutASnap() {
        // Passo intero invece che in virgola mobile: `stride` su Double non
        // arriva sull'estremo, e il test fallirebbe sull'aritmetica invece che
        // sulla cosa che vuole misurare.
        var previous = opacity(0.42)
        for step in 0...26 {
            let current = opacity(0.42 - Double(step) * 0.01)
            #expect(current >= previous, "la variante scura deve solo crescere scendendo")
            #expect(current - previous < 0.2, "e senza salti")
            previous = current
        }
        #expect(opacity(0.16) == 1)
    }

    @Test("A metà strada valgono metà ciascuna")
    func halfwayIsHalf() {
        let middle = opacity((0.42 + 0.16) / 2)
        #expect(abs(middle - 0.5) < 0.02)
    }

    @Test("Il passaggio cade nella sera, non a mezzogiorno né a notte fonda")
    func crossingHappensInTheEvening() {
        // La soglia alta sta sotto la luce del pomeriggio e sopra quella della
        // sera: è lì che in casa si accendono le lampade.
        #expect(opacity(0.5) == 0, "alle cinque del pomeriggio si è ancora chiari")
        #expect(opacity(0.28) > 0, "al crepuscolo il passaggio è cominciato")
        #expect(opacity(0.28) < 1, "ma non è finito")
    }
}
