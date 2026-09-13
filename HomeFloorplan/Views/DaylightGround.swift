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
    static let eveningLevel = 0.28

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

        static let night = Light(luminance: 0, warmth: 1)

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
        var imageBrightness: Double { 0.16 * luminance }

        /// Un filo di contrasto in più, a compensare l'appiattimento.
        var imageContrast: Double { 1 + 0.10 * luminance }

        /// La tinta calda da moltiplicare sul disegno.
        ///
        /// Moltiplicare e non sovrapporre: un velo sopra coprirebbe i tratti
        /// più sottili, mentre il prodotto scalda lasciando intatta la
        /// geometria. Il bianco puro a mezzogiorno è l'identità, quindi di
        /// giorno non succede niente.
        var imageTint: Color {
            Color(red: 1,
                  green: 1 - 0.06 * warmth,
                  blue: 1 - 0.14 * warmth)
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
            // Il pomeriggio resta puro sole; le lampade subentrano solo quando
            // il sole scende sotto di loro. Un raccordo che sollevasse tutta la
            // seconda metà renderebbe le cinque del pomeriggio più luminose
            // delle nove del mattino, che è la stessa altezza del sole.
            let luminance = t > 0.5 ? max(solar, eveningLevel) : solar
            return Light(luminance: luminance, warmth: warmth(solar: solar))
        }

        // Dopo il crepuscolo: il sole non c'è più, restano le lampade che si
        // consumano.
        return Light(luminance: eveningLevel * eveningFade(from: end, at: instant,
                                                           calendar: calendar),
                     warmth: 1)
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
    nonisolated static func warmth(solar: Double) -> Double {
        let height = min(max(solar, 0), 1)
        return pow(1 - height, 1.6)
    }

    /// Il fondo per un dato istante, a partire dal colore scelto dall'utente.
    ///
    /// `base` è la notte: a luce zero torna esattamente sé stesso, quindi al
    /// buio non c'è nessuna regressione rispetto a com'era prima.
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
