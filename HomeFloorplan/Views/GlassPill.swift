import SwiftUI

struct GlassPill<Content: View>: View {
    let content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}

struct GlassCircle<Content: View>: View {
    let content: Content
    let size: CGFloat
    
    init(size: CGFloat = 40, @ViewBuilder content: () -> Content) {
        self.size = size
        self.content = content()
    }
    
    var body: some View {
        content
            .frame(width: size, height: size)
            .background(.regularMaterial, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
    }
}

/// Variante più opaca del GlassPill, usata quando serve massima leggibilità
/// del testo sopra contenuti molto variabili (es. titolo sopra una galleria
/// di immagini). Usa .regularMaterial invece di .ultraThinMaterial.
struct GlassTitlePill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 3)
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
