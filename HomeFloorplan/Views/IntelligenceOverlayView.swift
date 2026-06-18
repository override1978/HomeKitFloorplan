import SwiftUI

// MARK: - IntelligenceOverlayView

/// Overlay that highlights rooms that have pending AI habit suggestions.
/// Tapping a room opens the context panel showing the suggestions for that room.
struct IntelligenceOverlayView: View {

    let floorplan: Floorplan
    @Bindable var overlayVM: FloorplanOverlayViewModel
    let containerSize: CGSize
    /// Pre-computed from the parent — avoids reloading the image just to get its size.
    let imageRect: CGRect
    let effectiveScale: CGFloat
    let effectiveOffset: CGSize

    @Environment(HabitAnalysisService.self) private var habitService
    @AppStorage("ai.isEnabled") private var isAIEnabled: Bool = false

    private enum RoomIntelligenceState {
        case ready(count: Int, confidence: Double)
        case learning
        case needsSetup
        case disabled
    }

    // MARK: Derived

    private var helper: FloorplanCoordinateHelper {
        FloorplanCoordinateHelper(imageRect: imageRect)
    }

    var body: some View {
        let h = helper
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for room in floorplan.linkedRooms {
                    let path = h.overlayPath(for: room)
                    let state = intelligenceState(for: room)
                    ctx.fill(path, with: .color(fillColor(for: state)))
                    ctx.stroke(path, with: .color(borderColor(for: state).opacity(0.6)),
                               lineWidth: 1.5 / effectiveScale)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                let state = intelligenceState(for: room)
                let center = h.centroid(for: room)
                let inverseScale = 1.0 / effectiveScale

                Button {
                    overlayVM.selectRoom(room.hmRoomUUID)
                } label: {
                    intelligenceBadge(room: room, state: state)
                        .scaleEffect(inverseScale)
                }
                .buttonStyle(.plain)
                .position(center)
            }
        }
    }

    // MARK: Badge

    private func intelligenceBadge(room: LinkedRoom, state: RoomIntelligenceState) -> some View {
        HStack(spacing: 4) {
            Image(systemName: badgeIcon(for: state))
                .font(.caption.weight(.bold))
            Text(badgeText(room: room, state: state))
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(badgeBackground(for: state))
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor(for: state).opacity(0.7), lineWidth: 1)
                )
        )
        .foregroundStyle(isReady(state) ? .white : Color.secondary)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: Helpers

    private func intelligenceState(for room: LinkedRoom) -> RoomIntelligenceState {
        guard isAIEnabled else { return .disabled }

        let patterns = patterns(for: room)
        if !patterns.isEmpty {
            let confidence = patterns.map(\.confidence).max() ?? 0
            return .ready(count: patterns.count, confidence: confidence)
        }

        return hasPlacedMarker(in: room) ? .learning : .needsSetup
    }

    private func patterns(for room: LinkedRoom) -> [HabitPattern] {
        habitService.pendingPatterns.filter {
            FloorplanRoomMatcher.matches(roomName: $0.roomName, linkedRoom: room)
        }
    }

    private func hasPlacedMarker(in room: LinkedRoom) -> Bool {
        floorplan.accessories.contains { accessory in
            if accessory.linkedRoomUUID == room.hmRoomUUID {
                return true
            }
            return FloorplanRoomMatcher.contains(accessory.position, in: room)
        }
    }

    private func fillColor(for state: RoomIntelligenceState) -> Color {
        switch state {
        case .ready(_, let confidence):
            return Color(.systemIndigo).opacity(confidence >= 0.8 ? 0.34 : 0.26)
        case .learning: return Color(.systemIndigo).opacity(0.08)
        case .needsSetup: return Color.gray.opacity(0.05)
        case .disabled: return Color.gray.opacity(0.03)
        }
    }

    private func borderColor(for state: RoomIntelligenceState) -> Color {
        switch state {
        case .ready: return Color(.systemIndigo)
        case .learning: return Color(.systemIndigo).opacity(0.26)
        case .needsSetup: return Color.gray.opacity(0.22)
        case .disabled: return Color.gray.opacity(0.16)
        }
    }

    private func badgeBackground(for state: RoomIntelligenceState) -> Color {
        switch state {
        case .ready: return Color(.systemIndigo).opacity(0.92)
        case .learning: return Color(.systemBackground).opacity(0.82)
        case .needsSetup: return Color(.systemBackground).opacity(0.72)
        case .disabled: return Color(.systemBackground).opacity(0.64)
        }
    }

    private func badgeIcon(for state: RoomIntelligenceState) -> String {
        switch state {
        case .ready: return "sparkles"
        case .learning: return "brain.head.profile"
        case .needsSetup: return "plus.viewfinder"
        case .disabled: return "sparkles.slash"
        }
    }

    private func badgeText(room: LinkedRoom, state: RoomIntelligenceState) -> String {
        switch state {
        case .ready(let count, _): return "\(count)"
        case .learning: return room.name
        case .needsSetup: return "Completa"
        case .disabled: return room.name
        }
    }

    private func isReady(_ state: RoomIntelligenceState) -> Bool {
        if case .ready = state { return true }
        return false
    }
}

