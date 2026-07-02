import Foundation
import SwiftData

/// One-shot migration that populates Floorplan.imageData from legacy imageFilename files.
/// Safe to call on every launch — exits immediately if already completed.
struct ImageMigrationService {

    static let migrationDoneKey    = "migration.images.v1.done"
    /// Snapshot counts written before migration — read by MigrationValidator to verify integrity.
    static let snapshotPendingKey  = "migration.images.v1.pendingCount"
    static let snapshotMigratedKey = "migration.images.v1.migratedCount"

    /// Runs the migration on the provided context.
    /// Call this once at app startup from a `.task` modifier on the root view.
    /// Idempotent: exits immediately after the first successful run.
    @MainActor
    static func runIfNeeded(context: ModelContext) async {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationDoneKey) else { return }

        guard let all = try? context.fetch(FetchDescriptor<Floorplan>()) else {
            dprint("[ImageMigration] fetch failed — aborting")
            return
        }

        let pending = all.filter { $0.imageData == nil && !$0.imageFilename.isEmpty }
        ud.set(pending.count, forKey: snapshotPendingKey)

        guard !pending.isEmpty else {
            ud.set(0, forKey: snapshotMigratedKey)
            ud.set(true, forKey: migrationDoneKey)
            dprint("[ImageMigration] nothing to migrate (\(all.count) floorplans already up to date)")
            return
        }

        dprint("[ImageMigration] starting — \(pending.count)/\(all.count) floorplans pending")

        var migratedCount = 0
        for floorplan in pending {
            // Capture String (Sendable) before entering detached task — avoids capturing the model.
            let filename = floorplan.imageFilename
            let data = await Task.detached(priority: .utility) {
                ImageStorageService.rawData(filename: filename)
            }.value

            if let data {
                floorplan.imageData = data
                migratedCount += 1
            } else {
                dprint("[ImageMigration] file not found, skipping '\(filename)'")
            }
        }

        try? context.save()
        ud.set(migratedCount, forKey: snapshotMigratedKey)
        ud.set(true, forKey: migrationDoneKey)
        dprint("[ImageMigration] complete — \(migratedCount)/\(pending.count) migrated")
        // NOTE: original JPEG files in ApplicationSupport/floorplans/ are intentionally preserved
        // as a safety backup during the migration window. Cleanup scheduled in FASE 4.
    }
}
