import Foundation
import SwiftData

// MARK: - SchemaVersionValidator
//
// Single source of truth for the app's SwiftData schema version.
//
// How to maintain this file:
//   • Increment `currentVersion` whenever any @Model type is added, removed,
//     or receives a breaking property change that requires lightweight migration.
//   • Update the model inventory comment below to reflect the new state.
//   • If a migration is non-lightweight (e.g. custom mapping), create a
//     VersionedSchema + SchemaMigrationPlan before shipping.
//
// Current schema — v21 (20 @Model types):
//   v21: PersistedHomeInsight += signalTypeRaw: String? (lightweight migration)
//   1.  Floorplan
//   2.  PlacedAccessory
//   3.  ActivityEvent
//   4.  SensorReading
//   5.  SensorAlertEvent
//   6.  SensorAlertThreshold
//   7.  AccessoryEvent
//   8.  Rule
//   9.  ActionEffectivenessEvent
//   10. PersistedInsight (legacy environmental insight bridge)
//   11. RoomAnalysisState
//   12. DailySensorSummary
//   13. AccessoryUsageSummary
//   14. EffectivenessSummary
//   15. PersistedHomeInsight (primary unified insight store)
//   16. ProactiveNotification
//   17. AutomationOpportunity
//   18. PersistedBehavioralPattern
//   19. HabitPattern
//   20. SyncableSettings
//
// NOTE: Automated migration tests require a dedicated test target.
// The project currently has no test target. When one is added, create a
// SchemaVersionValidatorTests.swift that:
//   • Opens an in-memory ModelContainer with the current Schema
//   • Verifies all model types are fetchable without errors
//   • Confirms currentVersion matches the count of types in the Schema array

enum SchemaVersionValidator {

    // MARK: - Version constant

    /// Bump this whenever the SwiftData schema changes (models added / removed / breaking field change).
    static let currentVersion: Int = 21

    // MARK: - Persistence

    private static let versionKey = "com.homefloorplan.schemaVersion"

    /// Schema version recorded on the previous launch, or `nil` on first install.
    static var installedVersion: Int? {
        let ud = UserDefaults.standard
        guard ud.object(forKey: versionKey) != nil else { return nil }
        return ud.integer(forKey: versionKey)
    }

    /// Writes the current version to UserDefaults.
    static func recordCurrentVersion() {
        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    // MARK: - Validation

    /// Compares the persisted schema version with `currentVersion`.
    ///
    /// - Returns: `true` if the schema version is unchanged (or this is a first install).
    ///   Always persists `currentVersion` for the next launch regardless of the result.
    @discardableResult
    static func validateAndRecord() -> Bool {
        let compatible: Bool
        switch installedVersion {
        case nil:
            dprint("✅ [Schema] First install — recording v\(currentVersion)")
            compatible = true
        case currentVersion:
            compatible = true
        case let old?:
            dprint("⚠️ [Schema] Version change detected: v\(old) → v\(currentVersion). SwiftData will attempt lightweight migration.")
            compatible = false
        }
        recordCurrentVersion()
        return compatible
    }

    // MARK: - Integrity probe

    /// Performs a lightweight read probe to confirm the container is queryable.
    ///
    /// SwiftData can return a valid `ModelContainer` even when the underlying
    /// SQLite file is partially corrupt. A failed fetch here is a strong signal
    /// that the store should be wiped before services are initialised.
    ///
    /// - Returns: `true` if the probe succeeds, `false` if the store is unreadable.
    static func probeContainerIntegrity(container: ModelContainer) -> Bool {
        do {
            let context = ModelContext(container)
            var descriptor = FetchDescriptor<ActivityEvent>()
            descriptor.fetchLimit = 1
            _ = try context.fetch(descriptor)
            return true
        } catch {
            dprint("❌ [Schema] Integrity probe failed — store may be corrupt: \(error)")
            return false
        }
    }
}