// MARK: - IntelligenceContextDashboard

/// Context Dashboard for the Intelligence overlay mode.
///
/// Always shows the home-level intelligence summary:
/// Analysis status → all pending recommendations sorted by confidence →
/// approve/dismiss actions per pattern → suggested top action.
///
/// When `highlightedRoomID` is set (user tapped a room on the floorplan),
/// that room's recommendation rows are visually highlighted — content never changes.
struct IntelligenceContextDashboard: View {

    @Environment(HabitAnalysisService.self) private var habitService
    @AppStorage("ai.isEnabled") private var isAIEnabled: Bool = false
    /// UUID of the room the user last tapped on the floorplan (highlight only).
    let highlightedRoomID: UUID?
    /// Linked rooms list — used to resolve the highlighted room name.
    let linkedRooms: [LinkedRoom]

    private var accent: Color { Color(.systemIndigo) }

    private var highlightedRoomName: String? {
        guard let id = highlightedRoomID else { return nil }
        return linkedRooms.first { $0.hmRoomUUID == id }?.name
    }

    private var sortedPatterns: [HabitPattern] {
        habitService.pendingPatterns.sorted { lhs, rhs in
            let lhsHighlighted = FloorplanRoomMatcher.matches(
                roomName: lhs.roomName,
                highlightedRoomName: highlightedRoomName
            )
            let rhsHighlighted = FloorplanRoomMatcher.matches(
                roomName: rhs.roomName,
                highlightedRoomName: highlightedRoomName
            )

            if lhsHighlighted != rhsHighlighted {
                return lhsHighlighted
            }

            return lhs.confidence > rhs.confidence
        }
    }

    private var topAction: HabitPattern? { sortedPatterns.first }

