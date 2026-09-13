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

    /// Il seno sull'intervallo esteso: sale piano, culmina a mezzogiorno,
    /// scende piano. È la forma della cosa vera, e costa una riga.
    nonisolated static func daylight(at instant: Date,
                                     sunrise: Date?,
                                     sunset: Date?) -> Double {
        guard let sunrise, let sunset, sunset > sunrise else { return 0 }
        let start = sunrise.addingTimeInterval(-twilight)
        let end = sunset.addingTimeInterval(twilight)
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        let t = instant.timeIntervalSince(start) / span
        guard (0...1).contains(t) else { return 0 }
        return sin(.pi * t)
    }

    /// Quanto il fondo è caldo: massimo appena sopra l'orizzonte, niente altrove.
    ///
    /// Poco e in un punto solo, perché è lì che la luce vera è davvero calda —
    /// e perché un fondo tiepido tutto il giorno diventa semplicemente un fondo
    /// beige, cioè una scelta di gusto invece di un'informazione.
    nonisolated static func warmth(daylight: Double) -> Double {
        max(0, 1 - abs(daylight - 0.25) / 0.35)
    }

    /// Il fondo per un dato istante, a partire dal colore scelto dall'utente.
    ///
    /// `base` è la notte: a luce zero torna esattamente sé stesso, quindi al
    /// buio non c'è nessuna regressione rispetto a com'era prima.
    nonisolated static func ground(base: Color, daylight: Double) -> Color {
        let light = min(max(daylight, 0), 1)
        guard light > 0 else { return base }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(base).getHue(&hue, saturation: &saturation,
                                   brightness: &brightness, alpha: &alpha) else { return base }

        // La luminanza di giorno non viene dal colore scelto ma dalla luce: un
        // fondo già scuro resterebbe scuro, e l'intera idea non si vedrebbe.
        // Si sale verso una carta chiara, non verso il bianco — il bianco pieno
        // sotto i muri di una planimetria abbaglia e mangia i contorni.
        let dayBrightness: CGFloat = 0.90
        let targetBrightness = brightness + (dayBrightness - brightness) * CGFloat(light)

        // Salendo di luce il fondo si smorza: un colore saturo che diventa
        // anche chiaro urla, e questo è il pavimento su cui tutto il resto
        // deve poter apparire.
        let targetSaturation = saturation * CGFloat(1 - light * 0.55)

        let warm = warmth(daylight: light)
        // Un soffio d'ambra all'orizzonte, mai più di così.
        let warmSaturation = targetSaturation + CGFloat(warm) * 0.07
        let warmHue: CGFloat = saturation < 0.02 ? 0.09 : hue  // fondi neutri prendono l'ambra
        let blendedHue = hue + (warmHue - hue) * CGFloat(warm)

        return Color(hue: Double(blendedHue),
                     saturation: Double(min(warmSaturation, 1)),
                     brightness: Double(min(targetBrightness, 1)),
                     opacity: Double(alpha))
    }
}
