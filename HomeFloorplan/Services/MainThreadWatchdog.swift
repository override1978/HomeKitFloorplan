#if DEBUG
import Foundation

/// Strumento diagnostico TEMPORANEO: misura per quanto tempo il main actor
/// resta occupato, cioè la durata reale dei freeze percepiti.
///
/// Come funziona: un task in background prova a saltare sul MainActor ogni
/// ~50 ms. Il tempo che passa prima di essere effettivamente schedulato **è**
/// la durata per cui il main actor è rimasto bloccato da altro lavoro.
/// Vengono loggati solo gli sforamenti oltre soglia, con orario preciso, così
/// si incrociano con gli altri log (`SensorLogger`, `loadFromCoreData`,
/// `runCycle`, pipeline AI) per identificare il colpevole di ogni blocco:
///
///     ⛔️ MAIN BLOCCATO 840ms @20:47:15.331
///
/// Compilato solo in DEBUG: zero impatto sulla build distribuita.
/// Da rimuovere quando l'indagine sui freeze è chiusa.
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

        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                // Clock monotonico: immune ai cambi di ora di sistema.
                let sentAt = DispatchTime.now().uptimeNanoseconds
                let wallClock = Date()

                await MainActor.run { }

                let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - sentAt) / 1_000_000
                if waitedMs > thresholdMilliseconds {
                    dprint("⛔️ MAIN BLOCCATO \(Int(waitedMs))ms @\(timestampFormatter.string(from: wallClock))")
                }

                try? await Task.sleep(nanoseconds: pingIntervalNanoseconds)
            }
        }
    }
}
#endif

/// Cronometra un blocco di lavoro sincrono e logga solo se supera 20 ms.
/// Serve a scomporre un blocco del main actor nei suoi contributi reali,
/// invece di dedurli. Compilato via in release.
@discardableResult
@inline(__always)
func measureMain<T>(_ label: String, _ work: () -> T) -> T {
    #if DEBUG
    let start = DispatchTime.now().uptimeNanoseconds
    let result = work()
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    if milliseconds > 20 {
        dprint("⏱ [\(label)] \(Int(milliseconds))ms")
    }
    return result
    #else
    return work()
    #endif
}
