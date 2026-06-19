import SwiftUI
import Observation

// MARK: - FloorplanOverlayViewModel

/// Scoped view model for the floorplan overlay system.
/// Created as `@State` in `FloorplanEditorView` — not injected globally.
/// Mode selection is persisted per-floorplan in UserDefaults.
@Observable
final class FloorplanOverlayViewModel {

    // MARK: Published state

    var activeMode: FloorplanOverlayMode = .controls {
        didSet {
            persistMode()
            // When switching back to controls, close the panel.
            // When switching TO an overlay mode, keep the panel closed —
            // it opens only when the user explicitly taps a room on the floorplan.
            if activeMode == .controls {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                    isPanelVisible = false
                }
            }
            // Clear transient state whenever the mode changes.
            highlightedRoomID = nil
            selectedSensorFilter = nil
        }
    }

    /// Whether the right-side context dashboard panel is currently shown.
    var isPanelVisible: Bool = false

    /// The room UUID the user last tapped on the floorplan.
    /// Used ONLY to highlight the corresponding row inside the dashboard —
    /// never to switch or replace dashboard content.
    var highlightedRoomID: UUID?

    /// Accessory UUID being highlighted (e.g. from intelligence overlay).
    var highlightedAccessoryID: UUID?

    /// Active sensor type sub-filter for the Environment overlay.
    /// `nil` = aggregate worst urgency across all sensor types.
    /// Non-nil = show only this sensor type in heatmap, badges, and panel cards.
    var selectedSensorFilter: SensorServiceType? = nil

    // MARK: Private

    private let floorplanID: UUID

    private var modeKey: String {
        "overlay_mode_\(floorplanID.uuidString)"
    }

    // MARK: Init

    init(floorplanID: UUID) {
        self.floorplanID = floorplanID
        resetToControls()
        // Panel always starts closed — it opens on explicit room tap.
        isPanelVisible = false
    }

    // MARK: Helpers

    /// Returns the subset of modes that are available given the current context,
    /// always including `.controls` as the baseline.
    func availableModes(context: FloorplanOverlayContext) -> [FloorplanOverlayMode] {
        FloorplanOverlayMode.allCases.filter { $0.isAvailable(in: context) }
    }

    /// Cycles to the next available mode, wrapping around.
    func cycleMode(context: FloorplanOverlayContext) {
        let modes = availableModes(context: context)
        guard modes.count > 1,
              let current = modes.firstIndex(of: activeMode) else { return }
        let next = (current + 1) % modes.count
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            activeMode = modes[next]
        }
    }

    /// Marks a room as highlighted in the context dashboard.
    /// If the panel is not already open (shouldn't happen in non-controls mode),
    /// opens it without changing content.
    func selectRoom(_ id: UUID) {
        highlightedRoomID = id
        if !isPanelVisible && activeMode != .controls {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                isPanelVisible = true
            }
        }
    }

    /// Clears the room highlight. Does NOT close the panel —
    /// the dashboard stays open as long as the mode is non-controls.
    func clearHighlight() {
        highlightedRoomID = nil
    }

    /// Dismisses the context panel and clears the room highlight.
    /// The active overlay mode is preserved — the panel can be reopened via the open button.
    func dismissPanel() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
            isPanelVisible = false
        }
        highlightedRoomID = nil
    }

    // MARK: Persistence

    // Shared key read by ContentView via @AppStorage to show/hide the chat FAB.
    static let sharedActiveModeKey = "floorplan_active_overlay_mode"

    private func persistMode() {
        UserDefaults.standard.set(activeMode.rawValue, forKey: modeKey)
        UserDefaults.standard.set(activeMode.rawValue, forKey: Self.sharedActiveModeKey)
    }

    private func resetToControls() {
        activeMode = .controls
        UserDefaults.standard.set(FloorplanOverlayMode.controls.rawValue, forKey: modeKey)
        UserDefaults.standard.set(FloorplanOverlayMode.controls.rawValue, forKey: Self.sharedActiveModeKey)
    }
}

// MARK: - Home Assistant Digest

/// Compact narrative summary used by floorplan overlay panels.
/// It answers "how is my home doing and where should I look first?"
struct HomeDigestSummary {
    let title: String
    let message: String
    let statusLabel: String
    let systemImage: String
    let color: Color
    let lines: [HomeDigestLine]
}

struct HomeDigestLine: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let color: Color
}

enum HomeAssistantDigestService {

