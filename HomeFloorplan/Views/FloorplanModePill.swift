import SwiftUI

// MARK: - FloorplanModePill

/// Bottom-centre floating pill that lets the user switch overlay modes.
/// Only visible when 2+ modes are available; hidden (not removed) otherwise
/// so the layout doesn't shift.
struct FloorplanModePill: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let context: FloorplanOverlayContext

    private var modes: [FloorplanOverlayMode] {
        overlayVM.availableModes(context: context)
    }

    var body: some View {
        // Collapse when only one mode is available.
        if modes.count > 1 {
            GlassTitlePill {
                HStack(spacing: 0) {
                    ForEach(modes) { mode in
                        modeButton(mode)
                        if mode != modes.last {
                            Divider().frame(height: 20)
                        }
                    }
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: FloorplanOverlayMode) -> some View {
        let isActive = overlayVM.activeMode == mode
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                overlayVM.activeMode = mode
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: mode.pillIcon)
                    .font(.system(size: 14, weight: .semibold))
                Text(mode.label)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .foregroundStyle(isActive ? mode.accentColor : Color.primary.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3), value: isActive)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    struct PreviewWrapper: View {
        @State private var vm = FloorplanOverlayViewModel(floorplanID: UUID())
        var body: some View {
            ZStack {
                Color.gray.ignoresSafeArea()
                VStack {
                    Spacer()
                    FloorplanModePill(
                        overlayVM: vm,
                        context: FloorplanOverlayContext(
                            hasEnvironmentData: true,
                            hasSecurityDevices: true,
                            hasAIService: true,
                            hasIntelligenceSuggestions: true
                        )
                    )
                    .padding(.bottom, 40)
                }
            }
        }
    }
    return PreviewWrapper()
}
#endif
