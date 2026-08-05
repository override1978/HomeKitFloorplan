import Foundation
import Observation

// MARK: - ArchiveStore

/// Conserva le copie singole di scene e automazioni.
///
/// Un file solo, non uno per elemento come per gli snapshot: là il payload è un
/// blocco da decine di KB che nessuno interroga per campi, qui sono oggetti
/// piccoli che si scorrono tutti insieme ogni volta che si apre l'elenco.
/// Dividerli in file costringerebbe ad aprirli uno a uno per mostrare una lista.
@MainActor
@Observable
final class ArchiveStore {

    private static let key = "home.archive.v1"
    private static let version = 1

    private(set) var items: [ArchivedItem] = []

    private let store: VersionedStore<[ArchivedItem]>
    private let imageDirectory: URL

    init() {
        store = VersionedStore<[ArchivedItem]>(key: Self.key, version: Self.version)
        items = (store.load() ?? []).sorted { $0.archivedAt > $1.archivedAt }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArchiveImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        imageDirectory = base
    }

    // MARK: - Immagini

    /// Lo sfondo di una planimetria archiviata sta in un file suo.
    ///
    /// Dentro l'indice sarebbe letto a ogni avvio dell'app da chiunque, anche da
    /// chi l'archivio non lo apre mai: qualche megabyte per copia lo rende un
    /// costo di lancio invece che un costo di consultazione.
    func imageData(for id: UUID) -> Data? {
        try? Data(contentsOf: imageURL(for: id))
    }

    func storeImage(_ data: Data, for id: UUID) {
        try? data.write(to: imageURL(for: id), options: .atomic)
    }

    private func imageURL(for id: UUID) -> URL {
        imageDirectory.appendingPathComponent("\(id.uuidString).img")
    }

    func items(homeName: String) -> [ArchivedItem] {
        items.filter { $0.homeName == homeName }
    }

    @discardableResult
    func add(_ item: ArchivedItem) -> ArchivedItem {
        // Nessuna deduplica per contenuto, al contrario degli snapshot: qui
        // archiviare due volte la stessa scena è **voluto**, sono due momenti
        // diversi della stessa cosa e si vuole poter tornare a entrambi.
        items.insert(item, at: 0)
        persist()
        return item
    }

    func rename(_ id: UUID, note: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: imageURL(for: id))
        persist()
    }

    private func persist() {
        items.sort { $0.archivedAt > $1.archivedAt }
        store.save(items)
    }
}
