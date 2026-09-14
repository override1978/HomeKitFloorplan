import SwiftUI

// MARK: - DaylightGround

/// Il fondo della planimetria che segue il sole.
///
/// Cambia cosa è la planimetria: da disegno a finestra. Un pannello appeso al
/// muro che alle sette del mattino schiarisce e alle nove di sera si spegne
/// racconta l'ora senza scriverla, e lo fa nell'unico posto che non stava
/// dicendo niente — il fondo. È anche la ragione per cui la banda giorno/notte
/// sul nastro funzionava: il tempo si legge meglio come luce che come numero.
///
/// Due regole tengono la cosa onesta invece che decorativa.
///
/// La prima: il fondo si muove in **luminanza**, non in colore. Nell'app il
/// colore satura già significa qualcosa — arancione è attenzione, rosso è
/// urgenza — e un fondo che scivolasse verso l'ambra al tramonto entrerebbe in
/// concorrenza con l'unica cosa che deve poter gridare. Quel poco di caldo che
/// c'è all'alba e al tramonto è a saturazione bassissima: si sente, non si
/// legge.
///
/// La seconda: la notte è il colore che l'utente ha scelto, intatto. Non si
/// reinventa la sua planimetria — si aggiunge il giorno sopra.
enum DaylightGround {

    /// Quanta luce c'è, da 0 (notte piena) a 1 (mezzogiorno).
    ///
    /// Non si ferma all'alba e al tramonto: il crepuscolo civile dura una
    /// quarantina di minuti e in quel tempo si vede benissimo, quindi la
    /// finestra si allarga di altrettanto da entrambe le parti. Senza, il fondo
    /// farebbe uno scatto al momento esatto dell'alba, che è il difetto che
    /// tutta questa idea vorrebbe evitare.
    static let twilight: TimeInterval = 40 * 60

    /// Il livello della sera: la casa è sveglia anche se fuori è buio.
    ///
    /// Senza, la curva solare faceva delle 20:50 e delle tre di notte la stessa
    /// cosa — zero — e il pannello passava dal crepuscolo al nero in un quarto
    /// d'ora. Fuori era corretto; dentro no, perché alle 20:50 in casa ci sono
    /// le lampade accese e qualcuno sveglio, che è ciò che il pannello sta
    /// davvero guardando.
    static let eveningLevel = 0.24

    /// Sopra quale altezza del sole la stanza è semplicemente illuminata.
    ///
    /// Una stanza non si schiarisce in proporzione all'altezza del sole: già
    /// poco dopo l'alba è chiara, e resta chiara fino a sera. La curva solare
    /// nuda invece passa ore nei valori intermedi, e i valori intermedi di una
    /// scala neutra sono **grigio** — alle nove del mattino si vedeva una
    /// planimetria grigia, che non somiglia a nessuna stanza di questo mondo.
    ///
    /// Oltre questa soglia si è al massimo, e sotto si sale in fretta. È la
    /// stessa ragione per cui una fotografia in interni non ha bisogno di
    /// aspettare mezzogiorno per essere bianca.
    static let fullLightAltitude = 0.55

    /// Quanto ripida è la salita sotto quella soglia. Sotto uno: parte forte e
    /// poi si appiattisce, come fa la luce vera all'alba.
    static let lightResponseCurve = 0.7

    /// L'ora in cui la casa si spegne davvero, e con lei il fondo.
    ///
    /// Mezzanotte e mezza è una convenzione, ed è giusto dirlo invece di
    /// fingere che sia un dato: è l'ora in cui in una casa normale non c'è più
    /// nessuno in piedi. Il vero segnale sarebbe l'ultima automazione della
    /// giornata — «Buonanotte» —, e il giorno che lo si volesse questo è il
    /// punto da cambiare.
    static let deepNightHour = 0
    static let deepNightMinute = 30

