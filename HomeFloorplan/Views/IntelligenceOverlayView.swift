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
                    let count = pendingCount(for: room)
                    ctx.fill(path, with: .color(fillColor(count: count)))
                    ctx.stroke(path, with: .color(borderColor(count: count).opacity(0.6)),
                               lineWidth: 1.5 / effectiveScale)
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                let count = pendingCount(for: room)
                let center = h.centroid(for: room)
                let inverseScale = 1.0 / effectiveScale

                Button {
                    overlayVM.selectRoom(room.hmRoomUUID)
                } label: {
                    intelligenceBadge(room: room, count: count)
                        .scaleEffect(inverseScale)
                }
                .buttonStyle(.plain)
                .position(center)
            }
        }
    }

    // MARK: Badge

    private func intelligenceBadge(room: LinkedRoom, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: count > 0 ? "sparkles" : "sparkle")
                .font(.caption.weight(.bold))
            Text(count > 0 ? "\(count)" : room.name)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(fillColor(count: count).opacity(0.9))
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor(count: count).opacity(0.7), lineWidth: 1)
                )
        )
        .foregroundStyle(count > 0 ? .white : Color.secondary)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    // MARK: Helpers

    private func pendingCount(for room: LinkedRoom) -> Int {
        habitService.pendingPatterns.filter { $0.roomName == room.name }.count
    }

    private func fillColor(count: Int) -> Color {
        count > 0
            ? Color(.systemIndigo).opacity(0.28)
            : Color(.systemIndigo).opacity(0.06)
    }

    private func borderColor(count: Int) -> Color {
        count > 0 ? Color(.systemIndigo) : Color(.systemIndigo).opacity(0.2)
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
    /// UUID of the room the user last tapped on the floorplan (highlight only).
    let highlightedRoomID: UUID?
    /// Linked rooms list — used to resolve the highlighted room name.
    let linkedRooms: [LinkedRoom]

    private var accent: Color { Color(.systemIndigo) }

    private var highlightedRoomName: String? {
        guard let id = highlightedRoomID else { return nil }
        return linkedRooms.first { $0.hmRoomUUID == id }?.name
    }

    // Patterns sorted by confidence descending
    private var sortedPatterns: [HabitPattern] {
        habitService.pendingPatterns.sorted { $0.confidence > $1.confidence }
    }

    private var topAction: HabitPattern? { sortedPatterns.first }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Header / status ───────────────────────────────────────────
            if habitService.isAnalyzing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Analisi in corso…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                // Mini score row
                intelligenceScoreRow
            }

            // ── Recommendations ───────────────────────────────────────────
            if !sortedPatterns.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Raccomandazioni")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(sortedPatterns) { pattern in
                        let highlighted = pattern.roomName == highlightedRoomName
                        recommendationRow(pattern, highlighted: highlighted)
                        if pattern.id != sortedPatterns.last?.id {
                            Divider().padding(.leading, 26)
                        }
                    }
                }
            } else if !habitService.isAnalyzing {
                Label("Nessuna raccomandazione disponibile", systemImage: "sparkle")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            }

            // ── Suggested top action ──────────────────────────────────────
            if let action = topAction {
                Divider()
                actionChip(action.description, icon: action.sfSymbol, color: accent)
            }
        }
    }

    // MARK: Score row

    private var intelligenceScoreRow: some View {
        let count = sortedPatterns.count
        let color: Color = count == 0 ? .green : count <= 2 ? accent : .orange
        let label: String = count == 0 ? "Tutto ottimizzato" :
                            count <= 2 ? "\(count) suggerimento\(count == 1 ? "" : "i")" :
                                         "\(count) suggerimenti"
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(1.0, CGFloat(count) / 5.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: count == 0 ? "checkmark" : "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Intelligenza Casa")
                    .font(.caption).foregroundStyle(.secondary)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
            }
        }
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

    // MARK: Action chip

    private func actionChip(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
