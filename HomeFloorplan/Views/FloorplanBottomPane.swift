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
            FloorplanControlsPaneList(overlayVM: overlayVM,
                                      clusters: clusters,
                                      categoryCounts: categoryCounts)
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

}