    private var highlightedRoomPatterns: [HabitPattern] {
        guard let highlightedRoomName else { return [] }
        return habitService.pendingPatterns
            .filter {
                FloorplanRoomMatcher.matches(
                    roomName: $0.roomName,
                    highlightedRoomName: highlightedRoomName
                )
            }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            nextUsefulCard

            // ── Recommendations ───────────────────────────────────────────
            if !sortedPatterns.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Raccomandazioni")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(sortedPatterns) { pattern in
                        let highlighted = FloorplanRoomMatcher.matches(
                            roomName: pattern.roomName,
                            highlightedRoomName: highlightedRoomName
                        )
                        recommendationRow(pattern, highlighted: highlighted)
                        if pattern.id != sortedPatterns.last?.id {
                            Divider().padding(.leading, 26)
                        }
                    }
                }
            }
        }
    }

    // MARK: Next useful card

    @ViewBuilder
    private var nextUsefulCard: some View {
        if habitService.isAnalyzing {
            FloorplanEmptyStateCard(
                title: "Analisi in corso",
                message: "Sto aggiornando pattern e opportunità. Le raccomandazioni compariranno qui quando saranno affidabili.",
                icon: "sparkles",
                color: accent
            )
        } else if !isAIEnabled {
            FloorplanEmptyStateCard(
                title: "Intelligenza disattivata",
                message: "Abilita l'AI nelle impostazioni per analizzare abitudini e opportunità di automazione.",
                icon: "sparkles.slash",
                color: .secondary
            )
        } else if let pattern = highlightedRoomPatterns.first, let roomName = highlightedRoomName {
            nextActionCard(
                title: "Prossima azione in \(roomName)",
                pattern: pattern,
                metrics: [
                    FloorplanStatusMetric(value: pattern.confidenceLabel, label: "Confidenza"),
                    FloorplanStatusMetric(value: "\(highlightedRoomPatterns.count)", label: "Pronte")
                ]
            )
        } else if let pattern = topAction {
            nextActionCard(
                title: "Prossima automazione da valutare",
                pattern: pattern,
                metrics: [
                    FloorplanStatusMetric(value: pattern.confidenceLabel, label: "Confidenza"),
                    FloorplanStatusMetric(value: "\(sortedPatterns.count)", label: "Totali")
                ]
            )
        } else if let roomName = highlightedRoomName {
            FloorplanEmptyStateCard(
                title: "Sto imparando \(roomName)",
                message: "Non ci sono azioni affidabili per questa stanza. Continua a usarla normalmente: quando emerge una routine utile la vedrai qui.",
                icon: "brain.head.profile",
                color: accent
            )
        } else {
            FloorplanEmptyStateCard(
                title: "Sto imparando le routine",
                message: "Non ci sono raccomandazioni pronte. Apri una stanza sulla mappa per vedere lo stato di apprendimento locale.",
                icon: "brain.head.profile",
                color: accent
            )
        }
    }

    private func nextActionCard(
        title: String,
        pattern: HabitPattern,
        metrics: [FloorplanStatusMetric]
    ) -> some View {
        FloorplanStatusSummaryCard(
            title: title,
            message: pattern.description,
            icon: pattern.sfSymbol,
            color: accent,
            metrics: metrics
        )
    }

    // MARK: Recommendation row

    private func recommendationRow(_ pattern: HabitPattern, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: pattern.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(highlighted ? .white : accent)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pattern.displayTitle)
                        .font(.caption.weight(.semibold))
                    Text(pattern.description)
                        .font(.caption)
                        .foregroundStyle(highlighted ? .white.opacity(0.85) : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !pattern.roomName.isEmpty {
                        Text(pattern.roomName)
                            .font(.caption2)
                            .foregroundStyle(highlighted ? .white.opacity(0.7) : accent.opacity(0.7))
                    }
                }
                Spacer(minLength: 4)
                Text(pattern.confidenceLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(highlighted ? .white : accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(highlighted ? Color.white.opacity(0.25) : accent.opacity(0.12)))
            }

            // Approve / dismiss
            HStack(spacing: 8) {
                Button {
                    habitService.approve(pattern)
                } label: {
                    Label("Approva", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(highlighted ? Color.white.opacity(0.2) : accent.opacity(0.15)))
                        .foregroundStyle(highlighted ? .white : accent)
                }
                .buttonStyle(.plain)

                Button {
                    habitService.dismiss(pattern)
                } label: {
                    Label("Ignora", systemImage: "xmark")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(highlighted ? Color.white.opacity(0.1) : Color(.systemGray5)))
                        .foregroundStyle(highlighted ? .white.opacity(0.8) : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 26)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, highlighted ? 8 : 2)
        .background(
            highlighted ? accent.opacity(0.85) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .animation(.easeInOut(duration: 0.2), value: highlighted)
    }
}
