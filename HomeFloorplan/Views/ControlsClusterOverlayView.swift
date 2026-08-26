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

    private var helper: FloorplanCoordinateHelper {
        FloorplanCoordinateHelper(imageRect: imageRect)
    }

    var body: some View {
        let inverseScale = 1.0 / effectiveScale

        ZStack(alignment: .topLeading) {
            if overlayVM.categoryFilter == nil {
                if let expandedID = overlayVM.expandedRoomID {
                    expandedRoomLayer(expandedID: expandedID, inverseScale: inverseScale)
                } else {
                    clusterCardsLayer(inverseScale: inverseScale)
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .animation(.easeInOut(duration: 0.35), value: overlayVM.expandedRoomID)
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

            // Pill "NomeStanza ✕" in alto alla stanza per comprimere.
            Button(action: overlayVM.collapseRoom) {
                HStack(spacing: 6) {
                    Text(room.name)
                        .font(.caption.weight(.semibold))
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(FloorplanTokens.Surface.filterChipActiveText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(FloorplanTokens.Surface.filterChipActive, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "floorplan.cluster.collapse",
                                       defaultValue: "Collapse \(room.name)"))
            .scaleEffect(inverseScale)
            .position(collapsePillPosition(for: room))
            .transition(.opacity)
        }

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

    /// Ancora della pill di compressione: centro-alto del rettangolo stanza,
    /// rientrato quel tanto da non cadere sul bordo.
    private func collapsePillPosition(for room: LinkedRoom) -> CGPoint {
        let rect = helper.screenRect(from: room.normalizedRect)
        return CGPoint(x: rect.midX, y: rect.minY + 18)
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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FloorplanTokens.Surface.card)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "floorplan.cluster.card",
                                   defaultValue: "\(cluster.room.name), \(cluster.totalCount) devices, \(cluster.activeCount) on"))
    }
}
