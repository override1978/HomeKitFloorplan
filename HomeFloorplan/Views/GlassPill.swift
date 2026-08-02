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

struct GlassCircle<Content: View>: View {
    let content: Content
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed
    
    init(size: CGFloat = 40, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }
    
    @ViewBuilder
    var body: some View {
        if isLiquidGlassEnabled && !isLiquidGlassSuppressed {
            if #available(iOS 26.0, *) {
                content
                    .frame(width: size, height: size)
                    .glassEffect(.regular.interactive(), in: Circle())
            } else {
                legacyBody
            }
        } else {
            legacyBody
        }
    }

    private var legacyBody: some View {
        content
            .frame(width: size, height: size)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(legacyGlassBorderColor(colorScheme), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
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

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.55

    private let circleSize: CGFloat = 48

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                // ── Marker circle with pulsing ring ──────────────────────
                ZStack {
                    // Outer pulse ring
                    Circle()
                        .stroke(mode.accentColor.opacity(pulseOpacity), lineWidth: 2.5)
                        .frame(width: circleSize + 14, height: circleSize + 14)
                        .scaleEffect(pulseScale)

                    // Inner filled circle (matches AccessoryMarkerView style)
                    Circle()
                        .fill(.regularMaterial)
                        .overlay(
                            Circle()
                                .strokeBorder(mode.accentColor.opacity(0.45), lineWidth: 1.5)
                        )
                        .frame(width: circleSize, height: circleSize)
                        .shadow(color: mode.accentColor.opacity(0.30), radius: 8, y: 3)
                        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)

                    // Icon
                    Image(systemName: mode.pillIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(mode.accentColor)
                }

                // ── Label pill (mirrors AccessoryMarkerView label) ────────
                Text(mode.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(mode.accentColor.opacity(0.25), lineWidth: 0.5)
                    )
                    .foregroundStyle(mode.accentColor)
            }
        }
        .buttonStyle(.plain)
        .id(mode)              // force view recreation when mode changes → resets @State + restarts onAppear
        .onAppear { startPulse() }
    }

    private func startPulse() {
        // Reset to initial values before animating so the new mode's color takes effect immediately.
        pulseScale = 1.0
        pulseOpacity = 0.55
        withAnimation(
            .easeInOut(duration: 1.3)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.18
            pulseOpacity = 0.0
        }
    }
}
