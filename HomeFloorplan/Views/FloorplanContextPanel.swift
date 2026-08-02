import SwiftUI

// MARK: - FloorplanContextPanel

/// Floating cards panel for floorplan overlays.
/// A small dismiss button (GlassCircle) anchors to the top-right edge.
struct FloorplanContextPanel<Content: View>: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let title: String
    let accentColor: Color
    let content: Content

    init(
        overlayVM: FloorplanOverlayViewModel,
        title: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.overlayVM = overlayVM
        self.title = title
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Floating cards ────────────────────────────────────────────
            ScrollView {
                content
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .safeAreaPadding(.top, 14)

            // ── Dismiss button — bottom centre ────────────────────────────
            //
            // Resta un bottone e non diventa "tocca fuori per chiudere": il
            // tocco sulla planimetria è già impegnato — `handleBackgroundTap`
            // risolve i tap sulle stanze e piazza i marker — e assegnargli anche
            // la chiusura renderebbe ambiguo ogni tocco fuori dal pannello.
            GlassDismissButton {
                overlayVM.dismissPanel()
            }
            .padding(.bottom, 16)
        }
    }
}

// MARK: - GlassDismissButton

/// Chiusura del pannello, in vetro.
///
/// Era una capsula rossa piena con un'ombra rossa disegnata a mano: il modo
/// pre-vetro di dare peso a un'azione. Con `.buttonStyle(.glass)` la superficie
/// **è** il controllo — si comprime e risponde al tocco — e il rosso resta dove
/// serve davvero, cioè sul contenuto, a dire cosa fa il bottone senza gridarlo.
private struct GlassDismissButton: View {
    let action: () -> Void

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
            Text(String(localized: "common.dismiss", defaultValue: "Chiudi"))
                .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    var body: some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            Button(action: action) {
                label.foregroundStyle(Color.red)
            }
            .buttonStyle(.glass)
        } else {
            Button(action: action) {
                label
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .shadow(color: .red.opacity(0.30), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - FloorplanContextPanelContainer

/// Wraps `FloorplanContextPanel` with a slide-in animation from the right.
/// No dim backdrop — the panel is transparent so the floorplan stays fully visible.
struct FloorplanContextPanelContainer<Content: View>: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerWidth: CGFloat
    let title: String
    let accentColor: Color
    let content: Content

    init(
        overlayVM: FloorplanOverlayViewModel,
        containerWidth: CGFloat,
        title: String,
        accentColor: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.overlayVM = overlayVM
        self.containerWidth = containerWidth
        self.title = title
        self.accentColor = accentColor
        self.content = content()
    }

    private var panelWidth: CGFloat {
        min(containerWidth * 0.72, 320)
    }

    var body: some View {
        // No ZStack dim layer — panel slides in as a pure overlay
        HStack(spacing: 0) {
            Spacer()
            FloorplanContextPanel(
                overlayVM: overlayVM,
                title: title,
                accentColor: accentColor
            ) {
                content
            }
            .frame(width: panelWidth)
            .offset(x: overlayVM.isPanelVisible ? 0 : panelWidth + 20)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: overlayVM.isPanelVisible)
        }
        .ignoresSafeArea(edges: .vertical)
        .zIndex(100)
    }
}