    static func environmentDigest(
        rooms: [RoomEnvironmentData],
        highlightedRoomName: String?
    ) -> HomeDigestSummary {
        guard !rooms.isEmpty else {
            return HomeDigestSummary(
                title: String(localized: "home.digest.environment.title", defaultValue: "Home environment"),
                message: String(localized: "home.digest.environment.empty", defaultValue: "There is not enough environmental data yet."),
                statusLabel: String(localized: "home.digest.status.waiting", defaultValue: "Waiting"),
                systemImage: "leaf",
                color: .secondary,
                lines: []
            )
        }

        let scopedRooms: [RoomEnvironmentData]
        if let highlightedRoomName,
           let room = rooms.first(where: { $0.roomName == highlightedRoomName }) {
            scopedRooms = [room]
        } else {
            scopedRooms = rooms
        }

        let alertRooms = scopedRooms.filter { $0.worstUrgency != .normal }
        let topSensor = scopedRooms
            .flatMap(\.sensors)
            .filter { $0.urgency != .normal }
            .sorted {
                if $0.urgency != $1.urgency { return $0.urgency > $1.urgency }
                return $0.roomName < $1.roomName
            }
            .first

        let score = scopedRooms.map(\.qualityScore).min() ?? 1.0
        let color: Color = score >= 0.85 ? .green : score >= 0.60 ? .orange : .red

        let title = highlightedRoomName.map {
            String(format: String(localized: "home.digest.environment.roomTitle", defaultValue: "Environment in %@"), $0)
        } ?? String(localized: "home.digest.environment.title", defaultValue: "Home environment")

        let message: String
        let statusLabel: String
        let icon: String
        if let sensor = topSensor {
            message = String(
                format: String(localized: "home.digest.environment.issue",
                               defaultValue: "%1$@ needs attention: %2$@ is at %3$@."),
                sensor.roomName,
                sensor.serviceType.displayName.lowercased(),
                sensor.formattedValue
            )
            statusLabel = sensor.urgency.label
            icon = sensor.urgency.sfSymbol.isEmpty ? "leaf.fill" : sensor.urgency.sfSymbol
        } else {
            message = highlightedRoomName == nil
                ? String(localized: "home.digest.environment.ok", defaultValue: "The home is stable: no room needs attention right now.")
                : String(localized: "home.digest.environment.roomOk", defaultValue: "This room is stable and does not need actions right now.")
            statusLabel = String(localized: "home.digest.status.stable", defaultValue: "Stable")
            icon = "checkmark.circle.fill"
        }

        let lines = alertRooms.prefix(3).map { room in
            HomeDigestLine(
                icon: room.worstUrgency.sfSymbol.isEmpty ? "leaf.fill" : room.worstUrgency.sfSymbol,
                title: room.roomName,
                detail: room.sensors.first(where: { $0.urgency != .normal }).map {
                    "\($0.serviceType.displayName): \($0.formattedValue)"
                } ?? room.qualityLabel,
                color: room.worstUrgency.color
            )
        }

        return HomeDigestSummary(
            title: title,
            message: message,
            statusLabel: alertRooms.isEmpty
                ? statusLabel
                : String(format: String(localized: "home.digest.environment.roomsToCheck", defaultValue: "%lld to check"), alertRooms.count),
            systemImage: icon,
            color: color,
            lines: lines
        )
    }

    static func securityDigest(
        score: Int,
        aggregated: AggregatedSecurityState,
        criticals: [SecurityInsight],
        warnings: [SecurityInsight],
        monitoredCount: Int,
        highlightedRoomName: String?
    ) -> HomeDigestSummary {
        let active = (criticals + warnings)
            .filter { highlightedRoomName == nil || $0.room == highlightedRoomName }
            .sorted { $0.priority < $1.priority }

        let title = highlightedRoomName.map {
            String(format: String(localized: "home.digest.security.roomTitle", defaultValue: "Security in %@"), $0)
        } ?? String(localized: "home.digest.security.title", defaultValue: "Home security")

        let message: String
        if let first = active.first {
            message = first.room.map { "\($0): \(first.message)" } ?? first.message
        } else if monitoredCount == 0 {
            message = String(localized: "home.digest.security.noSensors", defaultValue: "There are no monitored security sensors.")
        } else {
            message = highlightedRoomName == nil
                ? String(localized: "home.digest.security.ok", defaultValue: "The home is protected: no active security events.")
                : String(localized: "home.digest.security.roomOk", defaultValue: "This room has no active security events.")
        }

        let lines = active.prefix(3).map { insight in
            HomeDigestLine(
                icon: insight.sfSymbol,
                title: insight.room ?? String(localized: "home.digest.security.global", defaultValue: "Home"),
                detail: insight.message,
                color: insight.priority.color
            )
        }

        return HomeDigestSummary(
            title: title,
            message: message,
            statusLabel: aggregated.label,
            systemImage: aggregated.systemImage,
            color: aggregated.color,
            lines: lines.isEmpty && monitoredCount > 0
                ? [
                    HomeDigestLine(
                        icon: "shield.checkered",
                        title: String(localized: "home.digest.security.score", defaultValue: "Security score"),
                        detail: "\(score)%",
                        color: aggregated.color
                    )
                ]
                : lines
        )
    }
}

struct HomeDigestSummaryCard: View {
    let summary: HomeDigestSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(summary.color.opacity(0.12))
                        .frame(width: 38, height: 38)
                    Image(systemName: summary.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(summary.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(summary.message)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Text(summary.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(summary.color.opacity(0.10), in: Capsule())
            }

            if !summary.lines.isEmpty {
                Divider()
                VStack(spacing: 8) {
                    ForEach(summary.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: line.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(line.color)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title)
                                    .font(.caption.weight(.semibold))
                                Text(line.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(summary.color.opacity(0.6))
                .frame(height: 3)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: summary.color.opacity(0.12), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}
