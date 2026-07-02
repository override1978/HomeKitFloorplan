import Foundation
import SwiftData

// MARK: - HabitPatternMigrationService

/// One-shot migration: reads legacy VersionedStore HabitPattern JSON and
/// inserts records into SwiftData. Runs once at app launch, gated by UserDefaults.
struct HabitPatternMigrationService {
    static let migrationDoneKey = "migration.habitPatterns.v1.done"
    static let legacyStoreKey   = "habitPatterns.persisted"

    @MainActor
    static func runIfNeeded(context: ModelContext) async {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationDoneKey) else { return }

        let store = VersionedStore<[LegacyCodableHabitPattern]>(key: legacyStoreKey, version: 1)
        guard let legacyList = store.load(), !legacyList.isEmpty else {
            dprint("[HabitPatternMigration] no legacy patterns found — marking done")
            ud.set(true, forKey: migrationDoneKey)
            return
        }

        for legacy in legacyList {
            let pattern = HabitPattern(
                id:                 legacy.id,
                patternTypeRaw:     legacy.patternType.rawValue,
                accessoryName:      legacy.accessoryName,
                accessoryID:        legacy.accessoryID,
                sceneName:          legacy.sceneName,
                roomName:           legacy.roomName,
                patternDescription: legacy.description,
                detectedAt:         legacy.detectedAt,
                confidence:         legacy.confidence,
                suggestedRuleJSON:  legacy.suggestedRuleJSON,
                statusRaw:          legacy.status.rawValue
            )
            context.insert(pattern)
        }

        try? context.save()
        ud.set(true, forKey: migrationDoneKey)
        dprint("[HabitPatternMigration] complete — \(legacyList.count) patterns migrated")
    }
}

// MARK: - LegacyCodableHabitPattern

/// Mirror of the pre-migration `struct HabitPattern: Codable`.
/// Used only by HabitPatternMigrationService to decode legacy VersionedStore JSON.
private struct LegacyCodableHabitPattern: Codable {
    var id:              UUID
    var patternType:     PatternType
    var accessoryName:   String
    var accessoryID:     UUID
    var sceneName:       String?
    var roomName:        String
    var description:     String
    var detectedAt:      Date
    var confidence:      Double
    var suggestedRuleJSON: String
    var status:          PatternStatus
}
