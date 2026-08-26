import SwiftUI

// MARK: - FloorplanTokens

/// Registro centrale dei colori della vista planimetria.
///
/// Prima del redesign i colori vivevano inline nei singoli file — urgenze in
/// `AccessoryMarkerView`, accenti modo in `FloorplanOverlayMode`, superfici
/// sparse ovunque — e ogni superficie nuova doveva reinventarli. Qui c'è la
/// palette del design handoff (`design_handoff_floorplan_ux/README.md`,
/// sezione "Design Tokens"), completa delle varianti scure che l'handoff non
/// copre: l'app supporta planimetrie scure e il chrome eredita lo schema dalla
/// luminanza del disegno (`chromeColorScheme`), quindi ogni token DEVE
/// risolversi in entrambi gli schemi.
///
/// I token sono dinamici via `UIColor` provider: rispondono anche allo schema
/// iniettato con `.environment(\.colorScheme, …)`, non solo a quello di
/// sistema — che è esattamente il meccanismo con cui l'editor pilota la
/// chrome sopra planimetrie chiare o scure.
///
/// Le opacità dei fill stanza (es. verde .16 in Ambiente) si applicano al
/// momento dell'uso con `.opacity(_:)`: il registro tiene i colori pieni.
enum FloorplanTokens {

    // MARK: Semantici

    /// Stati semantici condivisi da barra di stato, chip in-place e pannelli.
    enum Semantic {
        /// Verde "ok" per pallini e fill leggeri.
        static let ok = Color(light: 0x4CAF6D, dark: 0x6FC48F)
        /// Verde profondo per testo e bottoni d'azione positivi.
        static let okDeep = Color(light: 0x3D9A5F, dark: 0x5CB27E)
        /// Arancio "attenzione": aperture, stanze da arieggiare.
        static let warning = Color(light: 0xE0762F, dark: 0xF0894A)
        /// Rosso "critico": allarmi, situazioni critiche, badge tab.
        static let critical = Color(light: 0xC23B3B, dark: 0xE06565)
    }

    // MARK: Modi (tab)

    /// Colori dei 4 tab. Deciso il 26/08/2026: si seguono i colori del design,
    /// non quelli di sistema usati finora (Sicurezza era `systemPurple`,
    /// Intelligenza `systemIndigo`).
    enum Mode {
        static func accent(_ mode: FloorplanOverlayMode) -> Color {
            switch mode {
            case .controls:     return Color(light: 0xE07030, dark: 0xF08C4E)
            case .environment:  return Color(light: 0x3D9A5F, dark: 0x5CB27E)
            case .security:     return Color(light: 0xC94F9E, dark: 0xDD74B8)
            case .intelligence: return Color(light: 0x8B7FD6, dark: 0xA89EE6)
            }
        }

        /// Sfondo del segmento attivo nella pill dei modi.
        static func activeBackground(_ mode: FloorplanOverlayMode) -> Color {
            switch mode {
            case .controls:     return Color(light: 0xFBD9C3, dark: 0x4A2E1C)
            case .environment:  return Color(light: 0xD5EAD8, dark: 0x1F3A2A)
            case .security:     return Color(light: 0xF7D9EC, dark: 0x45253A)
            case .intelligence: return Color(light: 0xE2DEF7, dark: 0x2E2950)
            }
        }

        /// Testo/glifo del segmento attivo: più profondo dell'accento perché
        /// deve reggere il contrasto sopra `activeBackground`.
        static func activeForeground(_ mode: FloorplanOverlayMode) -> Color {
            switch mode {
            case .controls:     return Color(light: 0xC05621, dark: 0xF5A374)
            case .environment:  return Color(light: 0x2F7A49, dark: 0x7ECB99)
            case .security:     return Color(light: 0xA4457F, dark: 0xE393C6)
            case .intelligence: return Color(light: 0x6C60C4, dark: 0xB7AEF0)
            }
        }
    }

