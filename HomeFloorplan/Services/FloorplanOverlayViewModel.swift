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
        restoreMode()
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

    private func restoreMode() {
        if let raw = UserDefaults.standard.string(forKey: modeKey),
           let mode = FloorplanOverlayMode(rawValue: raw) {
            activeMode = mode
            // persistMode() fires via didSet and updates the shared key too.
        } else {
            // No saved mode: reset shared key to controls so ContentView reflects defaults.
            UserDefaults.standard.set(FloorplanOverlayMode.controls.rawValue, forKey: Self.sharedActiveModeKey)
        }
    }
}