    /// La luce dell'istante, da 0 (notte fonda) a 1 (mezzogiorno).
    ///
    /// La curva è asimmetrica di proposito, perché lo è la giornata. Salendo
    /// verso l'alba c'è solo il sole: prima che sorga la casa dorme e il fondo
    /// è nero. Scendendo dal tramonto no: le lampade si accendono, e la
    /// discesa si ferma sul livello della sera invece di arrivare a zero. Poi
    /// da lì cala piano fino a notte fonda.
    ///
    /// È la stessa cosa che si vede da fuori guardando una casa: al mattino si
    /// illumina con il cielo, la sera resta illuminata da sola ancora per un
    /// pezzo.
    /// I due assi del ciclo, nello stesso istante.
    ///
    /// Separati perché non seguono la stessa cosa: la luminanza è quanta luce
    /// c'è in casa — sole più lampade — mentre il caldo segue **solo il sole**.
    /// La differenza si vede al tramonto: mentre le lampade tengono costante la
    /// quantità di luce, il colore continua a scaldarsi perché il sole sta
    /// scendendo lo stesso. Facendo dipendere il caldo dal totale, quei
    /// settantacinque minuti diventavano uno schermo fermo proprio nel momento
    /// più interessante della giornata.
    struct Light: Equatable, Sendable {
        let luminance: Double
        let warmth: Double
        /// Vero prima del mezzogiorno solare.
        ///
        /// Serve alla tinta e a nient'altro: alba e tramonto hanno la stessa
        /// luminosità e colori diversi — l'alba è rosa e fredda, il tramonto
        /// arancione. Senza sapere da che parte si sta andando le due mattine
        /// e le due sere sarebbero indistinguibili.
        var isRising: Bool = false

        static let night = Light(luminance: 0, warmth: 1, isRising: false)

        /// Quanto schiarire il disegno della planimetria.
        ///
        /// Il disegno è un raster coi colori già cotti dentro, quindi se lo si
        /// lascia fermo mentre il fondo si schiarisce diventa un rettangolo
        /// scuro che galleggia su una tovaglia chiara — il difetto si vede
        /// subito e rovina l'effetto invece di produrlo. La luce va data anche
        /// a lui.
        ///
        /// Poco però: alzare la luminosità di un disegno scuro gli spegne il
        /// contrasto, e la planimetria deve restare leggibile a qualunque ora.
        /// Il grosso del segnale resta sul fondo e sul calore.
        /// Un soffio, non più una compensazione.
        ///
        /// Valeva 0,16 quando il disegno era uno solo e doveva coprire da solo
        /// tutta la giornata: schiarirlo era l'unico modo di farlo somigliare
        /// al giorno. Con due varianti ognuna è già quella giusta per la
        /// propria fase, e continuare a schiarirla la sbianca e basta — i muri
        /// chiari saturavano a bianco pieno e sembravano accesi, che è anche
        /// ciò che faceva leggere grigio il fondo accanto a loro.
        var imageBrightness: Double { 0.04 * luminance }

        /// Quanto pesa la variante scura del disegno.
        ///
        /// La transizione non è un istante ma una fascia: il passaggio avviene
        /// mentre la luce cala fra il crepuscolo pieno e la sera, che è
        /// esattamente quando in casa si accendono le lampade. Sotto si è
        /// architectural scuro, sopra si è chiari, in mezzo si è entrambi.
        ///
        /// Il raccordo è un coseno e non una rampa: una rampa ha uno spigolo
        /// dove comincia e dove finisce, e su un incrocio fra due disegni gli
        /// spigoli sono l'unica cosa che si nota.
        var darkVariantOpacity: Double {
            let start = 0.42   // sopra: pieno giorno, disegno chiaro
            let end = 0.16     // sotto: notte, disegno scuro
            if luminance >= start { return 0 }
            if luminance <= end { return 1 }
            let t = (start - luminance) / (start - end)
            return (1 - cos(.pi * t)) / 2
        }

        /// Un filo di contrasto in più, a compensare l'appiattimento.
        var imageContrast: Double { 1 + 0.03 * luminance }

        /// La tinta calda da moltiplicare sul disegno.
        ///
        /// Moltiplicare e non sovrapporre: un velo sopra coprirebbe i tratti
        /// più sottili, mentre il prodotto scalda lasciando intatta la
        /// geometria. Il bianco puro a mezzogiorno è l'identità, quindi di
        /// giorno non succede niente.
        ///
        /// Anche qui la prima versione era troppo timida — sei e quattordici
        /// per cento non scaldano niente di percepibile — e il risultato era un
        /// tramonto in scala di grigi: il fondo appena tiepido e il disegno
        /// del tutto neutro. La luce di una lampada toglie al blu molto più di
        /// così.
        var imageTint: Color {
            Color(red: 1,
                  green: 1 - 0.13 * warmth,
                  blue: 1 - 0.30 * warmth)
        }
    }

