import Foundation
import SwiftData

// MARK: - SettingsMigrationService

/// One-shot task that:
///   1. Creates (or updates) the `SyncableSettings` singleton record from current
///      UserDefaults / AppStorage values.
///   2. Cleans up VersionedStore JSON files that have already been migrated to SwiftData.
///
/// Runs once at app launch after all other migrations complete.
struct SettingsMigrationService {
    static let migrationDoneKey = "migration.syncableSettings.v1.done"

    @MainActor
    static func runIfNeeded(
        context: ModelContext,
        aiSettings: AISettings,
        securityMonitoredUUIDsRaw: String
    ) async {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationDoneKey) else { return }

        let descriptor = FetchDescriptor<SyncableSettings>()
        let existing   = (try? context.fetch(descriptor))?.first

        if let existing {
            existing.aiProviderRaw             = aiSettings.selectedProvider.rawValue
            existing.aiIsEnabled               = aiSettings.isAIEnabled
            existing.aiSuggestionsEnabled      = aiSettings.suggestionsEnabled
            existing.aiAnomalyDetectionEnabled = aiSettings.anomalyDetectionEnabled
            existing.aiRuleEngineEnabled       = aiSettings.ruleEngineEnabled
            existing.aiHasDataConsent          = aiSettings.hasAIDataConsent
            existing.securityMonitoredUUIDsRaw = securityMonitoredUUIDsRaw
            existing.modifiedAt                = .now
        } else {
            let settings = SyncableSettings(
                aiProviderRaw:              aiSettings.selectedProvider.rawValue,
                aiIsEnabled:               aiSettings.isAIEnabled,
                aiSuggestionsEnabled:       aiSettings.suggestionsEnabled,
                aiAnomalyDetectionEnabled:  aiSettings.anomalyDetectionEnabled,
                aiRuleEngineEnabled:        aiSettings.ruleEngineEnabled,
                aiHasDataConsent:           aiSettings.hasAIDataConsent,
                securityMonitoredUUIDsRaw:  securityMonitoredUUIDsRaw
            )
            context.insert(settings)
        }

        try? context.save()
        ud.set(true, forKey: migrationDoneKey)
        dprint("[SettingsMigration] SyncableSettings initialised")

        cleanupMigratedVersionedStoreFiles()
    }

    // MARK: - VersionedStore cleanup

    /// Deletes VersionedStore JSON files whose data has been migrated to SwiftData.
    /// Backup files (.backup.json) are intentionally preserved.
    private static func cleanupMigratedVersionedStoreFiles() {
        guard let storeDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("VersionedStore", isDirectory: true)
        else { return }

        guard let allFiles = try? FileManager.default
            .contentsOfDirectory(at: storeDir, includingPropertiesForKeys: nil)
        else { return }

        // Only clean up keys whose migration gates are confirmed done
        let ud = UserDefaults.standard
        var migratedPrefixes: [String] = []
        if ud.bool(forKey: OpportunityMigrationService.migrationDoneKey) {
            migratedPrefixes.append("behavioral.opportunities.v1")
        }
        if ud.bool(forKey: PatternMigrationService.migrationDoneKey) {
            migratedPrefixes.append("behavioral.patterns.v1")
        }
        if ud.bool(forKey: HabitPatternMigrationService.migrationDoneKey) {
            migratedPrefixes.append(HabitPatternMigrationService.legacyStoreKey)
        }

        guard !migratedPrefixes.isEmpty else { return }

        var cleaned = 0
        for file in allFiles {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"), !name.hasSuffix(".backup.json") else { continue }
            let shouldDelete = migratedPrefixes.contains { name.hasPrefix($0) }
            if shouldDelete {
                try? FileManager.default.removeItem(at: file)
                cleaned += 1
            }
        }

        if cleaned > 0 {
            dprint("[SettingsMigration] cleaned up \(cleaned) migrated VersionedStore file(s)")
        }
    }
}
