import SwiftUI

// MARK: - FloorplanCategoryFilterPanel

/// Il filtro per tipo di accessorio, come colonna di pillole nel pannello
/// destro invece che come tendina in barra.
///
/// Una tendina costa due tap per scegliere e non mostra niente finché non la
/// apri; qui le categorie stanno tutte in vista coi loro conteggi, e sceglierne
/// una è un tap solo. Il prezzo è lo spazio, ed è per questo che il pannello
/// si apre a richiesta dall'icona in barra e non sta lì di suo.
///
/// Verticale e non la riga di chip che usa iPhone: quella nasce per una barra
/// larga e stretta, e infilata in una colonna da 340 punti andrebbe a capo o
/// scorrerebbe di lato — in una colonna una lista si legge meglio di una riga
/// piegata, e i conteggi si incolonnano a destra invece di galleggiare in
/// mezzo al testo.
struct FloorplanCategoryFilterPanel: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    let counts: [FloorplanRoomCluster.CategoryCount]

    private var total: Int { counts.reduce(0) { $0 + $1.total } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "floorplan.filter.panel.title",
                        defaultValue: "FILTER BY TYPE"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)

            row(label: String(localized: "floorplan.filter.all.plain", defaultValue: "All"),
                dot: nil,
                count: total,
                isSelected: overlayVM.categoryFilter == nil) {
                set(nil)
            }

            ForEach(counts) { count in
                row(label: count.category.displayName,
                    dot: FloorplanTokens.Category.color(for: count.category),
                    count: count.total,
                    isSelected: overlayVM.categoryFilter == count.category) {
                    // Ritoccare la categoria attiva torna a «Tutti»: la stessa
                    // regola della riga di chip su iPhone.
                    set(overlayVM.categoryFilter == count.category ? nil : count.category)
                }
            }
        }
    }

    private func set(_ category: AccessoryCategory?) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            overlayVM.categoryFilter = category
        }
    }

    private func row(label: String,
                     dot: Color?,
                     count: Int,
                     isSelected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // «Tutti» non ha un colore suo: al suo posto un cerchio vuoto,
                // che tiene la colonna allineata senza inventare una categoria
                // che non esiste.
                Group {
                    if let dot {
                        Circle().fill(dot)
                    } else {
                        Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                    }
                }
                .frame(width: 9, height: 9)

                Text(label)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .opacity(isSelected ? 1 : 0.6)
            }
            .foregroundStyle(isSelected
                             ? FloorplanTokens.Surface.filterChipActiveText
                             : Color.primary.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            Capsule().fill(isSelected
                           ? AnyShapeStyle(FloorplanTokens.Surface.filterChipActive)
                           : AnyShapeStyle(Color.primary.opacity(0.06)))
        )
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
