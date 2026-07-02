import Foundation
import SwiftData

// MARK: - PatternMigrationService

/// One-shot migration: reads legacy VersionedStore pattern JSON files and
/// inserts records into SwiftData. Runs once at app launch, gated by UserDefaults.
///
/// BehavioralPattern is still Codable so no separate legacy struct is needed.
struct PatternMigrationService {
    static let migrationDoneKey = "migration.patterns.v1.done"

    @MainActor
    static func runIfNeeded(context: ModelContext) async {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationDoneKey) else { return }

        let storeDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VersionedStore", isDirectory: true)

        let allFiles = (try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)) ?? []

        // Match "behavioral.patterns.v1*.json" but skip .backup.json files
        let patternFiles = allFiles.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("behavioral.patterns.v1") &&
                   name.hasSuffix(".json") &&
                   !name.hasSuffix(".backup.json")
        }

        guard !patternFiles.isEmpty else {
            dprint("[PatternMigration] no legacy files found — marking done")
            ud.set(true, forKey: migrationDoneKey)
            return
        }

        var totalMigrated = 0
        for fileURL in patternFiles {
            let stem      = (fileURL.lastPathComponent as NSString).deletingPathExtension
            let profileID = extractProfileID(from: stem)

            // BehavioralPattern is still Codable — decode directly, no legacy struct needed
            let store = VersionedStore<[BehavioralPattern]>(key: stem, version: 1)
            guard let patterns = store.load() else {
                dprint("[PatternMigration] could not decode \(stem)")
                continue
            }

            for pattern in patterns {
                let persisted = PersistedBehavioralPattern(from: pattern, profileID: profileID)
                context.insert(persisted)
                totalMigrated += 1
            }
            dprint("[PatternMigration] \(stem): \(patterns.count) patterns")
        }

        try? context.save()
        ud.set(true, forKey: migrationDoneKey)
        dprint("[PatternMigration] complete — \(totalMigrated) total migrated")
    }

    /// Extracts profileID from "behavioral.patterns.v1.<UUID>" filename stem.
    private static func extractProfileID(from stem: String) -> UUID? {
        let prefix = "behavioral.patterns.v1."
        guard stem.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(stem.dropFirst(prefix.count)))
    }
}
