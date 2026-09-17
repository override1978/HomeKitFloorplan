import SwiftUI

// MARK: - FloorplanControlsPaneList

/// Le pillole dei filtri e la lista delle stanze del tab Controlli.
///
/// Stava dentro il pannello di iPhone, ed era l'unico posto in cui esisteva:
/// su iPad il pannello destro in Controlli mostrava `EmptyView()`, cioè si
/// apriva vuoto a meno di non aver toccato qualcosa sul nastro. Due
/// piattaforme con lo stesso tab, una con dentro qualcosa e una no.
///
/// Le pillole vivono qui e non SOLO qui: la chip in barra resta, perché è la
/// via sempre disponibile e dice quale filtro è attivo anche a pannello
/// chiuso. Non è la stessa ridondanza di «Posiziona» e «Modifica», che erano
/// due porte per una stanza con nomi e pesi diversi — qui è un unico stato
/// con un comando permanente e uno a portata di mano mentre lavori
/// nell'elenco, come un volume che sta sia sulla tastiera sia nel menu.
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
