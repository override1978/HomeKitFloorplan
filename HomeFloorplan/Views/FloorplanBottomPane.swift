import SwiftUI
import HomeKit

// Il pannello custom FloorplanBottomPane non esiste più: la resa "Dov'è" su
// iPhone è tornata a uno sheet di sistema sempre presente (detent selezionabili,
// isola dei tab DENTRO lo sheet) — la fisica nativa batte qualunque molla fatta
// a mano. Qui resta il contenuto, che lo sheet monta.

// MARK: - FloorplanCompactPaneContent

/// Contenuto del pannello Dov'è per modalità: in Controlli la lista stanze
/// coi filtri (il tap sulla riga fa zoom semantico), negli altri tab le
/// stesse dashboard del pannello docked.
struct FloorplanCompactPaneContent: View {
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let floorplan: Floorplan
    let environmentViewModel: EnvironmentViewModel
    var adapterMap: [UUID: any AccessoryAdapter] = [:]
    var clusters: [FloorplanRoomCluster] = []
    var categoryCounts: [FloorplanRoomCluster.CategoryCount] = []
    /// Filtri sensore per il tab Ambiente (su iPhone vivono qui, non in una
    /// riga fissa in alto — regola mobile 5).
    var environmentSensorTypes: [SensorServiceType] = []

    var body: some View {
        // Il dettaglio dispositivo vince anche qui: su iPhone il tap su un
        // marker non-toggleabile espande lo sheet sul dettaglio, non sulla
        // lista stanze (matrice gesti 28/08).
        if case .device = overlayVM.panelContent {
            FloorplanContextDashboardRouter(
                overlayVM: overlayVM,
                floorplan: floorplan,
                environmentViewModel: environmentViewModel,
                adapterMap: adapterMap
            )
        } else if overlayVM.activeMode == .controls {
            controlsList
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if overlayVM.activeMode == .environment, !environmentSensorTypes.isEmpty {
                    EnvironmentFilterBar(
                        overlayVM: overlayVM,
                        availableTypes: environmentSensorTypes
                    )
                }
                FloorplanContextDashboardRouter(
                    overlayVM: overlayVM,
                    floorplan: floorplan,
                    environmentViewModel: environmentViewModel,
                    adapterMap: adapterMap
                )
            }
        }
    }

    private var controlsList: some View {
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
