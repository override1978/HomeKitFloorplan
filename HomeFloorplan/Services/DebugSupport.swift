#if DEBUG
import SwiftData

/// Hook per i test hosted: espone il ModelContainer reale creato dall'app al lancio.
///
/// Nel processo di test la creazione di un NUOVO ModelContainer fallisce sempre
/// con loadIssueModelContainer (simulatore iOS 26, qualunque configurazione:
/// in-memory, on-disk, subset — vedi PipelineEndToEndTests). Il processo host
/// invece crea il proprio container senza problemi: i test E2E riusano questo,
/// resettando i dati della pipeline prima di ogni scenario.
@MainActor
enum DebugSupport {
    static var modelContainer: ModelContainer?
}
#endif
