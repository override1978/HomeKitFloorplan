import Foundation

// MARK: - VersionedStore

/// Generic versioned wrapper for JSON persistence using Application Support files.
///
/// Stores data in `<App Support>/VersionedStore/<key>.json` — no UserDefaults size limit.
///
/// - **Save**: wraps payload in Envelope{version, payload}; atomically writes to file;
///   backs up the previous file at `<key>.backup.json` before overwriting.
/// - **Load**: reads from file first; on first run migrates legacy UserDefaults data and
///   removes the old key automatically.
/// - **Version mismatch**: calls `migrate` closure; returns nil on failure (data discarded).
struct VersionedStore<T: Codable> {

    let key:            String
    let currentVersion: Int
    let migrate:        ((Int, Data) -> T?)?

    init(key: String, version: Int = 1, migrate: ((Int, Data) -> T?)? = nil) {
        self.key            = key
        self.currentVersion = version
        self.migrate        = migrate
    }

    // MARK: - File URLs

    private static var storeDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("VersionedStore", isDirectory: true)
    }

    private var fileURL: URL {
        Self.storeDirectory.appendingPathComponent("\(key).json")
    }

    private var backupURL: URL {
        Self.storeDirectory.appendingPathComponent("\(key).backup.json")
    }

    // MARK: - Save

    func save(_ value: T) {
        guard let payload = try? JSONEncoder().encode(value) else {
            dprint("⚠️ VersionedStore[\(key)]: payload encoding failed — NOT saved")
            return
        }
        guard let envelopeData = try? JSONEncoder().encode(Envelope(version: currentVersion, payload: payload)) else {
            dprint("⚠️ VersionedStore[\(key)]: envelope encoding failed — NOT saved")
            return
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.storeDirectory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: fileURL.path) {
            // Remove before copy so copyItem doesn't fail silently on second+ saves.
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: fileURL, to: backupURL)
        }
        do {
            try envelopeData.write(to: fileURL, options: .atomic)
            dprint("✅ VersionedStore[\(key)]: saved \(envelopeData.count) bytes")
        } catch {
            dprint("⚠️ VersionedStore[\(key)]: write failed — \(error)")
        }
    }

    // MARK: - Load

    func load() -> T? {
        if let data = try? Data(contentsOf: fileURL) {
            // Eagerly clean up any large UserDefaults blob that may still exist from before the
            // file-based migration. Even one leftover 2MB blob causes every subsequent
            // UserDefaults write to fail with the 4MB limit error.
            if UserDefaults.standard.object(forKey: key) != nil {
                UserDefaults.standard.removeObject(forKey: key)
            }
            return decode(from: data)
        }
        // One-time migration from legacy UserDefaults
        return migrateFromUserDefaults()
    }

    // MARK: - Diagnostics

    var storedByteCount: Int  { (try? Data(contentsOf: fileURL).count) ?? 0 }
    var backupByteCount:  Int  { (try? Data(contentsOf: backupURL).count) ?? 0 }
    var hasBackup:        Bool { FileManager.default.fileExists(atPath: backupURL.path) }


    // MARK: - Private helpers

    private func decode(from data: Data) -> T? {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            if envelope.version == currentVersion {
                return try? JSONDecoder().decode(T.self, from: envelope.payload)
            }
            if let migrated = migrate?(envelope.version, envelope.payload) {
                save(migrated)
                return migrated
            }
            return nil
        }
        // Raw JSON without envelope (e.g. file written by an older code path)
        if let legacy = try? JSONDecoder().decode(T.self, from: data) {
            save(legacy)
            return legacy
        }
        return nil
    }

    private func migrateFromUserDefaults() -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }

        // Preserve the original UserDefaults blob as a backup before migrating.
        // This ensures backup=exists is visible in diagnostics and provides recovery data
        // even on the very first write (when no prior file exists).
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.storeDirectory, withIntermediateDirectories: true)
        try? data.write(to: backupURL, options: .atomic)

        // Try envelope format first (data written by an earlier VersionedStore that used UserDefaults)
        var value: T?
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            value = try? JSONDecoder().decode(T.self, from: envelope.payload)
        }
        // Fallback: raw JSON (legacy, pre-envelope format)
        if value == nil {
            value = try? JSONDecoder().decode(T.self, from: data)
        }

        if let v = value { save(v) }
        // Always remove the key — even if decoding fails the blob must not remain
        // or it will cause 4MB limit errors on every subsequent UserDefaults write.
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }
}

// MARK: - Envelope

private struct Envelope: Codable {
    let version: Int
    let payload: Data
}

// MARK: - Diagnostic helper (non-generic, usable without type annotation)

/// Returns file sizes and backup presence for a VersionedStore key.
func versionedStoreInfo(key: String) -> (stored: Int, backup: Int, hasBackup: Bool) {
    let dir    = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("VersionedStore", isDirectory: true)
    let file   = dir.appendingPathComponent("\(key).json")
    let bak    = dir.appendingPathComponent("\(key).backup.json")
    let stored = (try? Data(contentsOf: file).count) ?? 0
    let backup = (try? Data(contentsOf: bak).count) ?? 0
    return (stored, backup, FileManager.default.fileExists(atPath: bak.path))
}
