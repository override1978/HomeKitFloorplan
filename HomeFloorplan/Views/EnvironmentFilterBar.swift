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
            .background(
                Group {
                    if isSelected {
                        Capsule().fill(Color(.systemGreen))
                    } else {
                        Capsule().fill(.regularMaterial)
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? Color.clear : Color.white.opacity(0.25),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}
