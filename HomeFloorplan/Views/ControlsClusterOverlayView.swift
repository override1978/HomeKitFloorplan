import SwiftUI

// MARK: - ControlsClusterOverlayView

/// Layer del tab Controlli su larghezza regular (redesign, novità C).
///
/// Tre stati, mutuamente esclusivi, pilotati da `FloorplanOverlayViewModel`:
/// - default: nessun marker individuale, una card cluster per stanza;
/// - stanza espansa: fill leggermente scurito sulla stanza + pill di
///   compressione; i marker della stanza li disegna il layer marker;
/// - filtro categoria attivo: questo layer non disegna nulla (i marker
///   filtrati stanno nel layer marker).
///
/// Stesso impianto degli altri overlay: Canvas per i fill (fuori da ogni
/// container di vetro), card posizionate al centroide con contro-scala
/// applicata PRIMA di `.position` — e niente `GlassEffectContainer` attorno a
/// elementi posizionati, per la regressione documentata in EnvironmentOverlayView.
struct ControlsClusterOverlayView: View {

    let floorplan: Floorplan
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerSize: CGSize
    let imageRect: CGRect
    let effectiveScale: CGFloat
    let clusters: [FloorplanRoomCluster]
    /// iPhone (redesign fase 4): badge riassuntivi al posto delle card, e il
    /// tap fa zoom semantico sulla stanza invece di espanderla in place.
    var isCompact: Bool = false
    var onZoomRoom: ((FloorplanRoomCluster) -> Void)? = nil

    private var helper: FloorplanCoordinateHelper {
        FloorplanCoordinateHelper(imageRect: imageRect)
    }

