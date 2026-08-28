import SwiftUI
import HomeKit

// MARK: - Header

/// Chrome del flusso di posizionamento guidato (fase 6): titolo, barra di
/// progresso, uscita e — sotto — il banner-istruzione che rende esplicita la
/// modalità e dice sempre qual è il prossimo gesto (feedback 28/08: non era
/// chiaro né che si dovesse toccare una stanza, né di essere in un flusso).
/// Prende il posto della top bar finché il flusso è aperto.
struct FloorplanPlacementHeader: View {
    let phase: FloorplanPlacementOnboardingModel.Phase
    let placingRoomName: String?
    let placedCount: Int
    let totalCount: Int
    let onExit: () -> Void

    private var accent: Color { FloorplanTokens.Mode.accent(.controls) }

    var body: some View {
        VStack(spacing: 8) {
            // Titolo+progresso centrati; il ✕ sta a destra senza spostarli.
            HStack {
                Spacer(minLength: 44)

                VStack(spacing: 5) {
                    Text(headerTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        // Barra di progresso: fotografia della coda all'avvio
                        // come denominatore, i posizionamenti di sessione sopra.
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.12))
                                Capsule()
                                    .fill(accent)
                                    .frame(width: proxy.size.width * progressFraction)
                            }
                        }
                        .frame(width: 120, height: 5)

                        Text("\(placedCount)/\(totalCount)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassChromeSurface(in: Capsule())

                Spacer(minLength: 12)

                // Chiusura, non "salta tutto": il flusso si riprende quando
                // si vuole dal menu, uscire non butta via niente.
                Button(action: onExit) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassChromeSurface(in: Circle())
                .accessibilityLabel(String(localized: "common.close", defaultValue: "Close"))
            }

            // Banner-istruzione, tinto d'accento come il banner della
            // modifica: è LUI a dire che si è in una modalità a parte.
            HStack(spacing: 10) {
                Image(systemName: instructionIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent)

                Text(instructionText)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: 560)
            .glassChromeSurface(
                in: Capsule(),
                tint: accent.opacity(0.18),
                legacyBorder: accent.opacity(0.18)
            )

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var headerTitle: String {
        if let placingRoomName {
            return placingRoomName
        }
        return String(localized: "placement.title", defaultValue: "Place your devices")
    }

    private var instructionIcon: String {
        if case .placing = phase { return "hand.draw" }
        return "hand.tap"
    }

    private var instructionText: String {
        if case .placing = phase {
            return String(localized: "placement.instruction.placing",
                          defaultValue: "Drag the marker where the device is, then confirm. Tap the map to go back to the rooms.")
        }
        return String(localized: "placement.instruction.pickRoom",
                      defaultValue: "Tap a room badge to place its devices. Tap a placed marker to adjust or move it.")
    }

    private var progressFraction: CGFloat {
        guard totalCount > 0 else { return 0 }
        return CGFloat(placedCount) / CGFloat(totalCount)
    }
}

// MARK: - Rooms layer (fase 1 — scelta stanza)

/// Layer in spazio-mappa: colora le stanze secondo lo stato della coda e,
/// nella fase di scelta, mostra il badge "Nome · N" / "✓" al centro di ognuna.
struct FloorplanPlacementRoomsLayer: View {
    let rooms: [LinkedRoom]
    let queues: [UUID: FloorplanPlacementRoomQueue]
    let phase: FloorplanPlacementOnboardingModel.Phase
    let containerSize: CGSize
    let imageRect: CGRect
    let effectiveScale: CGFloat
    let onPickRoom: (UUID) -> Void

    private var accent: Color { FloorplanTokens.Mode.accent(.controls) }

    private var placingRoomID: UUID? {
        if case .placing(let roomID) = phase { return roomID }
        return nil
    }

