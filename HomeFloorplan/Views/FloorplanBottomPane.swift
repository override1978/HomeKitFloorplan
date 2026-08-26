import SwiftUI
import HomeKit

// MARK: - FloorplanBottomPane

/// Pannello a trascinamento in stile Dov'è (redesign iPhone): da chiuso
/// spunta dal bordo basso con pillola e testata, tirato su arriva al detent
/// esteso; l'isola dei tab gli flotta sopra.
///
/// È VOLUTAMENTE custom e non uno `.sheet` di sistema: lo sheet copre
/// l'isola quando si espande e possiede lui il gesto — da cui i rimbalzi e i
/// conflitti con l'app switcher del tentativo precedente (feedback 26/08).
/// Qui il drag vive SOLO sulla testata: la mappa resta interattiva e il
/// bordo dello schermo resta di iOS.
struct FloorplanBottomPane<Content: View>: View {

    /// Espanso ⇔ `overlayVM.isPanelVisible` su compact: stessa semantica del
    /// pannello docked, resa diversa.
    @Binding var isExpanded: Bool
    let container: CGSize
    /// Spazio occupato dall'isola dei tab che flotta sopra il pannello: la
    /// testata sta sopra di lei, il contenuto le scorre dietro.
    let islandClearance: CGFloat
    let background: Color
    let title: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    /// Traslazione live del drag. @State esplicito (non @GestureState): al
    /// rilascio l'azzeramento avviene DENTRO la stessa withAnimation dello
    /// snap, così non c'è il saltello dell'auto-reset a metà corsa che
    /// lasciava il pannello "un po' aperto".
    @State private var dragTranslation: CGFloat = 0

    private var peekHeight: CGFloat { islandClearance + 48 }
    private var expandedHeight: CGFloat {
        min(max(container.height * 0.52, 320), container.height - 120)
    }
    /// Offset del pannello da chiuso (il frame è FISSO a expandedHeight e si
    /// muove solo l'offset: niente re-layout del contenuto a ogni fotogramma,
    /// che era ciò che rendeva il drag legnoso).
    private var collapsedOffset: CGFloat { expandedHeight - peekHeight }
    private var baseOffset: CGFloat { isExpanded ? 0 : collapsedOffset }

    /// Offset vivo, con gomma oltre i limiti.
    private var liveOffset: CGFloat {
        let proposed = baseOffset + dragTranslation
        if proposed < 0 { return proposed * 0.2 }
        if proposed > collapsedOffset {
            return collapsedOffset + (proposed - collapsedOffset) * 0.2
        }
        return proposed
    }

    /// Il contenuto entra in dissolvenza man mano che il pannello sale.
    private var contentOpacity: CGFloat {
        guard collapsedOffset > 0 else { return 1 }
        return min(max(1 - liveOffset / (collapsedOffset * 0.6), 0), 1)
    }

    private var snapAnimation: Animation {
        .spring(response: 0.4, dampingFraction: 0.85)
    }

    var body: some View {
        VStack(spacing: 0) {
            grabHeader

            ScrollView {
                content()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            .contentMargins(.bottom, islandClearance + 12, for: .scrollContent)
            .opacity(contentOpacity)
            .allowsHitTesting(isExpanded)
        }
        .frame(height: expandedHeight, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22,
                                   bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: 22,
                                   style: .continuous)
                .fill(background)
                .shadow(color: .black.opacity(0.16), radius: 12, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
        .offset(y: liveOffset)
        // Da chiuso TUTTO il pannello visibile è maniglia: si trascina e si
        // tocca ovunque, come in Dov'è. Da esteso il drag resta sulla sola
        // testata, perché il contenuto deve poter scorrere.
        .gesture(isExpanded ? nil : paneDrag)
        .onTapGesture {
            if !isExpanded {
                withAnimation(snapAnimation) { isExpanded = true }
            }
        }
        .animation(nil, value: dragTranslation)
    }

    private var paneDrag: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragTranslation = value.translation.height
            }
            .onEnded { value in
                let predicted = baseOffset + value.predictedEndTranslation.height
                withAnimation(snapAnimation) {
                    isExpanded = predicted < collapsedOffset / 2
                    dragTranslation = 0
                }
            }
    }

    /// Pillola + titolo: possiede il drag anche da esteso. Il tap alterna.
    private var grabHeader: some View {
        VStack(spacing: 6) {
            Capsule()
                .fill(Color.primary.opacity(0.25))
                .frame(width: 36, height: 5)
                .padding(.top, 7)

            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(snapAnimation) { isExpanded.toggle() }
        }
        .gesture(paneDrag)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded
            ? String(localized: "floorplan.pane.expanded", defaultValue: "Expanded")
            : String(localized: "floorplan.pane.collapsed", defaultValue: "Collapsed"))
        .accessibilityAddTraits(.isButton)
    }
}

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

    var body: some View {
        if overlayVM.activeMode == .controls {
            controlsList
        } else {
            FloorplanContextDashboardRouter(
                overlayVM: overlayVM,
                floorplan: floorplan,
                environmentViewModel: environmentViewModel,
                adapterMap: adapterMap
            )
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
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(FloorplanTokens.Surface.card)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                )
                .accessibilityLabel(String(localized: "floorplan.pane.roomRow",
                                           defaultValue: "\(cluster.room.name), \(cluster.activeCount) of \(cluster.totalCount) on"))
            }
        }
    }
}