    var body: some View {
        let inverseScale = 1.0 / effectiveScale

        ZStack(alignment: .topLeading) {
            if overlayVM.categoryFilter == nil, !overlayVM.areAllRoomsExpanded {
                if isCompact {
                    // Vista intera iPhone: un badge per stanza, finché non si
                    // è zoomati dentro una.
                    if overlayVM.zoomedRoomID == nil {
                        compactBadgesLayer(inverseScale: inverseScale)
                    }
                } else if let expandedID = overlayVM.expandedRoomID {
                    expandedRoomLayer(expandedID: expandedID, inverseScale: inverseScale)
                } else {
                    clusterCardsLayer(inverseScale: inverseScale)
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .animation(.easeInOut(duration: 0.35), value: overlayVM.expandedRoomID)
        .animation(.easeInOut(duration: 0.35), value: overlayVM.zoomedRoomID)
    }

    // MARK: iPhone — badge riassuntivi

    @ViewBuilder
    private func compactBadgesLayer(inverseScale: CGFloat) -> some View {
        ForEach(clusters) { cluster in
            Button {
                onZoomRoom?(cluster)
            } label: {
                HStack(spacing: 4) {
                    Text(cluster.room.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FloorplanTokens.Text.primary)
                    Text("· \(cluster.activeCount)/\(cluster.totalCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(cluster.activeCount > 0
                                         ? FloorplanTokens.Semantic.warning
                                         : FloorplanTokens.Text.secondary)
                }
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                // Vetro quando attivo, card piena altrimenti — mai dentro un
                // GlassEffectContainer: questi badge usano .position().
                .glassChromeSurface(
                    in: Capsule(),
                    legacyFill: AnyShapeStyle(FloorplanTokens.Surface.card),
                    legacyShadow: GlassChromeShadow(color: .black.opacity(0.10), radius: 5, y: 1)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "floorplan.cluster.compactBadge",
                                       defaultValue: "\(cluster.room.name), \(cluster.activeCount) of \(cluster.totalCount) on"))
            .scaleEffect(inverseScale)
            .position(helper.centroid(for: cluster.room))
            .transition(.opacity)
        }
    }

    // MARK: Stato default — card cluster

    @ViewBuilder
    private func clusterCardsLayer(inverseScale: CGFloat) -> some View {
        ForEach(clusters) { cluster in
            Button {
                overlayVM.expandRoom(cluster.id)
            } label: {
                ClusterCard(cluster: cluster)
            }
            .buttonStyle(.plain)
            .scaleEffect(inverseScale)
            .position(helper.centroid(for: cluster.room))
            .transition(.opacity)
        }
    }

    // MARK: Stato stanza espansa

    @ViewBuilder
    private func expandedRoomLayer(expandedID: UUID, inverseScale: CGFloat) -> some View {
        // Fill scurito della sola stanza espansa; le altre restano com'erano.
        if let room = floorplan.linkedRooms.first(where: { $0.hmRoomUUID == expandedID }) {
            Canvas { ctx, _ in
                let path = helper.overlayPath(for: room)
                ctx.fill(path, with: .color(FloorplanTokens.Surface.roomFillExpanded.opacity(0.55)))
                ctx.stroke(path,
                           with: .color(FloorplanTokens.Text.tertiary.opacity(0.35)),
                           lineWidth: 1.5 / effectiveScale)
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
        // La chip "NomeStanza ✕" non vive qui e nemmeno più sulla mappa:
        // sta in chrome, vedi `ExpandedRoomCollapsePill`. Qui resta il
        // riempimento scurito col contorno, che è ciò che dice QUALE stanza
        // è aperta — la chip si limita a nominarla e a offrire l'uscita.

        // Le altre stanze restano a cluster.
        ForEach(clusters.filter { $0.id != expandedID }) { cluster in
            Button {
                overlayVM.expandRoom(cluster.id)
            } label: {
                ClusterCard(cluster: cluster)
            }
            .buttonStyle(.plain)
            .scaleEffect(inverseScale)
            .position(helper.centroid(for: cluster.room))
            .transition(.opacity)
        }
    }

}

// MARK: - ExpandedRoomCollapsePill

/// Bandierina «NomeStanza ✕» della stanza espansa: la pastiglia sta FUORI
/// dalla planimetria, sopra il bordo alto del disegno, con un'asta che scende
/// fino alla stanza di cui parla.
///
/// Fuori dal disegno, non fuori dalla stanza: in una casa, fuori da una stanza
/// è dentro un'altra stanza: ancorarla lì avrebbe spostato la sovrapposizione
/// invece di toglierla. I marker invece vivono tutti dentro la planimetria,
/// quindi sopra il suo bordo non c'è niente che si possa coprire — ed è una
/// garanzia, non una probabilità.
///
/// Prima era ancorata al bordo alto della STANZA, e da lì nessuna posizione
/// poteva prometterlo.
///
/// Quando la planimetria è aderente alla chrome — poco margine, o zoom — la
/// bandierina si ferma sotto la fascia alta invece di infilarcisi. In quel
/// caso può tornare a sovrapporsi, ma alla chrome, che è una superficie
/// piatta e non qualcosa che devi leggere sotto.
struct ExpandedRoomCollapsePill: View {
    let room: LinkedRoom
    let imageRect: CGRect
    /// Fascia riservata in alto alla chrome flottante.
    let topInset: CGFloat
    let onCollapse: () -> Void

    /// Altezza della pastiglia: caption + 6 di padding per lato.
    private let pillHeight: CGFloat = 28

    var body: some View {
        ZStack {
            if stemHeight > 1 {
                // L'asta: un capello, non una linea. Deve dire «questa
                // etichetta parla di quella stanza» senza competere con
                // niente di ciò che attraversa.
                Rectangle()
                    .fill(FloorplanTokens.Surface.filterChipActive.opacity(0.55))
                    .frame(width: 1.5, height: stemHeight)
                    .position(x: anchorX, y: pillCentreY + pillHeight / 2 + stemHeight / 2)
                    .allowsHitTesting(false)
            }

            Button(action: onCollapse) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(FloorplanTokens.Surface.filterChipActiveText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // Opaca, non vetro: la stessa conclusione dei badge stanza di
                // Ambiente. Una superficie che porta un nome da leggere non ha
                // ragione di essere traslucida.
                .background(
                    Capsule()
                        .fill(FloorplanTokens.Surface.filterChipActive)
                        .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "floorplan.cluster.collapse",
                                       defaultValue: "Collapse \(room.name)"))
            .position(x: anchorX, y: pillCentreY)
        }
        .transition(.opacity)
    }

    private var roomRect: CGRect {
        FloorplanCoordinateHelper(imageRect: imageRect).screenRect(from: room.normalizedRect)
    }

    /// Colonna della bandierina: il centro della stanza, trattenuto perché la
    /// pastiglia non sporga dai lati del disegno.
    private var anchorX: CGFloat {
        min(max(roomRect.midX, imageRect.minX + 60), imageRect.maxX - 60)
    }

    /// Sopra il bordo alto della planimetria — e mai dentro la fascia chrome,
    /// che è il caso della planimetria aderente in alto.
    private var pillCentreY: CGFloat {
        max(imageRect.minY - 18, topInset + pillHeight / 2 + 6)
    }

    /// Dal fondo della pastiglia al bordo alto della stanza.
    private var stemHeight: CGFloat {
        roomRect.minY - (pillCentreY + pillHeight / 2)
    }
}

// MARK: - ClusterCard

/// Card riassuntiva di una stanza: nome + riga di conteggi per categoria
/// (pallino colore + numero). Superficie opaca dal registro token — su
/// planimetria scura passa da sola alla variante dark.
private struct ClusterCard: View {
    let cluster: FloorplanRoomCluster

    var body: some View {
        VStack(spacing: 5) {
            Text(cluster.room.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FloorplanTokens.Text.primary)
                .lineLimit(1)

            HStack(spacing: 7) {
                ForEach(cluster.counts) { count in
                    HStack(spacing: 3) {
                        Circle()
                            .fill(count.active > 0
                                  ? FloorplanTokens.Category.color(for: count.category)
                                  : FloorplanTokens.Category.off)
                            .frame(width: 8, height: 8)
                        Text("\(count.total)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FloorplanTokens.Text.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Vetro quando attivo, card piena altrimenti — mai dentro un
        // GlassEffectContainer: le card usano .position().
        .glassChromeSurface(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            legacyFill: AnyShapeStyle(FloorplanTokens.Surface.card),
            legacyShadow: GlassChromeShadow(color: .black.opacity(0.10), radius: 8, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "floorplan.cluster.card",
                                   defaultValue: "\(cluster.room.name), \(cluster.totalCount) devices, \(cluster.activeCount) on"))
    }
}