    var body: some View {
        let h = FloorplanCoordinateHelper(imageRect: imageRect)
        let inverseScale = 1.0 / effectiveScale

        ZStack(alignment: .topLeading) {
            // Fill stanze: verde leggerissimo per le complete, accento sulla
            // stanza in cui si sta posizionando, neutre le altre.
            Canvas { ctx, _ in
                for room in rooms {
                    let path = h.overlayPath(for: room)
                    let queue = queues[room.hmRoomUUID]
                    if room.hmRoomUUID == placingRoomID {
                        ctx.fill(path, with: .color(accent.opacity(0.10)))
                        ctx.stroke(path, with: .color(accent),
                                   lineWidth: 2 / effectiveScale)
                    } else if queue?.isComplete == true {
                        ctx.fill(path, with: .color(FloorplanTokens.Semantic.ok.opacity(0.07)))
                        ctx.stroke(path, with: .color(FloorplanTokens.Semantic.ok.opacity(0.35)),
                                   lineWidth: 1 / effectiveScale)
                    } else {
                        ctx.stroke(path, with: .color(Color.primary.opacity(0.10)),
                                   lineWidth: 1 / effectiveScale)
                    }
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            // Badge di scelta: solo in fase 1 — durante il posizionamento la
            // stanza attiva parla da sé e le altre restano mute (da design).
            if placingRoomID == nil {
                ForEach(rooms, id: \.hmRoomUUID) { room in
                    let queue = queues[room.hmRoomUUID]
                    let center = h.centroid(for: room)
                    let roomScreenWidth = h.screenRect(from: room.normalizedRect).width * effectiveScale

                    Button {
                        guard let queue, !queue.isComplete else { return }
                        onPickRoom(room.hmRoomUUID)
                    } label: {
                        roomBadge(room: room,
                                  remaining: queue?.remainingCount ?? 0,
                                  roomScreenWidth: roomScreenWidth)
                            .scaleEffect(inverseScale)
                    }
                    .buttonStyle(.plain)
                    .position(center)
                }
            }
        }
    }

    @ViewBuilder
    private func roomBadge(room: LinkedRoom,
                           remaining: Int,
                           roomScreenWidth: CGFloat) -> some View {
        let isComplete = remaining == 0
        let level = FloorplanRoomBadgeCollapse.level(
            roomScreenWidth: roomScreenWidth,
            fullText: room.name + " " + String(remaining),
            valueText: String(remaining)
        )

        if level == .dot {
            RoomBadgeDot(color: isComplete ? FloorplanTokens.Semantic.ok : accent)
        } else if isComplete {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(FloorplanTokens.Semantic.ok))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        } else {
            HStack(spacing: 4) {
                if level == .full {
                    Text(room.name)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                Text("\(remaining)")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(FloorplanTokens.Surface.card))
            .overlay(Capsule().strokeBorder(accent.opacity(0.45), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
    }
}

// MARK: - Ghost layer (fase 2 — posizionamento)

/// Marker fantasma trascinabile + etichetta con Conferma/Salta. Vive SOPRA i
/// marker (overMarkerLayer), così resta raggiungibile anche dove i
/// dispositivi già posati si addensano.
struct FloorplanPlacementGhostLayer: View {
    let accessory: HMAccessory
    let iconName: String
    let queuePosition: (current: Int, total: Int)
    let ghostPosition: NormalizedPoint
    let imageRect: CGRect
    let effectiveScale: CGFloat
    let onMove: (NormalizedPoint) -> Void
    let onConfirm: () -> Void
    let onSkip: () -> Void

    @State private var dragDelta: CGSize = .zero
    @State private var isBreathing = false

    private var accent: Color { FloorplanTokens.Mode.accent(.controls) }

    var body: some View {
        let inverseScale = 1.0 / effectiveScale
        let basePoint = CGPoint(
            x: imageRect.origin.x + ghostPosition.x * imageRect.width,
            y: imageRect.origin.y + ghostPosition.y * imageRect.height
        )
        let livePoint = CGPoint(x: basePoint.x + dragDelta.width,
                                y: basePoint.y + dragDelta.height)
        // Nel terzo inferiore della mappa etichetta e bottoni si ribaltano
        // sopra il marker (da design); l'ancoraggio orizzontale resta dentro.
        let flipsAbove = (livePoint.y - imageRect.minY) / imageRect.height > 0.66
        let calloutHalfWidth = 130.0 * inverseScale
        let calloutX = min(max(livePoint.x, imageRect.minX + calloutHalfWidth),
                           imageRect.maxX - calloutHalfWidth)

        ZStack {
            // Fantasma: cerchio tratteggiato che respira, col glifo categoria.
            ZStack {
                Circle()
                    .fill(FloorplanTokens.Surface.card.opacity(0.9))
                Circle()
                    .strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                AccessoryIconView(iconName: iconName)
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
            }
            .frame(width: 44, height: 44)
            .scaleEffect(isBreathing ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: isBreathing)
            .scaleEffect(inverseScale)
            .position(livePoint)
            .gesture(dragGesture)
            .onAppear { isBreathing = true }

            // Etichetta + azioni, agganciate al fantasma ma mai fuori mappa.
            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    Text(AccessoryPickerSheet.strippedName(accessory.name,
                                                           roomName: accessory.room?.name))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(String(format: String(localized: "placement.queue.position",
                                               defaultValue: "%d of %d · drag to adjust"),
                                queuePosition.current, queuePosition.total))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button(action: onConfirm) {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                            Text(String(localized: "placement.confirm", defaultValue: "Confirm"))
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(accent))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onSkip) {
                        Text(String(localized: "placement.skip", defaultValue: "Skip"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 250)
            .glassChromeSurface(
                in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                legacyFill: AnyShapeStyle(FloorplanTokens.Surface.card),
                legacyShadow: GlassChromeShadow(color: .black.opacity(0.12), radius: 8, y: 3)
            )
            .scaleEffect(inverseScale)
            .position(x: calloutX,
                      y: livePoint.y + (flipsAbove ? -72 : 72) * inverseScale)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragDelta = CGSize(width: value.translation.width / effectiveScale,
                                   height: value.translation.height / effectiveScale)
            }
            .onEnded { value in
                let tx = value.translation.width / effectiveScale
                let ty = value.translation.height / effectiveScale
                let newX = ghostPosition.x * imageRect.width + tx
                let newY = ghostPosition.y * imageRect.height + ty
                onMove(NormalizedPoint(
                    x: max(0, min(1, newX / imageRect.width)),
                    y: max(0, min(1, newY / imageRect.height))
                ))
                dragDelta = .zero
            }
    }
}

// MARK: - Completion card

/// Card di riepilogo a code esaurite: tutte le stanze complete.
struct FloorplanPlacementCompletionCard: View {
    let placedCount: Int
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(FloorplanTokens.Semantic.ok)

            Text(String(localized: "placement.done.title", defaultValue: "Placement complete"))
                .font(.headline)

            Text(placedCount == 1
                 ? String(localized: "placement.done.one", defaultValue: "1 device placed on the floorplan")
                 : String(format: String(localized: "placement.done.count",
                                         defaultValue: "%d devices placed on the floorplan"),
                          placedCount))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onFinish) {
                Text(String(localized: "placement.done.cta", defaultValue: "Go to Controls"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(FloorplanTokens.Mode.accent(.controls)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: 340)
        .glassChromeSurface(
            in: RoundedRectangle(cornerRadius: 22, style: .continuous),
            legacyFill: AnyShapeStyle(FloorplanTokens.Surface.card),
            legacyShadow: GlassChromeShadow(color: .black.opacity(0.14), radius: 16, y: 6)
        )
    }
}
