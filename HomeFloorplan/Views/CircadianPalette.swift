import SwiftUI

// MARK: - CircadianPalette

/// I colori dell'interfaccia all'ora che è.
///
/// Finora la luce muoveva solo il fondo, e il risultato era incoerente: alle
/// otto di sera una planimetria ambra con sopra pillole grigio sistema, come
/// se la stanza avesse una temperatura e i mobili un'altra. Il fondo non è
/// l'ambiente: è solo la sua parte più grande.
///
/// Qui cambiano **quattro cose** — fondo, superficie, inchiostro, bordo — e
/// nient'altro. In particolare **non** cambiano i colori di categoria: giallo
/// luci, blu prese, rosa sicurezza restano identici a qualunque ora, perché
/// sono identità e non atmosfera. Una casa la cui luce cambia è una casa; una
/// casa in cui cambia anche il significato dei colori è un posto in cui non si
/// impara più niente.
struct CircadianPalette: Equatable, Sendable {

    /// Il fondo: il cielo dietro tutto.
    let ground: Color
    /// Le superfici che galleggiano sopra — card, pillole, pannelli.
    let surface: Color
    /// Quelle che devono staccare di più: una card sopra una card.
    let elevatedSurface: Color
    /// Il testo. Garantito leggibile sulla superficie, sempre.
    let ink: Color
    /// Il testo secondario, un gradino sotto ma ancora sopra la soglia.
    let secondaryInk: Color
    /// Il bordo che definisce una superficie senza gridarlo.
    let border: Color
    /// Vero quando la scena è scura: serve a chi deve ancora scegliere fra due
    /// risorse fisse, come le immagini.
    let isDark: Bool

    /// La soglia di leggibilità, e non è negoziabile.
    ///
    /// 4,5:1 è il minimo WCAG AA per il testo normale. Qui vale come vincolo e
    /// non come obiettivo: la palette può fare ciò che vuole con la tinta,
    /// purché alla fine il testo si legga anche alle 23:40 — che è l'ora in cui
    /// una palette che insegue l'atmosfera è più tentata di sbagliare.
    static let minimumContrast: Double = 4.5

    // MARK: Costruzione

    static func make(light cycle: DaylightGround.Light) -> CircadianPalette {
        let ground = DaylightGround.circadianGround(light: cycle)
        let (hue, saturation, brightness) = components(ground)
        let isDark = relativeLuminance(ground) < 0.30

        // La superficie si stacca dal fondo salendo di luce se il fondo è
        // scuro, e appena appena se è chiaro. Sopra un fondo quasi bianco una
        // card più chiara non esiste: lì a definirla è il bordo, che infatti
        // qui diventa più marcato.
        let surfaceBrightness = isDark
            ? min(brightness + 0.11, 1)
            : min(brightness + 0.035, 1)
        // Le superfici sono più calme del cielo: tengono la tinta, non la sua
        // intensità. Altrimenti una fila di pillole diventa una fila di
        // caramelle.
        let surface = Color(hue: hue, saturation: saturation * 0.55, brightness: surfaceBrightness)
        let elevated = Color(hue: hue,
                             saturation: saturation * 0.45,
                             brightness: isDark ? min(surfaceBrightness + 0.07, 1)
                                                : max(surfaceBrightness - 0.02, 0))

        // Il lato dell'inchiostro si decide dalla **superficie**, non dal fondo.
        //
        // Sono due cose diverse e lo si scopre a metà scala: un fondo scuro può
        // portare una superficie di luminosità media, e su quella il bianco non
        // arriva a 4,5:1 mentre il nero sì. Decidere dal fondo significava
        // scegliere il lato guardando l'oggetto sbagliato.
        let preferLight = relativeLuminance(surface) < 0.35
        let ink = readableInk(on: surface, hue: hue, preferLight: preferLight)
        let secondary = readableInk(on: surface, hue: hue, preferLight: preferLight,
                                    target: 3.0)
        // Il bordo non è un colore a sé: è l'inchiostro molto diluito, così
        // segue da solo il verso del contrasto senza doverlo decidere due volte.
        let border = ink.opacity(isDark ? 0.14 : 0.10)

        return CircadianPalette(ground: ground,
                                surface: surface,
                                elevatedSurface: elevated,
                                ink: ink,
                                secondaryInk: secondary,
                                border: border,
                                isDark: isDark)
    }

