import Foundation
import SwiftData

// MARK: - VimarAutoImport

/// L'aggiornamento automatico dell'export Vimar, senza chiedere niente:
/// il primo import manuale salva un bookmark security-scoped del file su
/// iCloud Drive; a ogni apertura della sezione Energia si risolve il
/// bookmark, si confronta la data di modifica e — SOLO se l'export è
/// cambiato — si reimporta. La dedup per timestamp di `HouseMeterImport`
/// rende l'operazione idempotente: nel caso peggiore costa «0 righe nuove».
///
/// Il file può essere «dataless» su iCloud: la lettura è coordinata (che
/// attende il download) e vive FUORI dal main actor — il main riceve solo
/// i byte già pronti.
enum VimarAutoImport {

    private static let bookmarkKey = "energy.vimar.bookmark"
    private static let lastModifiedKey = "energy.vimar.lastImportedModification"

    /// Da chiamare dopo un import manuale riuscito, mentre l'accesso
    /// security-scoped all'URL è ancora attivo: da qui in poi l'app sa
    /// dove vive l'export.
    static func rememberFile(at url: URL) {
        guard let bookmark = try? url.bookmarkData() else { return }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(modificationDate(of: url), forKey: lastModifiedKey)
    }

    /// Se l'export ricordato è cambiato dall'ultimo import lo reimporta e
    /// riporta l'esito; `nil` = niente da fare (nessun bookmark, file
    /// invariato o momentaneamente irraggiungibile — si ritenta alla
    /// prossima apertura).
    @MainActor
    static func importIfChanged(modelContainer: ModelContainer) async -> HouseMeterImport.Outcome? {
        guard let payload = await Task.detached(priority: .utility, operation: readIfChanged).value
        else { return nil }
        guard let outcome = try? HouseMeterImport.importArchive(payload.data,
                                                                modelContainer: modelContainer)
        else { return nil }
        UserDefaults.standard.set(payload.modified, forKey: lastModifiedKey)
        dprint("⚡️ Auto-import Vimar: \(outcome.inserted) righe nuove dall'export del \(payload.modified)")
        return outcome
    }

    // MARK: Lato file (fuori dal main)

    private struct Payload: Sendable {
        let data: Data
        let modified: Date
    }

    @Sendable
    private static func readIfChanged() -> Payload? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &isStale)
        else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if isStale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }

        // Se iCloud tiene il file solo in cloud, questo avvia il download;
        // la lettura coordinata sotto lo attende.
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)

        guard let modified = modificationDate(of: url) else { return nil }
        let last = UserDefaults.standard.object(forKey: lastModifiedKey) as? Date
        guard modified != last else { return nil }

        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordinationError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        guard let data else { return nil }
        return Payload(data: data, modified: modified)
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
