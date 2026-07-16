import SwiftUI

struct FloorplanInteractionChromeController {
    @Binding var controlsVisible: Bool
    @Binding var hideTask: Task<Void, Never>?
    @Binding var showHelp: Bool
    @Binding var hasSeenHelp: Bool

    func shouldShowControls(isEditing: Bool) -> Bool {
        isEditing || controlsVisible
    }

    func enterEditingMode() {
        controlsVisible = true
        cancelAutoHide()
    }

    func scheduleAutoHide(isEditing: Bool) {
        hideTask?.cancel()

        guard !isEditing else {
            controlsVisible = true
            return
        }

        controlsVisible = true
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) {
                    controlsVisible = false
                }
            }
        }
    }

    func showControlsAndScheduleAutoHide(isEditing: Bool) {
        withAnimation(.easeInOut(duration: 0.25)) {
            controlsVisible = true
        }
        scheduleAutoHide(isEditing: isEditing)
    }

    func cancelAutoHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    func presentHelpIfNeeded(canPresent: @escaping @MainActor () -> Bool) {
        guard !hasSeenHelp else { return }

        let hasSeenHelp = $hasSeenHelp
        let showHelp = $showHelp

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !hasSeenHelp.wrappedValue, canPresent() else { return }
            showHelp.wrappedValue = true
        }
    }

    func markHelpSeen() {
        hasSeenHelp = true
    }

    func showHelpManually() {
        hasSeenHelp = true
        showHelp = true
    }

    func dismissHelp() {
        hasSeenHelp = true
        showHelp = false
    }
}
