import SwiftUI
import UIKit

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

    private var task: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Chiama questo metodo ad ogni interazione dell'utente per resettare il timer.
    func resetTimer() {
        isIdle = false
        scheduleIdle()
    }

    /// Dismette lo screensaver e riavvia il timer.
    func dismissScreensaver() {
        isIdle = false
        scheduleIdle()
    }

    // MARK: - Private

    private func scheduleIdle() {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(timeout * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                await MainActor.run {
                    guard !(self.task?.isCancelled ?? true) else { return }
                    self.isIdle = true
                }
            } catch {
                // Task cancellato: nessuna azione
            }
        }
    }
}
