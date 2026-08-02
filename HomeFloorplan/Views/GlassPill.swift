import SwiftUI

enum AppAppearanceSettings {
    static let liquidGlassEnabledKey = "appearance.liquidGlassEnabled"
}

private struct LiquidGlassSuppressionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isLiquidGlassSuppressed: Bool {
        get { self[LiquidGlassSuppressionKey.self] }
        set { self[LiquidGlassSuppressionKey.self] = newValue }
    }
}

struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat?
    let content: Content
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if isLiquidGlassEnabled && !isLiquidGlassSuppressed {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) {
                    content
                }
            } else {
                content
            }
        } else {
            content
        }
    }
}

/// Bordo del fallback non-vetro, adattato al tema: un bianco fisso sparisce su
/// fondo chiaro. Condiviso da GlassPill e GlassCircle, che prima lo avevano
/// cablato mentre GlassTitlePill lo calcolava già correttamente.
func legacyGlassBorderColor(_ scheme: ColorScheme) -> Color {
    scheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.11)
}

struct GlassPill<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    @ViewBuilder
    var body: some View {
        if isLiquidGlassEnabled && !isLiquidGlassSuppressed {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular, in: Capsule())
            } else {
                legacyBody
            }
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(legacyGlassBorderColor(colorScheme), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}

// MARK: - Superficie di chrome flottante

/// Ombra del ramo legacy, quando la superficie ne aveva una.
struct GlassChromeShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

extension View {
    /// Superficie per la chrome che **fluttua sopra il contenuto** — barre,
    /// pannelli, banner: vetro col toggle attivo, esattamente il materiale di
    /// prima altrimenti.
    ///
    /// Serve a smettere di riscrivere a mano `background + overlay(bordo) +
    /// shadow` in ogni file: era il motivo per cui `DrawingToolbars.swift`
    /// (12 superfici flottanti) era rimasto interamente fuori dall'adozione
    /// senza che nessun audit se ne accorgesse.
    ///
    /// Bordo e ombra vivono **solo** nel ramo legacy: il vetro porta con sé il
    /// proprio bordo e la propria profondità, e sovrapporgliene di disegnati a
    /// mano è la ricetta per la superficie "quasi vetro" che stona.
    /// `tint` dà identità alla superficie **nel vetro**. Serve quando quella
    /// identità oggi è affidata a un bordo colorato: il bordo disegnato a mano
    /// non va portato sul vetro, e la tinta è il modo previsto per ottenere lo
    /// stesso significato. Aiuta anche dove il vetro non ha nulla da rifrangere
    /// — sopra una planimetria chiara e ferma degrada a lastra grigia, e la
    /// tinta gli restituisce carattere senza dipendere dallo sfondo.
    /// `legacyFill` accetta qualunque stile, non solo un `Material`: gli item
    /// delle barre di disegno usano riempimenti tenui a colore, e senza questo
    /// servirebbe una seconda primitiva quasi identica accanto a questa.
    func glassChromeSurface<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        legacyFill: AnyShapeStyle = AnyShapeStyle(.regularMaterial),
        legacyBorder: Color? = nil,
        legacyBorderWidth: CGFloat = 1,
        legacyShadow: GlassChromeShadow? = nil
    ) -> some View {
        modifier(GlassChromeSurface(
            shape: shape,
            tint: tint,
            legacyFill: legacyFill,
            legacyBorder: legacyBorder,
            legacyBorderWidth: legacyBorderWidth,
            legacyShadow: legacyShadow
        ))
    }
}

private struct GlassChromeSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let legacyFill: AnyShapeStyle
    let legacyBorder: Color?
    let legacyBorderWidth: CGFloat
    let legacyShadow: GlassChromeShadow?

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: shape)
        } else {
            content
                .background(legacyFill, in: shape)
                .overlay {
                    if let legacyBorder {
                        shape.strokeBorder(legacyBorder, lineWidth: legacyBorderWidth)
                    }
                }
                .shadow(color: legacyShadow?.color ?? .clear,
                        radius: legacyShadow?.radius ?? 0,
                        x: legacyShadow?.x ?? 0,
                        y: legacyShadow?.y ?? 0)
        }
    }
}

// MARK: - GlassIconButton

/// Bottone circolare con icona, in vetro **interattivo**.
///
/// Rimpiazza il pattern `Button { GlassCircle { … } }.buttonStyle(.plain)`, che
/// era l'anti-pattern indicato da Apple: il vetro finiva DENTRO la label, così
/// restava una lastra ferma mentre il bottone gestiva il tocco per conto suo.
/// Il risultato era vetro che non reagisce — cioè tutto il "glass" e niente del
/// "liquid". Con `.buttonStyle(.glass)` la superficie **è** il controllo: si
/// comprime, rimbalza e sposta il riflesso sotto il dito.
///
/// ⚠️ Non ottenere lo stesso effetto mettendo `.interactive()` a mano sul vetro
/// dentro la label di un Button: i due gestori del tocco competono e i tap si
/// perdono (regressione già vista sui chip filtro dell'overlay Ambiente).
///
/// Il frame è applicato DOPO lo stile, non alla label: lo stile aggiunge un
/// padding proprio, quindi vincolare la label darebbe un controllo più grande
/// di `size`. Proponendo la misura al bottone intero, la superficie di vetro si
/// disegna esattamente in `size`, come faceva GlassCircle.
struct GlassIconButton<Label: View>: View {
    private let size: CGFloat
    private let action: () -> Void
    private let label: Label

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    init(size: CGFloat = 40,
         action: @escaping () -> Void,
         @ViewBuilder label: () -> Label) {
        self.size = size
        self.action = action
        self.label = label()
    }

