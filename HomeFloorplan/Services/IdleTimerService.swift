import SwiftUI
import UIKit

enum IdleSuppressionReason: Hashable {
    case modalPresentation
    case chatPanel
    case alarmOverlay
    case drawingEditor
    case floorplanInteraction
}

// MARK: - IdleTimerService

/// Rileva l'inattività dell'utente e attiva/disattiva lo screensaver.
///
/// - Ogni volta che viene chiamato `resetTimer()` il conto alla rovescia riparte.
/// - Dopo `timeout` secondi senza interazioni `isIdle` diventa `true`.
/// - Impostare `isIdle = false` (es. tap sullo screensaver) resetta anche il timer.
@Observable
final class IdleTimerService {

    /// Istanza condivisa usata da `IdleAwareApplication.sendEvent`.
    static let shared = IdleTimerService()


    /// Secondi di inattività prima di mostrare lo screensaver.
    var timeout: TimeInterval = 90

    /// `true` quando l'app è inattiva e lo screensaver deve essere mostrato.
    private(set) var isIdle: Bool = false

    /// Motivi attivi per cui lo screensaver non deve comparire anche se il timer scade.
    private var suppressionCounts: [IdleSuppressionReason: Int] = [:]

    var suppressionReasons: Set<IdleSuppressionReason> {
        Set(suppressionCounts.keys)
    }

    var shouldShowScreensaver: Bool {
        isIdle && suppressionCounts.isEmpty
    }

    private var task: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Chiama questo metodo ad ogni interazione dell'utente per resettare il timer.
    func resetTimer() {
        isIdle = false
        if suppressionCounts.isEmpty {
            scheduleIdle()
        } else {
            task?.cancel()
        }
    }

    /// Dismette lo screensaver e riavvia il timer.
    func dismissScreensaver() {
        isIdle = false
        scheduleIdle()
    }

    /// Blocca temporaneamente la comparsa dello screensaver.
    func suppress(_ reason: IdleSuppressionReason) {
        suppressionCounts[reason, default: 0] += 1
        isIdle = false
        task?.cancel()
    }

    /// Rimuove un blocco temporaneo e riavvia il timer quando non ci sono altri blocchi.
    func resume(_ reason: IdleSuppressionReason) {
        if let count = suppressionCounts[reason], count > 1 {
            suppressionCounts[reason] = count - 1
        } else {
            suppressionCounts.removeValue(forKey: reason)
        }
        isIdle = false
        if suppressionCounts.isEmpty {
            scheduleIdle()
        }
    }

    // MARK: - Private

    private func scheduleIdle() {
        task?.cancel()
        guard timeout.isFinite, timeout > 0 else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(timeout * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    guard !(self.task?.isCancelled ?? true) else { return }
                    guard self.suppressionCounts.isEmpty else {
                        self.isIdle = false
                        return
                    }
                    self.isIdle = true
                }
            } catch {
                // Task cancellato: nessuna azione
            }
        }
    }
}

private struct IdleSuppressionModifier: ViewModifier {
    @Environment(IdleTimerService.self) private var idleTimer

    let reason: IdleSuppressionReason
    let isActive: Bool
    @State private var isSuppressed = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateSuppression(active: isActive)
            }
            .onChange(of: isActive) { _, active in
                updateSuppression(active: active)
            }
            .onDisappear {
                if isSuppressed {
                    idleTimer.resume(reason)
                    isSuppressed = false
                }
            }
    }

    private func updateSuppression(active: Bool) {
        if active && !isSuppressed {
            idleTimer.suppress(reason)
            isSuppressed = true
        } else if !active && isSuppressed {
            idleTimer.resume(reason)
            isSuppressed = false
        }
    }
}

extension View {
    func suppressesIdleScreensaver(_ reason: IdleSuppressionReason, when isActive: Bool = true) -> some View {
        modifier(IdleSuppressionModifier(reason: reason, isActive: isActive))
    }
}
