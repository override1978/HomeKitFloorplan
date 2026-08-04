import Foundation
import Observation

// MARK: - HomeSnapshotStore

/// Conserva gli snapshot: **i file su disco, l'indice a parte**.
///
/// Uno snapshot è un blocco immutabile che nessuno interroga per campi, quindi
/// non è un modello relazionale e non entra in SwiftData — che costerebbe un
/// avanzamento di schema per zero vantaggi. L'indice invece è piccolo e cambia
/// spesso, e usa `VersionedStore`, che porta con sé scrittura atomica e copia di
/// sicurezza.
///
/// La stessa divisione che `ImageStorageService` fa già per le immagini delle
/// planimetrie: il blob dove sta comodo, i metadati dove si cercano.
@MainActor
@Observable
final class HomeSnapshotStore {

    /// Oltre questo numero i più vecchi non bloccati vengono potati. A ~90 KB
    /// l'uno, cento snapshot stanno in 9 MB: il limite serve a non accumulare
    /// all'infinito, non a risparmiare spazio.
    static let retentionLimit = 100

    private static let indexKey = "home.snapshot.index"
    private static let indexVersion = 1

    /// Riga d'indice: tutto ciò che serve a **mostrare l'elenco** senza aprire
    /// un solo file.
    struct Entry: Codable, Identifiable, Sendable, Equatable {
        let id: UUID
        var title: String
        let capturedAt: Date
        let deviceName: String
        let homeName: String
        let homeUUID: String?
        let appVersion: String
        let fingerprint: String
        let byteCount: Int
        let counts: HomeConfigurationSnapshot.Counts
        let identityCoverage: Double
        var isPinned: Bool
        /// Ultima volta che una cattura ha trovato la configurazione ancora
        /// identica a questa. È ciò che permette di dire «niente è cambiato da
        /// allora» senza creare un doppione.
        var lastConfirmedAt: Date
    }

    private(set) var entries: [Entry] = []

    private let directory: URL
    private let indexStore: VersionedStore<[Entry]>

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        directory = base
        indexStore = VersionedStore<[Entry]>(key: Self.indexKey, version: Self.indexVersion)
        entries = (indexStore.load() ?? []).sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: - Salvataggio

    enum SaveOutcome: Sendable {
        /// Creato uno snapshot nuovo.
        case created(Entry)
        /// Configurazione identica all'ultimo: non si duplica, si aggiorna la
        /// data di conferma.
        case unchanged(Entry)
    }

    /// Salva, **a meno che non sia cambiato niente**.
    ///
    /// La configurazione di una casa è quasi statica: senza questo controllo
    /// ogni tocco produrrebbe un file identico al precedente, e l'elenco
    /// diventerebbe illeggibile proprio quando serve — quando si cerca *quando*
    /// è cambiato qualcosa.
    @discardableResult
    func save(_ snapshot: HomeConfigurationSnapshot, title: String = "") throws -> SaveOutcome {
        let fingerprint = snapshot.configurationFingerprint

        if let index = entries.firstIndex(where: {
            $0.fingerprint == fingerprint && $0.homeUUID == snapshot.homeUUID
        }) {
            entries[index].lastConfirmedAt = Date()
            persistIndex()
            return .unchanged(entries[index])
        }

        let data = try Self.encoder.encode(snapshot)
        let compressed = try (data as NSData).compressed(using: .zlib) as Data
        try compressed.write(to: fileURL(for: snapshot.id), options: .atomic)

        let entry = Entry(
            id: snapshot.id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            capturedAt: snapshot.capturedAt,
            deviceName: snapshot.capturedOnDevice,
            homeName: snapshot.homeName,
            homeUUID: snapshot.homeUUID,
            appVersion: snapshot.appVersion,
            fingerprint: fingerprint,
            byteCount: compressed.count,
            counts: snapshot.counts,
            identityCoverage: snapshot.reliableIdentityCoverage,
            isPinned: false,
            lastConfirmedAt: snapshot.capturedAt
        )
        entries.insert(entry, at: 0)
        prune()
        persistIndex()
        return .created(entry)
    }

    // MARK: - Lettura

    func snapshot(with id: UUID) throws -> HomeConfigurationSnapshot {
        let compressed = try Data(contentsOf: fileURL(for: id))
        let data = try (compressed as NSData).decompressed(using: .zlib) as Data
        return try Self.decoder.decode(HomeConfigurationSnapshot.self, from: data)
    }

    /// Vero se la configurazione attuale coincide ancora con questo snapshot.
    func isUpToDate(_ entry: Entry, against fingerprint: String) -> Bool {
        entry.fingerprint == fingerprint
    }

    // MARK: - Modifiche all'indice

    func rename(_ id: UUID, to title: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        persistIndex()
    }

    func setPinned(_ pinned: Bool, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isPinned = pinned
        persistIndex()
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(for: id))
        persistIndex()
    }

    var totalByteCount: Int { entries.reduce(0) { $0 + $1.byteCount } }

    // MARK: - Interni

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).hksnap")
    }

    /// Pota i più vecchi **non bloccati**. Uno snapshot bloccato non sparisce
    /// mai per anzianità: è il modo per dire «questo lo tengo».
    private func prune() {
        let unpinned = entries.filter { !$0.isPinned }
        guard entries.count > Self.retentionLimit, !unpinned.isEmpty else { return }
        let excess = entries.count - Self.retentionLimit
        let doomed = unpinned.suffix(excess)
        for entry in doomed {
            try? FileManager.default.removeItem(at: fileURL(for: entry.id))
        }
        let doomedIDs = Set(doomed.map(\.id))
        entries.removeAll { doomedIDs.contains($0.id) }
    }

    private func persistIndex() {
        entries.sort { $0.capturedAt > $1.capturedAt }
        indexStore.save(entries)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