    @ViewBuilder
    var body: some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .frame(width: size, height: size)
        } else {
            Button(action: action) { legacyLabel }
                .buttonStyle(.plain)
        }
    }

    private var legacyLabel: some View {
        label
            .frame(width: size, height: size)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(legacyGlassBorderColor(colorScheme), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}

/// Variante più opaca del GlassPill, usata quando serve massima leggibilità
/// del testo sopra contenuti molto variabili (es. titolo sopra una galleria
/// di immagini). Usa .regularMaterial invece di .ultraThinMaterial.
struct GlassTitlePill<Content: View>: View {
    let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if isLiquidGlassEnabled && !isLiquidGlassSuppressed {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular, in: Capsule())
            } else {
                legacyBody
            }
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(titleBorderColor, lineWidth: 0.6)
            )
            .shadow(color: titleShadowColor, radius: 11, x: 0, y: 3)
    }

    private var titleBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.35) : Color.black.opacity(0.11)
    }

    private var titleShadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.12) : Color.black.opacity(0.09)
    }
}

// MARK: - OverlayPanelMarkerButton

/// Pulsante per aprire il pannello contestuale nelle modalità overlay (Ambiente, Sicurezza, …).
/// Simula lo stile di un AccessoryMarkerView: cerchio con icona + label pill sotto.
/// Un anello concentrico pulsa in loop per segnalare l'interattività.
struct OverlayPanelMarkerButton: View {

    let mode: FloorplanOverlayMode
    let action: () -> Void

    private let circleSize: CGFloat = 48

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // ── Marker circle with pulsing ring ──────────────────────
                ZStack {
                    // Anello che pulsa. Resta FUORI dal vetro, e non per caso:
                    // ha diametro 62 (fino a ~73 pulsando) contro i 48 del
                    // cerchio, quindi il suo tratto sta a raggio 31+ mentre il
                    // vetro ha raggio 24. Il vetro campiona solo ciò che sta
                    // dietro la propria forma, e l'anello non ci entra mai —
                    // altrimenti un'animazione `repeatForever` lo costringerebbe
                    // a ricampionare il backdrop a ogni fotogramma, per sempre.
                    //
                    // La pulsazione è guidata da `phaseAnimator`, non più da
                    // `withAnimation(.repeatForever)` dentro `onAppear`. Quel
                    // `onAppear` scattava DENTRO la transazione del cambio
                    // modalità, e la molla ambientale sovrascriveva il
                    // repeatForever: l'anello andava una volta sola al suo stato
                    // finale — opacità 0 — e restava invisibile. Ecco perché
                    // arrivando su Sicurezza o Intelligenza non pulsava nulla.
                    // Il phaseAnimator si guida da sé: non dipende da quando
                    // `onAppear` scatta né da quale animazione è in corso.
                    Circle()
                        .stroke(mode.accentColor, lineWidth: 2.5)
                        .frame(width: circleSize + 14, height: circleSize + 14)
                        .phaseAnimator([false, true]) { ring, isExpanded in
                            ring
                                .scaleEffect(isExpanded ? 1.18 : 1.0)
                                .opacity(isExpanded ? 0 : 0.55)
                        } animation: { _ in
                            .easeInOut(duration: 1.3)
                        }

                    // Cerchio e icona sono ora una cosa sola: il vetro è la
                    // superficie del controllo, non un riempimento sotto di
                    // esso. La tinta prende il posto di bordo e alone colorati,
                    // che erano il modo pre-vetro di dire "questo non è un
                    // bottone qualsiasi, appartiene a questa modalità".
                    Image(systemName: mode.pillIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(mode.accentColor)
                        .frame(width: circleSize, height: circleSize)
                        .modifier(MarkerCircleSurface(tint: mode.accentColor))
                }

                // ── Label pill (mirrors AccessoryMarkerView label) ────────
                Text(mode.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(mode.accentColor)
                    .modifier(MarkerLabelSurface(tint: mode.accentColor))
            }
            // Area sensibile esplicita su TUTTO il controllo, anello compreso.
            //
            // Prima il cerchio era una forma riempita, che offre da sé area
            // toccabile su tutti i suoi punti. Ora è un'icona su `glassEffect`,
            // e il vetro non contribuisce in modo affidabile all'area sensibile:
            // il tocco si riduceva più o meno al glifo, da cui "difficilmente
            // tappabile". Vale ogni volta che una superficie riempita diventa
            // vetro — non è una particolarità di questo bottone.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(mode)              // ricrea la view al cambio modalità: riavvia il phaseAnimator
    }

    /// Superficie del cerchio.
    ///
    /// Niente `.interactive()`: il vetro vive dentro la label di un Button, e i
    /// due gestori del tocco competono facendo perdere i tap. Niente ombre sul
    /// ramo vetro: le porta con sé.
    private struct MarkerCircleSurface: ViewModifier {
        let tint: Color
        @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
        private var isLiquidGlassEnabled = false
        @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

        @ViewBuilder
        func body(content: Content) -> some View {
            if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(tint.opacity(0.28)), in: Circle())
            } else {
                content
                    .background(.regularMaterial, in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(tint.opacity(0.45), lineWidth: 1.5)
                    )
                    .shadow(color: tint.opacity(0.30), radius: 8, y: 3)
                    .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
            }
        }
    }

    /// Superficie dell'etichetta sotto il cerchio. Tinta più leggera: è
    /// contenuto secondario e non deve competere col cerchio.
    private struct MarkerLabelSurface: ViewModifier {
        let tint: Color
        @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
        private var isLiquidGlassEnabled = false
        @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

        @ViewBuilder
        func body(content: Content) -> some View {
            if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(tint.opacity(0.16)), in: Capsule())
            } else {
                content
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(tint.opacity(0.25), lineWidth: 0.5)
                    )
            }
        }
    }

}
