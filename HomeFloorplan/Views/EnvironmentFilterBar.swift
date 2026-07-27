import SwiftUI

// MARK: - EnvironmentFilterBar

/// Horizontal scrollable filter bar for the Environment overlay mode.
/// Shown below the top-bar mode pill when `activeMode == .environment`.
///
/// Selecting a pill filters the heatmap, room badges, and context dashboard
/// to display data for the chosen sensor type only.
/// The "Tutto" pill resets to the aggregate (worst-urgency) view.
struct EnvironmentFilterBar: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    /// Sensor types that have real data — supplied by `EnvironmentViewModel.availableSensorTypes`.
    let availableTypes: [SensorServiceType]

    /// The pill row content — shared between fixed and scrollable layouts.
    private var pillRow: some View {
        LiquidGlassContainer(spacing: 0) {
        HStack(spacing: 8) {
            filterPill(
                label: String(localized: "filter.all", defaultValue: "Tutto"),
                icon: "leaf.fill",
                isSelected: overlayVM.selectedSensorFilter == nil
            ) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    overlayVM.selectedSensorFilter = nil
                }
            }
            ForEach(availableTypes) { type in
                filterPill(
                    label: type.displayName,
                    icon: type.sfSymbol,
                    isSelected: overlayVM.selectedSensorFilter == type
                ) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        overlayVM.selectedSensorFilter =
                            overlayVM.selectedSensorFilter == type ? nil : type
                    }
                }
            }
        }
        .padding(.vertical, 4)
        }
    }

    var body: some View {
        // ViewThatFits: if pills fit without scrolling, centre them;
        // otherwise fall back to a horizontal scroll view.
        ViewThatFits(in: .horizontal) {
            // Fixed, centred layout (used when everything fits)
            pillRow
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .center)

            // Scrollable fallback (used when there are many sensor types)
            ScrollView(.horizontal, showsIndicators: false) {
                pillRow
                    .padding(.horizontal, 20)
            }
        }
    }

    // MARK: Pill surface

    /// Superficie del chip filtro. Col vetro attivo la selezione è una tinta
    /// verde sul vetro invece di un riempimento pieno; il bordo manuale sparisce
    /// perché il vetro porta il proprio. Nel fallback il bordo è theme-aware:
    /// era un bianco fisso, invisibile su planimetria chiara.
    private struct FilterPillSurface: ViewModifier {
        let isSelected: Bool
        @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
        private var isLiquidGlassEnabled = false
        @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed
        @Environment(\.colorScheme) private var colorScheme

        @ViewBuilder
        func body(content: Content) -> some View {
            if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
                // NIENTE .interactive(): installa una propria gestione del
                // tocco che compete col Button che avvolge il contenuto, e il
                // primo tap va perso.
                content.glassEffect(
                    isSelected ? .regular.tint(Color(.systemGreen)) : .regular,
                    in: Capsule()
                )
            } else {
                content
                    .background(
                        Capsule().fill(isSelected ? AnyShapeStyle(Color(.systemGreen))
                                                  : AnyShapeStyle(.regularMaterial))
                    )
                    .overlay(
                        Capsule().strokeBorder(
                            isSelected ? Color.clear : legacyGlassBorderColor(colorScheme),
                            lineWidth: 0.5
                        )
                    )
            }
        }
    }

    // MARK: Pill button

    private func filterPill(
        label: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? .white : Color.primary.opacity(0.7))
            .modifier(FilterPillSurface(isSelected: isSelected))
            // Area sensibile dichiarata esplicitamente: senza, il tocco deriva
            // da ciò che il vetro disegna e i tap sul padding vanno persi.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}
