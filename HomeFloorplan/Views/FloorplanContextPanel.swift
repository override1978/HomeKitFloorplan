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

            // ── Dismiss button — bottom centre, red ───────────────────────
            Button {
                overlayVM.dismissPanel()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                    Text(String(localized: "common.dismiss", defaultValue: "Chiudi"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.85), in: Capsule())
                .shadow(color: .red.opacity(0.30), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 16)
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
