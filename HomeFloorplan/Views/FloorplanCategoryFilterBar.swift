import SwiftUI

// MARK: - FloorplanCategoryFilterBar

/// Riga di chip per il filtro categoria del tab Controlli (redesign, novità C):
/// "Tutti · N" più una chip per categoria presente sul piano, col pallino del
/// colore categoria e il conteggio. La chip attiva è piena scura con testo
/// bianco, come da design.
///
/// Stesso impianto di `EnvironmentFilterBar`: riga centrata se ci sta,
/// scorrevole altrimenti; `contentShape` esplicito sulle chip (il vetro non
/// offre hit-test affidabile) e mai `.interactive()` dentro un `Button`.
struct FloorplanCategoryFilterBar: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let counts: [FloorplanRoomCluster.CategoryCount]

    private var totalCount: Int { counts.reduce(0) { $0 + $1.total } }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            chipRow
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, alignment: .center)

            ScrollView(.horizontal, showsIndicators: false) {
                chipRow
                    .padding(.horizontal, 20)
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            categoryChip(
                label: String(localized: "floorplan.filter.all",
                              defaultValue: "All · \(totalCount)"),
                dotColor: nil,
                isSelected: overlayVM.categoryFilter == nil
            ) {
                setFilter(nil)
            }

            ForEach(counts) { count in
                categoryChip(
                    label: "\(count.category.displayName) · \(count.total)",
                    dotColor: FloorplanTokens.Category.color(for: count.category),
                    isSelected: overlayVM.categoryFilter == count.category
                ) {
                    // Toggle: ritoccare la chip attiva torna a "Tutti".
                    setFilter(overlayVM.categoryFilter == count.category ? nil : count.category)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func setFilter(_ category: AccessoryCategory?) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            overlayVM.categoryFilter = category
        }
    }

    private func categoryChip(label: String,
                              dotColor: Color?,
                              isSelected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dotColor {
                    Circle()
                        .fill(isSelected ? FloorplanTokens.Surface.filterChipActiveText : dotColor)
                        .frame(width: 8, height: 8)
                }
                Text(label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected
                             ? FloorplanTokens.Surface.filterChipActiveText
                             : Color.primary.opacity(0.7))
            .modifier(CategoryChipSurface(isSelected: isSelected))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isSelected)
    }
}

// MARK: - CategoryChipSurface

/// Superficie della chip: piena scura da attiva (design), vetro/materiale da
/// inattiva — nelle due varianti glass/legacy come ogni superficie della chrome.
private struct CategoryChipSurface: ViewModifier {
    let isSelected: Bool

    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey)
    private var isLiquidGlassEnabled = false
    @Environment(\.isLiquidGlassSuppressed) private var isLiquidGlassSuppressed
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLiquidGlassEnabled, !isLiquidGlassSuppressed, #available(iOS 26.0, *) {
            content.glassEffect(
                isSelected ? .regular.tint(FloorplanTokens.Surface.filterChipActive) : .regular,
                in: Capsule()
            )
        } else {
            content
                .background(
                    Capsule().fill(isSelected
                                   ? AnyShapeStyle(FloorplanTokens.Surface.filterChipActive)
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
