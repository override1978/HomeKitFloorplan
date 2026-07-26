import Foundation
#if DEBUG
import os
#endif

// Strumentazione diagnostica TEMPORANEA per l'indagine sui freeze.
// Da rimuovere quando l'indagine è chiusa.
//
// Usa `os.Logger` e non `print` per una ragione precisa: print scrive su stdout,
// che esiste SOLO col debugger attaccato. Con Logger le misure restano leggibili
// in Console.app anche lanciando l'app a mano dal device — l'unico modo di
// misurare senza l'overhead di LLDB, che è la pista ancora aperta.

#if DEBUG

private let watchdogLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "HomeFloorplan",
    category: "Freeze"
)

/// Misura per quanto tempo il main actor resta occupato, cioè la durata reale
/// dei freeze percepiti.
///
/// Un task in background prova a saltare sul MainActor ogni ~50 ms. Il tempo che
/// passa prima di essere effettivamente schedulato **è** la durata per cui il
/// main actor è rimasto bloccato da altro lavoro.
enum MainThreadWatchdog {

    /// Sotto questa soglia il ritardo è schedulazione normale, non un freeze.
    private static let thresholdMilliseconds: Double = 250
    private static let pingIntervalNanoseconds: UInt64 = 50_000_000  // 50 ms

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private nonisolated(unsafe) static var isRunning = false

    static func start() {
        guard !isRunning else { return }
        isRunning = true

        watchdogLogger.notice("🧪 Watchdog attivo")

        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                // Clock monotonico: immune ai cambi di ora di sistema.
                let sentAt = DispatchTime.now().uptimeNanoseconds
                let wallClock = Date()

                await MainActor.run { }

                let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - sentAt) / 1_000_000
                if waitedMs > thresholdMilliseconds {
                    let stamp = timestampFormatter.string(from: wallClock)
                    watchdogLogger.notice("⛔️ MAIN BLOCCATO \(Int(waitedMs), privacy: .public)ms @\(stamp, privacy: .public)")
                }

                try? await Task.sleep(nanoseconds: pingIntervalNanoseconds)
            }
        }
    }
}

#endif

/// Cronometra un blocco di lavoro sincrono e logga solo se supera 20 ms.
/// Serve a scomporre un blocco del main actor nei suoi contributi reali,
/// invece di dedurli. In release è un passante che il compilatore rimuove.
@discardableResult
@inline(__always)
func measureMain<T>(_ label: String, _ work: () -> T) -> T {
    #if DEBUG
    let start = DispatchTime.now().uptimeNanoseconds
    let result = work()
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    if milliseconds > 20 {
        watchdogLogger.notice("⏱ [\(label, privacy: .public)] \(Int(milliseconds), privacy: .public)ms")
    }
    return result
    #else
    return work()
    #endif
}