    // MARK: Categorie dispositivo

    /// Colori per categoria: marker, pallini dei cluster, chip filtro.
    /// Il design ne nomina cinque (luci, prese, clima, sensori, media); le
    /// altre categorie di `AccessoryCategory` sono mappate qui per famiglia —
    /// la sicurezza sul rosa del tab Sicurezza, l'aria sul clima, il resto
    /// sul grigio dei sensori — così nessun chiamante deve inventarsi un
    /// colore fuori registro.
    enum Category {
        /// Marker spento / inattivo, uguale per tutte le categorie.
        static let off = Color(light: 0xCFC9BD, dark: 0x57514A)

        static func color(for category: AccessoryCategory) -> Color {
            switch category {
            case .lights:                    return Color(light: 0xE8B93A, dark: 0xF0C95E)
            case .outlets, .switches:        return Color(light: 0x3F8FD8, dark: 0x6AAAE4)
            case .climate, .air:             return Color(light: 0xE0762F, dark: 0xF0894A)
            case .television:                return Color(light: 0x8B7FD6, dark: 0xA89EE6)
            case .security, .cameras:        return Color(light: 0xC94F9E, dark: 0xDD74B8)
            case .windowCoverings:           return Color(light: 0x8FA378, dark: 0xA8BC90)
            case .sensors, .hubs, .buttons,
                 .others, .all:              return Color(light: 0xA9A294, dark: 0x8F8A7E)
            }
        }
    }

    // MARK: Superfici

    /// Superfici della chrome e della planimetria. Nota: molte superfici
    /// flottanti passano da `glassChromeSurface` e non da qui — questi token
    /// servono alle superfici opache del redesign (card cluster, card
    /// pannello, fill stanza espansa).
    enum Surface {
        /// Sfondo app / crema di riferimento del design.
        static let appBackground = Color(light: 0xFAF0DE, dark: 0x1D1814)
        /// Superficie delle pill di stato.
        static let pill = Color(light: 0xFDF7EC, dark: 0x26201B)
        /// Card bianche (cluster, pannello).
        static let card = Color(light: 0xFFFFFF, dark: 0x2D2620)
        /// Fill neutro delle stanze nel tab Controlli.
        static let roomFill = Color(light: 0xFDFBF5, dark: 0x221C17)
        /// Fill della stanza espansa (leggermente scurito).
        static let roomFillExpanded = Color(light: 0xF3EFE3, dark: 0x322B24)
        /// Etichetta capsule scura sotto i marker (fissa, non dinamica: deve
        /// staccare dal disegno in entrambi gli schemi).
        static let markerLabel = Color(light: 0x4A443D, dark: 0x4A443D).opacity(0.88)
        /// Chip filtro attivo (fill scuro, testo bianco).
        static let filterChipActive = Color(light: 0x4A443D, dark: 0xD6CFC3)
    }

    // MARK: Testo

    /// Gerarchia testo per le superfici opache del redesign. Le superfici
    /// glass continuano a usare `.primary`/`.secondary` di sistema, che il
    /// vetro adatta da sé.
    enum Text {
        static let primary = Color(light: 0x2E2A24, dark: 0xF0E8DB)
        static let secondary = Color(light: 0x5A5348, dark: 0xC4B9A8)
        static let tertiary = Color(light: 0x8A8275, dark: 0x948A7A)
        static let disabled = Color(light: 0xB3A992, dark: 0x5F574A)
    }
}

// MARK: - Costruzione colori dinamici

private extension Color {
    /// Colore dinamico da coppia di esadecimali sRGB (chiaro/scuro).
    /// Passa da `UIColor` con provider così il colore si risolve contro il
    /// trait effettivo della gerarchia — incluso lo schema iniettato con
    /// `.environment(\.colorScheme, …)` dal `chromeColorScheme` dell'editor.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(srgbHex: dark)
                : UIColor(srgbHex: light)
        })
    }
}

private extension UIColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