    /// L'inchiostro più vicino all'atmosfera che rispetti ancora la soglia.
    ///
    /// Si parte dal lato giusto — chiaro su fondo scuro, scuro su fondo chiaro —
    /// con un filo della tinta del cielo addosso, e lo si spinge verso
    /// l'estremo finché il rapporto non è soddisfatto. Cercare invece di
    /// imporre un bianco e un nero fissi darebbe sempre contrasto e toglierebbe
    /// ogni atmosfera; partire dall'atmosfera e correggere quanto basta tiene
    /// entrambe.
    nonisolated static func readableInk(on surface: Color,
                                        hue: Double,
                                        preferLight: Bool,
                                        target: Double = minimumContrast) -> Color {
        // Si prova il lato preferito, e se non basta si prova l'altro.
        //
        // La seconda prova non è una ridondanza: a metà scala esiste una fascia
        // in cui un lato solo non ce la fa mai, per quanto lo si spinga. Una
        // ricerca che non cambia mai direzione lì non trova nulla e restituisce
        // il suo estremo — cioè un testo illeggibile con l'aria di essere stato
        // verificato.
        for light in preferLight ? [true, false] : [false, true] {
            if let ink = search(on: surface, hue: hue, light: light, target: target) {
                return ink
            }
        }
        // Nessuno dei due lati arriva: vince il migliore dei due, e la
        // leggibilità batte l'atmosfera.
        return contrastRatio(.white, surface) >= contrastRatio(.black, surface) ? .white : .black
    }

    /// Parte dall'atmosfera e si spinge verso l'estremo finché basta.
    ///
    /// Imporre un bianco e un nero fissi darebbe sempre contrasto e toglierebbe
    /// ogni temperatura; partire dalla tinta del cielo e correggere quanto
    /// serve tiene entrambe.
    nonisolated private static func search(on surface: Color,
                                           hue: Double,
                                           light: Bool,
                                           target: Double) -> Color? {
        var brightness = light ? 0.92 : 0.26
        var saturation = light ? 0.05 : 0.30
        for _ in 0..<26 {
            let candidate = Color(hue: hue, saturation: saturation, brightness: brightness)
            if contrastRatio(candidate, surface) >= target { return candidate }
            brightness = light ? min(brightness + 0.03, 1) : max(brightness - 0.015, 0)
            saturation = max(saturation - 0.015, 0)
        }
        return nil
    }

    // MARK: Contrasto

    nonisolated static func contrastRatio(_ a: Color, _ b: Color) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        let lighter = max(la, lb), darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Luminanza relativa secondo WCAG: i canali pesano in modo molto diverso,
    /// e una media semplice sbaglierebbe proprio sui fondi colorati.
    nonisolated static func relativeLuminance(_ color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    nonisolated private static func components(_ color: Color) -> (Double, Double, Double) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (Double(h), Double(s), Double(b))
    }
}

// MARK: - Environment

private struct CircadianPaletteKey: EnvironmentKey {
    /// Il default è la modalità classica: nessuna atmosfera, i token di sempre.
    /// Così una vista che non riceve la palette non si rompe — si limita a non
    /// seguire la luce, che è esattamente il comportamento con l'interruttore
    /// spento.
    static let defaultValue: CircadianPalette? = nil
}

extension EnvironmentValues {
    var circadianPalette: CircadianPalette? {
        get { self[CircadianPaletteKey.self] }
        set { self[CircadianPaletteKey.self] = newValue }
    }
}
