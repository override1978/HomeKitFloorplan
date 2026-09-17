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
/// dalla planimetria, sul bordo più vicino alla stanza, con un'asta che la
/// raggiunge.
///
/// Fuori dal DISEGNO, non fuori dalla stanza. In una casa, fuori da una stanza
/// è dentro un'altra stanza: ancorarla lì sposterebbe la sovrapposizione
/// invece di toglierla. I marker vivono tutti dentro la planimetria, quindi
/// oltre il suo bordo non c'è niente che si possa coprire — è una garanzia
/// geometrica, non una probabilità.
///
/// Il bordo si sceglie, non è sempre l'alto: con l'alto fisso, una stanza in
/// fondo alla casa si prendeva un'asta che tagliava l'intero disegno. Fra alto,
/// sinistra e destra vince il più vicino fra quelli che hanno spazio per la
/// pastiglia.
///
/// Il basso è escluso: là sotto c'è il nastro della giornata.
struct ExpandedRoomCollapsePill: View {
    let room: LinkedRoom
    let imageRect: CGRect
    let containerSize: CGSize
    /// Fascia riservata in alto alla chrome flottante.
    let topInset: CGFloat
    let onCollapse: () -> Void

    /// Misura vera della pastiglia: il nome della stanza cambia da «Bagno» a
    /// «Soggiorno», e per stare FUORI dal disegno di lato bisogna sapere
    /// quanto è larga. Finché non è misurata resta invisibile per un
    /// fotogramma, che è meglio di vederla saltare da un bordo all'altro.
    @State private var pillSize: CGSize = .zero

    private let gap: CGFloat = 10

    private enum Edge { case top, left, right }

    var body: some View {
        ZStack {
            stem
            pill
        }
        .opacity(pillSize == .zero ? 0 : 1)
        .transition(.opacity)
    }

    private var pill: some View {
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pillSize = $0 }
        .position(pillCentre)
    }

    /// L'asta: un capello, non una linea. Dice «questa etichetta parla di
    /// quella stanza» senza competere con ciò che attraversa.
    @ViewBuilder
    private var stem: some View {
        let tint = FloorplanTokens.Surface.filterChipActive.opacity(0.55)
        switch edge {
        case .top:
            let from = pillCentre.y + pillSize.height / 2
            if roomRect.minY - from > 1 {
                Rectangle().fill(tint)
                    .frame(width: 1.5, height: roomRect.minY - from)
                    .position(x: pillCentre.x, y: (from + roomRect.minY) / 2)
                    .allowsHitTesting(false)
            }
        case .left:
            let from = pillCentre.x + pillSize.width / 2
            if roomRect.minX - from > 1 {
                Rectangle().fill(tint)
                    .frame(width: roomRect.minX - from, height: 1.5)
                    .position(x: (from + roomRect.minX) / 2, y: pillCentre.y)
                    .allowsHitTesting(false)
            }
        case .right:
            let to = pillCentre.x - pillSize.width / 2
            if to - roomRect.maxX > 1 {
                Rectangle().fill(tint)
                    .frame(width: to - roomRect.maxX, height: 1.5)
                    .position(x: (roomRect.maxX + to) / 2, y: pillCentre.y)
                    .allowsHitTesting(false)
            }
        }
    }

    private var roomRect: CGRect {
        FloorplanCoordinateHelper(imageRect: imageRect).screenRect(from: room.normalizedRect)
    }

    /// Il bordo più vicino alla stanza fra quelli che hanno spazio per la
    /// pastiglia. L'alto fa anche da ripiego: se non ci sta nemmeno lui, la
    /// pastiglia si ferma sotto la chrome invece di uscire dallo schermo.
    private var edge: Edge {
        var candidates: [(Edge, CGFloat)] = []
        if imageRect.minY - topInset >= pillSize.height + gap {
            candidates.append((.top, roomRect.minY - imageRect.minY))
        }
        if imageRect.minX >= pillSize.width + gap {
            candidates.append((.left, roomRect.minX - imageRect.minX))
        }
        if containerSize.width - imageRect.maxX >= pillSize.width + gap {
            candidates.append((.right, imageRect.maxX - roomRect.maxX))
        }
        return candidates.min { $0.1 < $1.1 }?.0 ?? .top
    }

    private var pillCentre: CGPoint {
        switch edge {
        case .top:
            return CGPoint(
                x: min(max(roomRect.midX, imageRect.minX + pillSize.width / 2),
                       imageRect.maxX - pillSize.width / 2),
                y: max(imageRect.minY - gap - pillSize.height / 2,
                       topInset + pillSize.height / 2 + 6))
        case .left:
            return CGPoint(x: imageRect.minX - gap - pillSize.width / 2,
                           y: clampedRoomMidY)
        case .right:
            return CGPoint(x: imageRect.maxX + gap + pillSize.width / 2,
                           y: clampedRoomMidY)
        }
    }

    /// Di lato la pastiglia segue la stanza in verticale, ma non oltre i bordi
    /// del disegno: per una stanza d'angolo finirebbe fuori dallo schermo.
    private var clampedRoomMidY: CGFloat {
        min(max(roomRect.midY, imageRect.minY + pillSize.height / 2),
            imageRect.maxY - pillSize.height / 2)
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