    nonisolated static func light(at instant: Date,
                                  sunrise: Date?,
                                  sunset: Date?,
                                  calendar: Calendar = .current) -> Light {
        guard let sunrise, let sunset, sunset > sunrise else { return .night }
        let start = sunrise.addingTimeInterval(-twilight)
        let end = sunset.addingTimeInterval(twilight)
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return .night }

        let t = instant.timeIntervalSince(start) / span
        if t < 0 { return .night }

        if t <= 1 {
            let solar = sin(.pi * t)
            let lit = roomResponse(solar: solar)
            // Il pomeriggio resta puro sole; le lampade subentrano solo quando
            // il sole scende sotto di loro. Un raccordo che sollevasse tutta la
            // seconda metà renderebbe le cinque del pomeriggio più luminose
            // delle nove del mattino, che è la stessa altezza del sole.
            let luminance = t > 0.5 ? max(lit, eveningLevel) : lit
            return Light(luminance: luminance, warmth: warmth(solar: solar), isRising: t < 0.5)
        }

        // Dopo il crepuscolo: il sole non c'è più, restano le lampade che si
        // consumano.
        return Light(luminance: eveningLevel * eveningFade(from: end, at: instant,
                                                           calendar: calendar),
                     warmth: 1, isRising: false)
    }

    /// Compatibilità: la sola luminanza.
    nonisolated static func daylight(at instant: Date,
                                     sunrise: Date?,
                                     sunset: Date?,
                                     calendar: Calendar = .current) -> Double {
        light(at: instant, sunrise: sunrise, sunset: sunset, calendar: calendar).luminance
    }

    /// Quanto resta della sera, da 1 (appena finito il crepuscolo) a 0 (notte fonda).
    ///
    /// Con un raccordo morbido a entrambi i capi e non lineare: una rampa
    /// dritta ha uno spigolo dove comincia e dove finisce, e su un fondo che
    /// cambia di un passo al minuto gli spigoli sono l'unica cosa che l'occhio
    /// riesce a notare.
    nonisolated static func eveningFade(from twilightEnd: Date,
                                        at instant: Date,
                                        calendar: Calendar = .current) -> Double {
        guard let deepNight = nextDeepNight(after: twilightEnd, calendar: calendar),
              deepNight > twilightEnd else { return 0 }
        let span = deepNight.timeIntervalSince(twilightEnd)
        let t = instant.timeIntervalSince(twilightEnd) / span
        if t <= 0 { return 1 }
        if t >= 1 { return 0 }
        return (cos(.pi * t) + 1) / 2
    }

    /// La mezzanotte e mezza successiva al crepuscolo.
    nonisolated static func nextDeepNight(after instant: Date,
                                          calendar: Calendar = .current) -> Date? {
        calendar.nextDate(after: instant,
                          matching: DateComponents(hour: deepNightHour, minute: deepNightMinute),
                          matchingPolicy: .nextTime)
    }

    /// Quanto il fondo è caldo: massimo di notte, nullo a mezzogiorno.
    ///
    /// È l'altro asse del ciclo circadiano, e va nella direzione opposta alla
    /// luce. Le lampade circadiane fanno esattamente questo — ambra la sera,
    /// bianco freddo a mezzogiorno — e non per gusto: la luce fredda la sera
    /// sopprime la melatonina, quindi una casa che si comporta bene la evita.
    /// Un pannello acceso su una parete è una sorgente luminosa come le altre,
    /// e non ha ragione di essere l'unica che sbaglia.
    ///
    /// Prima questa funzione culminava all'orizzonte e poi *si raffreddava*
    /// scendendo verso la notte, che è il rovescio della cosa vera: la notte è
    /// il punto più caldo della giornata, non il più neutro.
    ///
    /// L'esponente sopra uno tiene il caldo schiacciato nella parte bassa: a
    /// metà giornata deve già essere quasi sparito, altrimenti il fondo è
    /// beige dalla mattina alla sera, che è una scelta di gusto invece che
    /// un'informazione.
    /// Da quanto è alto il sole a quanto è illuminata la stanza.
    nonisolated static func roomResponse(solar: Double) -> Double {
        let height = min(max(solar, 0), 1)
        guard height < fullLightAltitude else { return 1 }
        return pow(height / fullLightAltitude, lightResponseCurve)
    }

    nonisolated static func warmth(solar: Double) -> Double {
        let height = min(max(solar, 0), 1)
        return pow(1 - height, 1.6)
    }

    /// Il fondo del momento, uguale per tutti.
    ///
    /// La luce è una proprietà dell'istante, non del documento. Partendo dal
    /// colore scelto per ciascuna planimetria si otteneva il contrario: due
    /// planimetrie aperte alla stessa ora avevano due luci diverse — una scura
    /// e una crema alle 21:44 — perché ognuna restava ancorata alla propria
    /// palette. Con l'interruttore acceso quel colore non serve più: il disegno
    /// esce senza fondo, e il fondo lo mette l'ora.
    ///
    /// È anche ciò che permette alla scala di essere assoluta e larga davvero.
    /// Finché il riferimento era il documento, «notte» voleva dire cose diverse
    /// a seconda di cosa si stava guardando, e l'escursione doveva restare
    /// piccola per non tradire nessuna delle due.
    nonisolated static func circadianGround(light cycle: Light) -> Color {
        let light = min(max(cycle.luminance, 0), 1)

        // Da un viola quasi nero al bianco.
        //
        // Il tetto era 0,95, e a mezzogiorno si leggeva grigio: il bianco non è
        // una quantità assoluta ma un confronto, e accanto ai riempimenti
        // bianchi del disegno un fondo a 0,95 è semplicemente il grigio della
        // coppia. Era un ragionamento giusto sul colore e sbagliato sulla
        // scena — «non arrivare al bianco perché abbaglia» vale per una
        // superficie sola, non per una che ne tocca un'altra più chiara.
        // Il fondo della notte non è nero: è prugna scurissimo.
        //
        // Era 0,10, e finché la luce calda si spandeva su tutta la schermata
        // quel valore non si vedeva mai. Con i bagliori stretti sulle stanze il
        // fondo vero è venuto fuori, e a 0,10 con questa tinta fa `#111119` —
        // che di notte, su uno schermo, è nero. Perdeva senso tutta la parte
        // del ciclo che sta sotto l'orizzonte: quattro ore di viola diverso
        // rese indistinguibili dal nero assoluto.
        let brightness = 0.15 + (0.99 - 0.15) * light

        return Color(hue: skyHue(light: light, rising: cycle.isRising),
                     saturation: skySaturation(light: light),
                     brightness: brightness)
    }

    /// La tinta del cielo a una data quantità di luce.
    ///
    /// Una tinta sola non bastava. Con l'ambra fissa, qualunque saturazione
    /// dessi, l'arco della giornata restava una scala di grigi appena tiepida:
    /// il colore non si legge come colore se non **cambia**. E un'alba vera non
    /// è ambra — è rosa che diventa oro; un tramonto è oro che diventa arancio
    /// e poi prugna e poi viola.
    ///
    /// Tre tratti, tutti presi dalla cosa vera:
    ///
    /// Alba e tramonto partono da tinte diverse — rosa freddo contro arancio —
    /// perché la stessa luminosità al mattino e alla sera ha colori diversi, e
    /// senza questa distinzione le due metà della giornata sarebbero
    /// specularmente identiche.
    ///
    /// Salendo di luce entrambe convergono all'oro e poi diventano
    /// irrilevanti, perché a mezzogiorno la saturazione è zero e la tinta non
    /// ha più niente da tingere.
    ///
    /// Scendendo sotto il livello della sera la tinta **scende** di valore
    /// invece di salire: da arancio verso magenta e poi viola. È il verso
    /// corto sulla ruota, ma è anche la sequenza vera del crepuscolo — chi ha
    /// guardato un cielo dopo il tramonto l'ha vista.
    nonisolated static func skyHue(light: Double, rising: Bool) -> Double {
        let edge = rising ? -0.035 : 0.045      // rosa all'alba, arancio al tramonto
        let warm = edge + (0.11 - edge) * smoothstep(light, from: 0, to: 0.65)
        let nightness = max(0, (eveningLevel - light) / eveningLevel)
        // La rotazione si ferma sulla prugna, non prosegue fino al blu.
        //
        // Era 0,40 e portava la notte a un indigo da 232°. Il cielo dopo il
        // tramonto passa per l'arancio, il magenta e il viola, e si ferma lì
        // prima di diventare buio — non vira al blu di mezzogiorno d'inverno.
        // «Fondo prugna freddo» è la descrizione giusta, e prugna sta a
        // trecentodieci gradi.
        let rotated = warm - nightRotation * nightness
        return rotated.truncatingRemainder(dividingBy: 1) + (rotated < 0 ? 1 : 0)
    }

    /// Quanto la tinta ruota scendendo nella notte. Si ferma sulla prugna.
    static let nightRotation = 0.185

    /// Quanto è colorato il cielo: massimo agli estremi, nullo a mezzogiorno.
    ///
    /// L'esponente poco sopra uno fa sì che la saturazione cali più in fretta
    /// di quanto salga la luce: è ciò che tiene automaticamente vera l'unica
    /// regola che conta, cioè mai chiaro **e** saturo insieme. Non serve un
    /// tetto separato — lo garantisce la forma della curva.
    nonisolated static func skySaturation(light: Double) -> Double {
        0.34 * pow(1 - min(max(light, 0), 1), 1.1)
    }

    nonisolated private static func smoothstep(_ x: Double, from a: Double, to b: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Il fondo modulato a partire dal colore scelto dall'utente.
    ///
    /// Resta per il caso in cui la luce circadiana è spenta e per chi ha un
    /// disegno col proprio fondo cotto dentro: lì il colore scelto è ancora il
    /// riferimento, e a luce zero torna esattamente sé stesso.
    nonisolated static func ground(base: Color, light cycle: Light) -> Color {
        let light = min(max(cycle.luminance, 0), 1)

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(base).getHue(&hue, saturation: &saturation,
                                   brightness: &brightness, alpha: &alpha) else { return base }

        // La luminanza di giorno non viene dal colore scelto ma dalla luce: un
        // fondo già scuro resterebbe scuro, e l'intera idea non si vedrebbe.
        //
        // Ma nemmeno si sale fino alla carta. Il disegno della planimetria è un
        // raster scuro che si può schiarire solo fin dove regge il contrasto, e
        // un fondo che diventasse bianco lascerebbe comunque un rettangolo
        // d'inchiostro in mezzo a una tovaglia: due materiali diversi invece di
        // una stanza illuminata. Il tetto è quello che il disegno sa seguire.
        // Da 0,12 a 0,42 il valore più che triplica — si vede benissimo — e i
        // due strati restano parenti.
        let dayBrightness: CGFloat = 0.42
        let targetBrightness = brightness + (dayBrightness - brightness) * CGFloat(light)

        // Salendo di luce il fondo si smorza: un colore saturo che diventa
        // anche chiaro urla, e questo è il pavimento su cui tutto il resto
        // deve poter apparire.
        let targetSaturation = saturation * CGFloat(1 - light * 0.55)

        // L'ambra della sera e della notte. La sua forza cala con la luce, così
        // non può mai esistere un fondo chiaro E caldo E saturo: in basso è un
        // bruno scurissimo, che con l'arancione d'allarme non si confonde
        // perché è la luminanza a separarli, non la tinta.
        // Un fondo scelto apposta colorato resta suo, tinta e forza: l'ambra
        // entra solo dove la tinta non stava già dicendo qualcosa. Chi ha
        // scelto un blu notte lo ha scelto, e virarglielo — o anche solo
        // saturarlo — sarebbe rispondere a una domanda che non ha fatto.
        let isNeutralBase = saturation < 0.10
        let warm = min(max(cycle.warmth, 0), 1)
        let castStrength = isNeutralBase
            ? CGFloat(warm) * 0.16 * CGFloat(1 - light * 0.7)
            : 0
        let warmSaturation = targetSaturation + castStrength
        let blendedHue = isNeutralBase ? hue + (Self.amberHue - hue) * CGFloat(warm) : hue

        return Color(hue: Double(blendedHue),
                     saturation: Double(min(warmSaturation, 1)),
                     brightness: Double(min(targetBrightness, 1)),
                     opacity: Double(alpha))
    }

    /// L'ambra delle lampade: circa 2200 K tradotti in tinta.
    nonisolated static let amberHue: CGFloat = 0.075
}
