import SwiftUI

// MARK: - FloorplanControlsPaneList

/// Le pillole dei filtri e la lista delle stanze: il pannello Controlli di
/// iPhone.
///
/// Solo iPhone. Su iPad il pannello destro porta le sole pillole, in colonna
/// (`FloorplanCategoryFilterPanel`), e la lista stanze non c'è: là la
/// planimetria È l'indice delle stanze, e ripeterla in colonna direbbe due
/// volte la stessa cosa nella stessa schermata. Su iPhone invece la mappa è
/// piccola e il pannello fa da indice, che è il mestiere per cui la lista è
/// nata.
///
/// Vive in un tipo suo, e non più dentro il pannello compatto, da quando su
/// iPad il tab Controlli ha smesso di mostrare `EmptyView()`: la prima
/// versione di quel riempimento riusava questa lista, e anche se poi l'iPad
/// ha preso una strada diversa, averla estratta ha lasciato il pannello di
/// iPhone più leggibile di com'era.
struct FloorplanControlsPaneList: View {

    @Bindable var overlayVM: FloorplanOverlayViewModel
    var clusters: [FloorplanRoomCluster] = []
    var categoryCounts: [FloorplanRoomCluster.CategoryCount] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if categoryCounts.count > 1 {
                FloorplanCategoryFilterBar(overlayVM: overlayVM,
                                           counts: categoryCounts,
                                           showsExpandToggle: false)
            }

            ForEach(clusters) { cluster in
                Button {
                    // Zoom semantico: il pannello si fa da parte da solo
                    // (lo stato zoomato nasconde pannello e isola).
                    overlayVM.zoomedRoomID = cluster.room.hmRoomUUID
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(cluster.activeCount > 0
                                  ? FloorplanTokens.Semantic.warning
                                  : FloorplanTokens.Text.tertiary)
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(cluster.room.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text(String(localized: "floorplan.pane.roomStatus",
                                        defaultValue: "\(cluster.activeCount) on of \(cluster.totalCount)"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                // Vetro quando attivo, card piena altrimenti.
                .glassChromeSurface(
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                    legacyFill: AnyShapeStyle(FloorplanTokens.Surface.card),
                    legacyShadow: GlassChromeShadow(color: .black.opacity(0.08), radius: 6, y: 2)
                )
                .accessibilityLabel(String(localized: "floorplan.pane.roomRow",
                                           defaultValue: "\(cluster.room.name), \(cluster.activeCount) of \(cluster.totalCount) on"))
            }
        }
    }
}
