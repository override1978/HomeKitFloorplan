import Foundation

/// Rileva se il processo è il test host degli unit test.
///
/// Usato per rendere inerte l'app host durante i test: i servizi di startup
/// (root view, auto-sync CloudKit) scrivono sullo stesso ModelContainer che
/// PipelineEndToEndTests riusa, e al primo avvio su un simulatore clone fresco
/// le loro scritture concorrenti rendevano i test non deterministici.
enum TestEnvironment {
    static var isRunningUnitTests: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
        #else
        return false
        #endif
    }
}

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
