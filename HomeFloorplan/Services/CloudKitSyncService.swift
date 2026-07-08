import Foundation
import CloudKit
import SwiftData
import Observation

extension Notification.Name {
    static let floorplansDidApplyRemoteChanges = Notification.Name("floorplansDidApplyRemoteChanges")
}

enum FloorplanRemoteChangeNotification {
    static let markerSnapshotsByFloorplanIDKey = "markerSnapshotsByFloorplanID"
}

// MARK: - CloudKitSyncService

/// Manages bidirectional CloudKit sync for Floorplan and SyncableSettings records
/// using CKSyncEngine (iOS 17+). Push: scan dirty records → pendingRecordZoneChanges.
/// Pull: apply modifications/deletions fetched from the private database.
/// Conflict strategy: last-write-wins on updatedAt / modifiedAt.
@Observable
@MainActor
final class CloudKitSyncService {

    // MARK: - Constants

    static let containerID = "iCloud.com.override1978.HomeFloorplan"
    static let zoneID      = CKRecordZone.ID(zoneName: "HomeFloorplan",
                                             ownerName: CKCurrentUserDefaultName)

    private static let engineStateKey        = "cloudkit.syncEngineState"
    private static let lastSyncedKey         = "cloudkit.lastSyncedAt"
    private static let zoneCreatedKey        = "cloudkit.zoneCreated"
    private static let syncedThresholdIDsKey = "cloudkit.syncedThresholdIDs"
    private static let localFirstSafetyVersionKey = "cloudkit.localFirstSafetyVersion"
    private static let currentLocalFirstSafetyVersion = 1
    private static let deterministicZoneTokenKey = "cloudkit.deterministicZoneToken"
    private static let deterministicDeletionReplayVersionKey = "cloudkit.deterministicDeletionReplayVersion"
    private static let currentDeterministicDeletionReplayVersion = 1
    private static let markerBackfillQueuedKey = "cloudkit.markerBackfillQueued.v2"
    private static let markerIdentityCacheKey = "cloudkit.markerIdentityCache.v1"
    private static let automaticMasterClaimCompletedKey = "cloudkit.automaticMasterClaimCompleted.v1"
    private static let securityMonitoredAccessoriesField = "securityMonitoredAccessoriesJSON"
    private static let syncedUserPreferenceFields: [String: UserPreferenceField] = [
        "prefMarkerSizeRaw": .string(MarkerSize.appStorageKey),
        "prefIdleTimeoutSeconds": .double("idleTimeout"),
        "prefTemperatureUnitRaw": .string(TemperatureUnit.appStorageKey),
        "prefAppLanguageRaw": .string(AppLanguage.appStorageKey),
        "prefDimensionUnitRaw": .string(DimensionUnit.appStorageKey),
        "prefAlertNotificationsEnabled": .bool("alertNotificationsEnabled"),
        "prefSecurityNotificationsEnabled": .bool(SecurityNotificationService.enabledKey),
        "prefProactiveNotificationsEnabled": .bool("proactiveIntelligenceNotificationsEnabled"),
        "prefHomeLocationCityName": .string("homeLocation.cityName"),
        "prefHomeLocationLatitude": .double(LocationPresenceService.homeLatKey),
        "prefHomeLocationLongitude": .double(LocationPresenceService.homeLonKey)
    ]

    private static let floorplanPrefix   = "floorplan:"
    private static let settingsPrefix    = "settings:"
    private static let opportunityPrefix = "opportunity:"
    private static let thresholdPrefix   = "threshold:"
    private static let insightPrefix     = "insight:"
    private static let behaviorPrefix    = "behavior:"
    private static let habitPrefix       = "habit:"

    private static func formatCoordinate(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private struct CachedMarkerIdentity: Codable {
        var accessoryName: String?
        var roomName: String?
    }

    private struct SecurityMonitoredAccessorySnapshot: Codable {
        var homeKitAccessoryUUID: UUID
        var accessoryName: String?
        var roomName: String?
    }

    private enum UserPreferenceField {
        case string(String)
        case bool(String)
        case double(String)
    }

    // MARK: - Observable State

    var isSyncing:              Bool  = false
    var lastSyncedAt:           Date?
    var lastError:              Error?
    /// True after the first CKSyncEngine fetch cycle completes on this launch.
    /// Used by ContentView to gate the "Connecting to iCloud…" screen on first install.
    var hasCompletedInitialSync: Bool  = false

    /// Called (on MainActor) when a CloudKit sync delivers SyncableSettings that
    /// confirm this iCloud account already has a master device → auto-complete onboarding.
    var onboardingAutoCompleteCallback: (() -> Void)?

    /// Provides HomeKit identity metadata for marker sync.
    /// HMAccessory.uniqueIdentifier can differ across devices, so snapshots also
    /// carry name/room for cross-device remapping.
    var accessorySnapshotProvider: ((UUID) -> (name: String?, roomName: String?))?
    var markerIconOverrideProvider: ((UUID) -> String?)?
    var markerIconOverrideApplyCallback: ((UUID, String?) -> Void)?

    /// Resolves a synced marker UUID/name/room into this device's local HMAccessory UUID.
    var accessoryUUIDResolver: ((UUID, String?, String?) -> UUID?)?

    /// Resolves a synced room UUID/name into this device's local HMRoom UUID.
    var roomUUIDResolver: ((UUID, String) -> UUID?)?

    /// Applies remotely received settings into runtime services backed by UserDefaults.
    /// SwiftData stores the sync source of truth; this callback keeps observable app state in step.
    var remoteSettingsApplyCallback: ((SyncableSettings) -> Void)?

    /// True while CloudKit is applying remote settings into runtime state.
    /// Views can use this to avoid echoing the remote update back as a new local edit.
    var isApplyingRemoteSettings: Bool = false

    // MARK: - Private

    let modelContainer: ModelContainer
    private var syncEngine: CKSyncEngine!
    private var lastManualFetchAt: Date?
    private var isManualFetchInFlight = false
    private var lastDeterministicFetchAt: Date?
    private var isDeterministicFetchInFlight = false
    private var appliedFloorplanMarkerSnapshots: [UUID: [PlacedAccessorySnapshot]] = [:]
    /// Server records (with correct etag) cached after a serverRecordChanged conflict.
    /// Written by handleSentChanges; consumed once by buildCKRecord on the retry batch.
    private var conflictResolutionRecords: [CKRecord.ID: CKRecord] = [:]

    /// UUIDs of SensorAlertThreshold records successfully uploaded to (or downloaded from) CloudKit.
    /// Prevents re-queuing already-synced thresholds on every launch which causes "record to insert
    /// already exists" conflicts when CKSyncEngine has lost its etag state (e.g. after reinstall).
    private var syncedThresholdIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.syncedThresholdIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.syncedThresholdIDsKey) }
    }

    private var cachedMarkerIdentities: [String: CachedMarkerIdentity] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.markerIdentityCacheKey),
                  let decoded = try? JSONDecoder().decode([String: CachedMarkerIdentity].self, from: data)
            else { return [:] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: Self.markerIdentityCacheKey)
        }
    }

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        Self.applyLocalFirstSafetyMigrationIfNeeded()
        Self.resetDeterministicTokenForDeletionReplayIfNeeded()
        lastSyncedAt = UserDefaults.standard.object(forKey: Self.lastSyncedKey) as? Date

        let savedState: CKSyncEngine.State.Serialization? = {
            guard let data = UserDefaults.standard.data(forKey: Self.engineStateKey),
                  let s = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self,
                                                   from: data)
            else { return nil }
            return s
        }()

        configureSyncEngine(stateSerialization: savedState)

        // Create the custom zone on first launch (or after account switch/zone deletion).
        // .saveZone is idempotent — safe to send even if zone already exists.
        if !UserDefaults.standard.bool(forKey: Self.zoneCreatedKey) {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            dprint("[CloudKitSync] Zone not confirmed — scheduled zone creation")
        }
    }

    private func configureSyncEngine(stateSerialization: CKSyncEngine.State.Serialization?) {
        let db = CKContainer(identifier: Self.containerID).privateCloudDatabase
        var config = CKSyncEngine.Configuration(
            database: db,
            stateSerialization: stateSerialization,
            delegate: self
        )
        config.automaticallySync = true
        syncEngine = CKSyncEngine(config)
    }

    private func resetSyncEngineKnowledge(reason: String) {
        UserDefaults.standard.removeObject(forKey: Self.engineStateKey)
        UserDefaults.standard.removeObject(forKey: Self.deterministicZoneTokenKey)
        configureSyncEngine(stateSerialization: nil)
        if !UserDefaults.standard.bool(forKey: Self.zoneCreatedKey) {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        }
        registerPendingLocalChanges()
        SyncDiagnosticsLogger.log("Reset CloudKit sync knowledge reason=\(reason)")
    }

    private static func applyLocalFirstSafetyMigrationIfNeeded() {
        let savedVersion = UserDefaults.standard.integer(forKey: localFirstSafetyVersionKey)
        guard savedVersion < currentLocalFirstSafetyVersion else { return }

        UserDefaults.standard.removeObject(forKey: lastSyncedKey)
        UserDefaults.standard.removeObject(forKey: syncedThresholdIDsKey)
        UserDefaults.standard.set(currentLocalFirstSafetyVersion, forKey: localFirstSafetyVersionKey)
        dprint("[CloudKitSync] Local-first safety migration applied — local records will be re-evaluated for upload")
    }

    private static func loadServerChangeToken(forKey key: String) -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self,
            from: data
        )
    }

    private static func saveServerChangeToken(_ token: CKServerChangeToken, forKey key: String) {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        ) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func isChangeTokenExpired(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .changeTokenExpired
    }

    private static func resetDeterministicTokenForDeletionReplayIfNeeded() {
        let savedVersion = UserDefaults.standard.integer(forKey: deterministicDeletionReplayVersionKey)
        guard savedVersion < currentDeterministicDeletionReplayVersion else { return }

        UserDefaults.standard.removeObject(forKey: deterministicZoneTokenKey)
        UserDefaults.standard.set(currentDeterministicDeletionReplayVersion, forKey: deterministicDeletionReplayVersionKey)
        SyncDiagnosticsLogger.log("Reset deterministic zone token for Floorplan deletion replay")
    }

    // MARK: - Public API

    // MARK: - Device Role

    /// True if this device is the designated Master (runs behavioral analysis).
    /// Reads SyncableSettings from the store synchronously — always fresh.
    var isMaster: Bool {
        let ctx = ModelContext(modelContainer)
        guard let s = (try? ctx.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return true // no settings yet → first device → master
        }
        return s.masterDeviceID.isEmpty || s.masterDeviceID == DeviceIdentity.id
    }

    /// If no master is claimed yet, this device claims the role and syncs.
    /// This is only for the initial account bootstrap. Once this install has either
    /// seen a remote master or claimed the role once, future role changes must be explicit.
    func claimMasterIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.automaticMasterClaimCompletedKey) else {
            return
        }

        let ctx = ModelContext(modelContainer)
        if let s = (try? ctx.fetch(FetchDescriptor<SyncableSettings>()))?.first {
            guard s.masterDeviceID.isEmpty else {
                UserDefaults.standard.set(true, forKey: Self.automaticMasterClaimCompletedKey)
                return
            }
            s.masterDeviceID = DeviceIdentity.id
            s.modifiedAt     = .now
            try? ctx.save()
            UserDefaults.standard.set(true, forKey: Self.automaticMasterClaimCompletedKey)
            syncAfterSave()
            dprint("[CloudKitSync] This device claimed initial Master role")
        }
        // If SyncableSettings doesn't exist yet it will be created by SettingsMigrationService;
        // registerPendingLocalChanges() will pick it up once it exists.
    }

    /// Waits for the initial CloudKit fetch before claiming master.
    /// This prevents a second device from becoming master before it has had a
    /// chance to receive an existing SyncableSettings record from iCloud.
    func claimMasterAfterInitialSyncIfNeeded() async {
        while !hasCompletedInitialSync {
            try? await Task.sleep(for: .milliseconds(250))
        }
        claimMasterIfNeeded()
    }

    /// Explicitly transfers the Master role to this device (user-initiated from Settings).
    func becomeMaster() {
        let ctx = ModelContext(modelContainer)
        guard let s = (try? ctx.fetch(FetchDescriptor<SyncableSettings>()))?.first else { return }
        s.masterDeviceID = DeviceIdentity.id
        s.modifiedAt     = .now
        try? ctx.save()
        UserDefaults.standard.set(true, forKey: Self.automaticMasterClaimCompletedKey)
        syncAfterSave()
        dprint("[CloudKitSync] This device claimed Master role")
    }

    // MARK: - Sync API

    /// Call after any SwiftData save that touches synced models.
    /// Scans all records modified since last sync and queues them for upload.
    func syncAfterSave() {
        registerPendingLocalChanges()
    }

    /// Pulls remote changes on demand, throttled to avoid foreground churn.
    /// CKSyncEngine normally relies on silent notifications, but those can lag or be
    /// unavailable during TestFlight/Xcode cross-device testing.
    func fetchRemoteChangesIfNeeded(reason: String, minimumInterval: TimeInterval = 15) async {
        guard !isManualFetchInFlight else { return }
        if let lastManualFetchAt,
           Date().timeIntervalSince(lastManualFetchAt) < minimumInterval {
            return
        }

        isManualFetchInFlight = true
        lastManualFetchAt = Date()
        defer { isManualFetchInFlight = false }

        do {
            SyncDiagnosticsLogger.log("Manual fetch started reason=\(reason)")
            try await syncEngine.fetchChanges()
            lastError = nil
            SyncDiagnosticsLogger.log("Manual fetch completed reason=\(reason)")
            dprint("[CloudKitSync] ✅ Manual fetch completed (\(reason))")
        } catch {
            lastError = error
            if Self.isChangeTokenExpired(error) {
                resetSyncEngineKnowledge(reason: "manual-fetch-change-token-expired")
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    await fetchZoneChangesDeterministicallyIfNeeded(
                        reason: "\(reason)-token-reset",
                        minimumInterval: 0
                    )
                }
            }
            SyncDiagnosticsLogger.log("Manual fetch failed reason=\(reason) error=\(error.localizedDescription)")
            dprint("[CloudKitSync] ❌ Manual fetch failed (\(reason)): \(error)")
        }
    }

    /// Deterministic fallback that bypasses CKSyncEngine subscriptions and asks the
    /// custom zone directly for changes since our own zone token.
    func fetchZoneChangesDeterministicallyIfNeeded(reason: String, minimumInterval: TimeInterval = 20) async {
        guard !isDeterministicFetchInFlight else { return }
        if let lastDeterministicFetchAt,
           Date().timeIntervalSince(lastDeterministicFetchAt) < minimumInterval {
            return
        }

        isDeterministicFetchInFlight = true
        lastDeterministicFetchAt = Date()
        defer { isDeterministicFetchInFlight = false }
        appliedFloorplanMarkerSnapshots.removeAll()

        do {
            SyncDiagnosticsLogger.log("Deterministic zone fetch started reason=\(reason)")
            var token = Self.loadServerChangeToken(forKey: Self.deterministicZoneTokenKey)
            var totalModifications = 0
            var totalDeletions = 0
            var didApplyFloorplanChange = false
            let database = CKContainer(identifier: Self.containerID).privateCloudDatabase

            repeat {
                let result = try await database.recordZoneChanges(
                    inZoneWith: Self.zoneID,
                    since: token,
                    desiredKeys: nil,
                    resultsLimit: 200
                )

                let ctx = modelContainer.mainContext
                for (_, recordResult) in result.modificationResultsByID {
                    guard case .success(let modification) = recordResult else { continue }
                    let record = modification.record
                    totalModifications += 1
                    if record.recordType == "Floorplan" {
                        didApplyFloorplanChange = true
                    }
                    descriptor(for: record.recordID)?.applyRecord(record, ctx)
                }

                for deletion in result.deletions {
                    totalDeletions += 1
                    guard let descriptor = descriptor(for: deletion.recordID) else { continue }
                    if descriptor.recordType == "Floorplan" {
                        didApplyFloorplanChange = true
                        descriptor.deleteRecord(deletion.recordID, ctx)
                        SyncDiagnosticsLogger.log("Applied remote Floorplan deletion record=\(deletion.recordID.recordName)")
                        continue
                    }
                    if descriptor.buildRecord(deletion.recordID, ctx) != nil {
                        addPendingRecordZoneChanges([.saveRecord(deletion.recordID)])
                    }
                }

                try? ctx.save()
                token = result.changeToken
                Self.saveServerChangeToken(result.changeToken, forKey: Self.deterministicZoneTokenKey)
                if !result.moreComing { break }
            } while true

            if totalModifications > 0 || totalDeletions > 0 {
                markSyncCompleted()
            }
            if didApplyFloorplanChange {
                postFloorplanRemoteChangesNotification()
            }
            lastError = nil
            SyncDiagnosticsLogger.log("Deterministic zone fetch completed reason=\(reason) modifications=\(totalModifications) deletions=\(totalDeletions) floorplan=\(didApplyFloorplanChange)")
        } catch {
            lastError = error
            if Self.isChangeTokenExpired(error) {
                UserDefaults.standard.removeObject(forKey: Self.deterministicZoneTokenKey)
                lastDeterministicFetchAt = nil
                SyncDiagnosticsLogger.log("Reset deterministic zone token reason=change-token-expired")
                Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    await fetchZoneChangesDeterministicallyIfNeeded(
                        reason: "\(reason)-token-reset",
                        minimumInterval: 0
                    )
                }
            }
            SyncDiagnosticsLogger.log("Deterministic zone fetch failed reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    /// Marks the singleton settings record as locally changed so UserDefaults-backed
    /// preferences included in the CKRecord are uploaded on the next send cycle.
    func markSettingsNeedsSync() {
        guard !isApplyingRemoteSettings else { return }

        let context = ModelContext(modelContainer)
        guard let settings = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return
        }
        settings.modifiedAt = .now
        try? context.save()
        syncAfterSave()
    }

    /// On the Primary device, runtime UserDefaults/AISettings are the source of truth.
    /// Rewrites the sync singleton from runtime state so stale stored settings do not
    /// overwrite the Primary on launch.
    func updateSettingsFromRuntime(
        aiSettings: AISettings,
        securityMonitoredUUIDsRaw: String
    ) {
        let context = ModelContext(modelContainer)
        guard let settings = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return
        }

        if settings.masterDeviceID.isEmpty {
            guard hasCompletedInitialSync,
                  !UserDefaults.standard.bool(forKey: Self.automaticMasterClaimCompletedKey)
            else { return }
            settings.masterDeviceID = DeviceIdentity.id
            UserDefaults.standard.set(true, forKey: Self.automaticMasterClaimCompletedKey)
        } else {
            guard settings.masterDeviceID == DeviceIdentity.id else { return }
            UserDefaults.standard.set(true, forKey: Self.automaticMasterClaimCompletedKey)
        }

        settings.aiProviderRaw             = aiSettings.selectedProvider.rawValue
        settings.aiIsEnabled               = aiSettings.isAIEnabled
        settings.aiSuggestionsEnabled      = aiSettings.suggestionsEnabled
        settings.aiAnomalyDetectionEnabled = aiSettings.anomalyDetectionEnabled
        settings.aiRuleEngineEnabled       = aiSettings.ruleEngineEnabled
        settings.aiHasDataConsent          = aiSettings.hasAIDataConsent
        settings.securityMonitoredUUIDsRaw = securityMonitoredUUIDsRaw
        settings.modifiedAt = .now

        try? context.save()
        syncAfterSave()
        dprint("[CloudKitSync] Updated settings from Primary runtime ai=\(settings.aiIsEnabled) master=\(settings.masterDeviceID)")
    }

    /// Applies the locally stored SyncableSettings singleton into runtime UserDefaults-backed services.
    /// This covers installs where CKSyncEngine already fetched the record before the runtime bridge existed.
    func applyStoredSettingsToRuntime() {
        let context = ModelContext(modelContainer)
        guard let settings = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return
        }
        guard !settings.masterDeviceID.isEmpty, settings.masterDeviceID != DeviceIdentity.id else {
            return
        }
        isApplyingRemoteSettings = true
        remoteSettingsApplyCallback?(settings)
        isApplyingRemoteSettings = false
        dprint("[CloudKitSync] Applied stored settings ai=\(settings.aiIsEnabled) master=\(settings.masterDeviceID)")
    }

    /// Re-resolves imported floorplan markers against this device's HomeKit accessory UUIDs.
    /// Useful when CloudKit records arrive before HomeKit has finished loading on a slave device.
    func remapPlacedAccessoriesToLocalHomeKitIDs() {
        guard let accessoryUUIDResolver else { return }

        let context = ModelContext(modelContainer)
        let floorplans = (try? context.fetch(FetchDescriptor<Floorplan>())) ?? []
        var didChange = false

        for floorplan in floorplans {
            for placed in floorplan.accessories {
                let cachedIdentity = cachedMarkerIdentities[placed.id.uuidString]
                guard let localUUID = accessoryUUIDResolver(
                    placed.homeKitAccessoryUUID,
                    cachedIdentity?.accessoryName ?? placed.customLabel,
                    cachedIdentity?.roomName
                ),
                      localUUID != placed.homeKitAccessoryUUID
                else { continue }

                placed.homeKitAccessoryUUID = localUUID
                didChange = true
            }
        }

        guard didChange else { return }
        try? context.save()
        dprint("[CloudKitSync] Remapped floorplan markers to local HomeKit accessory IDs")
    }

    /// Re-resolves synced floorplan linked-room UUIDs against this device's HomeKit rooms.
    /// CloudKit shares the drawn floorplan, but HMRoom.uniqueIdentifier can differ per HomeKit graph.
    func remapLinkedRoomsToLocalHomeKitIDs() {
        guard let roomUUIDResolver else { return }

        let context = ModelContext(modelContainer)
        let floorplans = (try? context.fetch(FetchDescriptor<Floorplan>())) ?? []
        var didChange = false

        for floorplan in floorplans {
            let roomIDMap = remapLinkedRooms(on: floorplan)
            guard !roomIDMap.isEmpty else { continue }
            didChange = true

            for marker in floorplan.accessories {
                if let linkedRoomUUID = marker.linkedRoomUUID,
                   let localRoomUUID = roomIDMap[linkedRoomUUID] {
                    marker.linkedRoomUUID = localRoomUUID
                    didChange = true
                } else if let localRoomUUID = FloorplanRoomMatcher.linkedRoomID(
                    containing: marker.position,
                    in: floorplan.linkedRooms
                ), marker.linkedRoomUUID != localRoomUUID {
                    marker.linkedRoomUUID = localRoomUUID
                    didChange = true
                }
            }
        }

        guard didChange else { return }
        try? context.save()
        dprint("[CloudKitSync] Remapped floorplan linked rooms to local HomeKit room IDs")
    }

    /// Must be called before or right after the SwiftData delete — once the record is gone
    /// from SwiftData, registerPendingLocalChanges() can no longer detect it.
    func markFloorplanDeleted(_ id: UUID) {
        addPendingRecordZoneChanges([.deleteRecord(floorplanRecordID(id))])
    }

    /// Queues a floorplan upload explicitly after a local edit.
    /// This avoids relying only on updatedAt > lastSyncedAt, which can be fragile on
    /// devices that just applied remote changes and then immediately save locally.
    func markFloorplanNeedsSync(_ id: UUID) {
        addPendingRecordZoneChanges([.saveRecord(floorplanRecordID(id))])
    }

    func markOpportunityDeleted(_ id: UUID) {
        addPendingRecordZoneChanges([.deleteRecord(opportunityRecordID(id))])
    }

    func markThresholdDeleted(_ id: UUID) {
        var synced = syncedThresholdIDs
        synced.remove(id.uuidString)
        syncedThresholdIDs = synced
        addPendingRecordZoneChanges([.deleteRecord(thresholdRecordID(id))])
    }

    /// Call when the user modifies an existing threshold in AlertThresholdSettingsView.
    /// Removes it from the "already synced" cache so registerPendingLocalChanges re-queues it.
    func markThresholdNeedsSync(_ id: UUID) {
        var synced = syncedThresholdIDs
        synced.remove(id.uuidString)
        syncedThresholdIDs = synced
        syncAfterSave()
    }

    /// Scans all synced model types for changes since last sync and queues them for upload.
    /// Called at launch, on account sign-in, and via syncAfterSave().
    func registerPendingLocalChanges() {
        let ctx    = ModelContext(modelContainer)
        let cutoff = lastSyncedAt ?? .distantPast
        var changes = syncDescriptors.flatMap { $0.pendingChanges(ctx, cutoff) }
        changes.append(contentsOf: markerBackfillChangesIfNeeded(context: ctx))

        guard !changes.isEmpty else { return }
        addPendingRecordZoneChanges(changes)
        dprint("[CloudKitSync] Registered \(changes.count) pending change(s)")
    }

    private func markerBackfillChangesIfNeeded(context: ModelContext) -> [CKSyncEngine.PendingRecordZoneChange] {
        guard !UserDefaults.standard.bool(forKey: Self.markerBackfillQueuedKey) else { return [] }

        let floorplans = (try? context.fetch(FetchDescriptor<Floorplan>())) ?? []
        let changes = floorplans
            .filter { !$0.accessories.isEmpty }
            .map { CKSyncEngine.PendingRecordZoneChange.saveRecord(floorplanRecordID($0.id)) }

        UserDefaults.standard.set(true, forKey: Self.markerBackfillQueuedKey)
        if !changes.isEmpty {
            dprint("[CloudKitSync] Queued marker backfill for \(changes.count) floorplan(s)")
        }
        return changes
    }

    // MARK: - Record ID Helpers

    private func floorplanRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.floorplanPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func settingsRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.settingsPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func opportunityRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.opportunityPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func thresholdRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.thresholdPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func insightRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.insightPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func behaviorRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.behaviorPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func habitRecordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(Self.habitPrefix)\(id.uuidString)", zoneID: Self.zoneID)
    }

    private func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) {
        let existing = Set(syncEngine.state.pendingRecordZoneChanges)
        let uniqueChanges = changes.filter { !existing.contains($0) }
        guard !uniqueChanges.isEmpty else { return }
        syncEngine.state.add(pendingRecordZoneChanges: uniqueChanges)
        SyncDiagnosticsLogger.log("Queued \(uniqueChanges.count) pending record change(s)")
    }

    private var syncDescriptors: [CloudKitSyncDescriptor] {
        [
            floorplanDescriptor,
            settingsDescriptor,
            opportunityDescriptor,
            thresholdDescriptor,
            behaviorDescriptor,
            habitDescriptor
        ]
    }

    private func descriptor(for recordID: CKRecord.ID) -> CloudKitSyncDescriptor? {
        syncDescriptors.first { $0.matches(recordID) }
    }

    private func isAISyncEnabled(context: ModelContext) -> Bool {
        guard let settings = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return false
        }
        return settings.aiIsEnabled && settings.aiHasDataConsent
    }
}

// MARK: - Sync Descriptors

private extension CloudKitSyncService {

    var floorplanDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "Floorplan",
            recordPrefix: Self.floorplanPrefix,
            pendingChanges: { [self] context, cutoff in
                let floorplans = (try? context.fetch(FetchDescriptor<Floorplan>())) ?? []
                return floorplans
                    .filter { $0.updatedAt > (cutoff ?? .distantPast) }
                    .map { .saveRecord(floorplanRecordID($0.id)) }
            },
            buildRecord: { [self] recordID, context in
                guard let id = uuid(from: recordID, prefix: Self.floorplanPrefix) else { return nil }
                let descriptor = FetchDescriptor<Floorplan>(predicate: #Predicate { $0.id == id })
                guard let fp = (try? context.fetch(descriptor))?.first else { return nil }
                return fp.toCKRecord(
                    recordID: recordID,
                    accessorySnapshotProvider: accessorySnapshotProvider,
                    iconOverrideProvider: markerIconOverrideProvider
                )
            },
            applyRecord: { [self] record, context in
                applyFloorplanRecord(record, context: context)
            },
            deleteRecord: { [self] recordID, context in
                deleteFloorplanRecord(name: recordID.recordName, context: context)
            },
            overlayLocalFields: { [self] serverRecord, context in
                guard let id = uuid(from: serverRecord.recordID, prefix: Self.floorplanPrefix) else { return }
                let descriptor = FetchDescriptor<Floorplan>(predicate: #Predicate { $0.id == id })
                guard let fp = (try? context.fetch(descriptor))?.first else { return }
                overlayFields(
                    from: fp.toCKRecord(
                        recordID: serverRecord.recordID,
                        accessorySnapshotProvider: accessorySnapshotProvider,
                        iconOverrideProvider: markerIconOverrideProvider
                    ),
                    to: serverRecord
                )
            },
            markSavedRecord: { _ in }
        )
    }

    var settingsDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "SyncableSettings",
            recordPrefix: Self.settingsPrefix,
            pendingChanges: { [self] context, cutoff in
                guard let s = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
                    return []
                }
                if s.masterDeviceID.isEmpty {
                    guard hasCompletedInitialSync, s.modifiedAt > (cutoff ?? .distantPast) else {
                        return []
                    }
                } else if s.masterDeviceID != DeviceIdentity.id {
                    return []
                }
                return [.saveRecord(settingsRecordID(s.id))]
            },
            buildRecord: { [self] recordID, context in
                guard let s = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else { return nil }
                if s.masterDeviceID.isEmpty {
                    guard hasCompletedInitialSync else { return nil }
                } else if s.masterDeviceID != DeviceIdentity.id {
                    return nil
                }
                return buildSettingsRecord(s, recordID: recordID)
            },
            applyRecord: { [self] record, context in
                applySettingsRecord(record, context: context)
            },
            deleteRecord: { _, _ in },
            overlayLocalFields: { [self] serverRecord, context in
                guard let s = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else { return }
                guard s.masterDeviceID.isEmpty || s.masterDeviceID == DeviceIdentity.id else { return }
                let serverMasterID = serverRecord["masterDeviceID"] as? String ?? ""
                overlayFields(from: buildSettingsRecord(s, recordID: serverRecord.recordID), to: serverRecord)
                if s.masterDeviceID.isEmpty && !serverMasterID.isEmpty {
                    serverRecord["masterDeviceID"] = serverMasterID
                }
            },
            markSavedRecord: { _ in }
        )
    }

    var opportunityDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "AutomationOpportunity",
            recordPrefix: Self.opportunityPrefix,
            pendingChanges: { [self] context, cutoff in
                let opportunities = (try? context.fetch(FetchDescriptor<AutomationOpportunity>())) ?? []
                return opportunities
                    .filter { $0.modifiedAt > (cutoff ?? .distantPast) }
                    .map { .saveRecord(opportunityRecordID($0.id)) }
            },
            buildRecord: { [self] recordID, context in
                guard let id = uuid(from: recordID, prefix: Self.opportunityPrefix) else { return nil }
                let descriptor = FetchDescriptor<AutomationOpportunity>(predicate: #Predicate { $0.id == id })
                guard let opp = (try? context.fetch(descriptor))?.first else { return nil }
                return opp.toCKRecord(recordID: recordID)
            },
            applyRecord: { [self] record, context in
                applyOpportunityRecord(record, context: context)
            },
            deleteRecord: { [self] recordID, context in
                deleteOpportunityRecord(name: recordID.recordName, context: context)
            },
            overlayLocalFields: { [self] serverRecord, context in
                guard let id = uuid(from: serverRecord.recordID, prefix: Self.opportunityPrefix) else { return }
                let descriptor = FetchDescriptor<AutomationOpportunity>(predicate: #Predicate { $0.id == id })
                guard let opp = (try? context.fetch(descriptor))?.first else { return }
                overlayFields(from: opp.toCKRecord(recordID: serverRecord.recordID), to: serverRecord)
            },
            markSavedRecord: { _ in }
        )
    }

    var thresholdDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "SensorAlertThreshold",
            recordPrefix: Self.thresholdPrefix,
            pendingChanges: { [self] context, _ in
                let synced = syncedThresholdIDs
                let thresholds = (try? context.fetch(FetchDescriptor<SensorAlertThreshold>())) ?? []
                return thresholds
                    .filter { !synced.contains($0.id.uuidString) }
                    .map { .saveRecord(thresholdRecordID($0.id)) }
            },
            buildRecord: { [self] recordID, context in
                guard let id = uuid(from: recordID, prefix: Self.thresholdPrefix) else { return nil }
                let descriptor = FetchDescriptor<SensorAlertThreshold>(predicate: #Predicate { $0.id == id })
                guard let threshold = (try? context.fetch(descriptor))?.first else { return nil }
                return threshold.toCKRecord(recordID: recordID)
            },
            applyRecord: { [self] record, context in
                applyThresholdRecord(record, context: context)
            },
            deleteRecord: { [self] recordID, context in
                deleteThresholdRecord(name: recordID.recordName, context: context)
            },
            overlayLocalFields: { [self] serverRecord, context in
                guard let id = uuid(from: serverRecord.recordID, prefix: Self.thresholdPrefix) else { return }
                let descriptor = FetchDescriptor<SensorAlertThreshold>(predicate: #Predicate { $0.id == id })
                guard let threshold = (try? context.fetch(descriptor))?.first else { return }
                overlayFields(from: threshold.toCKRecord(recordID: serverRecord.recordID), to: serverRecord)
            },
            markSavedRecord: { [self] record in
                var synced = syncedThresholdIDs
                synced.insert(String(record.recordID.recordName.dropFirst(Self.thresholdPrefix.count)))
                syncedThresholdIDs = synced
            }
        )
    }

    var insightDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "PersistedInsight",
            recordPrefix: Self.insightPrefix,
            pendingChanges: { [self] context, cutoff in
                guard isAISyncEnabled(context: context) else { return [] }
                let insights = (try? context.fetch(FetchDescriptor<PersistedInsight>())) ?? []
                return insights
                    .filter { $0.generatedAt > (cutoff ?? .distantPast) }
                    .map { .saveRecord(insightRecordID($0.id)) }
            },
            buildRecord: { [self] recordID, context in
                guard isAISyncEnabled(context: context),
                      let id = uuid(from: recordID, prefix: Self.insightPrefix)
                else { return nil }
                let descriptor = FetchDescriptor<PersistedInsight>(predicate: #Predicate { $0.id == id })
                guard let insight = (try? context.fetch(descriptor))?.first else { return nil }
                return insight.toCKRecord(recordID: recordID)
            },
            applyRecord: { [self] record, context in
                guard isAISyncEnabled(context: context) else { return }
                applyInsightRecord(record, context: context)
            },
            deleteRecord: { _, _ in },
            overlayLocalFields: { [self] serverRecord, context in
                guard isAISyncEnabled(context: context),
                      let id = uuid(from: serverRecord.recordID, prefix: Self.insightPrefix)
                else { return }
                let descriptor = FetchDescriptor<PersistedInsight>(predicate: #Predicate { $0.id == id })
                guard let insight = (try? context.fetch(descriptor))?.first else { return }
                overlayFields(from: insight.toCKRecord(recordID: serverRecord.recordID), to: serverRecord)
            },
            markSavedRecord: { _ in }
        )
    }

    var behaviorDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "PersistedBehavioralPattern",
            recordPrefix: Self.behaviorPrefix,
            pendingChanges: { [self] context, cutoff in
                guard isAISyncEnabled(context: context) else { return [] }
                let patterns = (try? context.fetch(FetchDescriptor<PersistedBehavioralPattern>())) ?? []
                return patterns
                    .filter { $0.modifiedAt > (cutoff ?? .distantPast) }
                    .map { .saveRecord(behaviorRecordID($0.id)) }
            },
            buildRecord: { [self] recordID, context in
                guard isAISyncEnabled(context: context),
                      let id = uuid(from: recordID, prefix: Self.behaviorPrefix)
                else { return nil }
                let descriptor = FetchDescriptor<PersistedBehavioralPattern>(predicate: #Predicate { $0.id == id })
                guard let pattern = (try? context.fetch(descriptor))?.first else { return nil }
                return pattern.toCKRecord(recordID: recordID)
            },
            applyRecord: { [self] record, context in
                guard isAISyncEnabled(context: context) else { return }
                applyBehaviorRecord(record, context: context)
            },
            deleteRecord: { _, _ in },
            overlayLocalFields: { [self] serverRecord, context in
                guard isAISyncEnabled(context: context),
                      let id = uuid(from: serverRecord.recordID, prefix: Self.behaviorPrefix)
                else { return }
                let descriptor = FetchDescriptor<PersistedBehavioralPattern>(predicate: #Predicate { $0.id == id })
                guard let pattern = (try? context.fetch(descriptor))?.first else { return }
                overlayFields(from: pattern.toCKRecord(recordID: serverRecord.recordID), to: serverRecord)
            },
            markSavedRecord: { _ in }
        )
    }

    var habitDescriptor: CloudKitSyncDescriptor {
        CloudKitSyncDescriptor(
            recordType: "HabitPattern",
            recordPrefix: Self.habitPrefix,
            pendingChanges: { [self] context, cutoff in
                guard isAISyncEnabled(context: context) else { return [] }
                let habits = (try? context.fetch(FetchDescriptor<HabitPattern>())) ?? []
                return habits
                    .filter { $0.modifiedAt > (cutoff ?? .distantPast) }
                    .map { .saveRecord(habitRecordID($0.id)) }
            },
            buildRecord: { [self] recordID, context in
                guard isAISyncEnabled(context: context),
                      let id = uuid(from: recordID, prefix: Self.habitPrefix)
                else { return nil }
                let descriptor = FetchDescriptor<HabitPattern>(predicate: #Predicate { $0.id == id })
                guard let habit = (try? context.fetch(descriptor))?.first else { return nil }
                return habit.toCKRecord(recordID: recordID)
            },
            applyRecord: { [self] record, context in
                guard isAISyncEnabled(context: context) else { return }
                applyHabitRecord(record, context: context)
            },
            deleteRecord: { _, _ in },
            overlayLocalFields: { [self] serverRecord, context in
                guard isAISyncEnabled(context: context),
                      let id = uuid(from: serverRecord.recordID, prefix: Self.habitPrefix)
                else { return }
                let descriptor = FetchDescriptor<HabitPattern>(predicate: #Predicate { $0.id == id })
                guard let habit = (try? context.fetch(descriptor))?.first else { return }
                overlayFields(from: habit.toCKRecord(recordID: serverRecord.recordID), to: serverRecord)
            },
            markSavedRecord: { _ in }
        )
    }

    func uuid(from recordID: CKRecord.ID, prefix: String) -> UUID? {
        UUID(uuidString: String(recordID.recordName.dropFirst(prefix.count)))
    }

    func overlayFields(from fresh: CKRecord, to serverRecord: CKRecord) {
        for key in fresh.allKeys() {
            serverRecord[key] = fresh[key]
        }
    }

    func buildSettingsRecord(_ settings: SyncableSettings, recordID: CKRecord.ID) -> CKRecord {
        let record = settings.toCKRecord(recordID: recordID)
        addUserPreferences(to: record)

        let monitoredIDs = settings.securityMonitoredUUIDsRaw
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) }

        let snapshots = monitoredIDs.map { uuid in
            let identity = accessorySnapshotProvider?(uuid)
            return SecurityMonitoredAccessorySnapshot(
                homeKitAccessoryUUID: uuid,
                accessoryName: identity?.name,
                roomName: identity?.roomName
            )
        }

        if let data = try? JSONEncoder().encode(snapshots) {
            record[Self.securityMonitoredAccessoriesField] = data
        }
        return record
    }

    func addUserPreferences(to record: CKRecord) {
        let defaults = UserDefaults.standard

        for (recordKey, field) in Self.syncedUserPreferenceFields {
            switch field {
            case .string(let defaultsKey):
                guard let value = defaults.string(forKey: defaultsKey) else { continue }
                record[recordKey] = value
            case .bool(let defaultsKey):
                guard defaults.object(forKey: defaultsKey) != nil else { continue }
                record[recordKey] = NSNumber(value: defaults.bool(forKey: defaultsKey))
            case .double(let defaultsKey):
                guard defaults.object(forKey: defaultsKey) != nil else { continue }
                record[recordKey] = NSNumber(value: defaults.double(forKey: defaultsKey))
            }
        }
    }

    func applyUserPreferences(from record: CKRecord) {
        let defaults = UserDefaults.standard

        for (recordKey, field) in Self.syncedUserPreferenceFields {
            guard let value = record[recordKey] else { continue }

            switch field {
            case .string(let defaultsKey):
                if let string = value as? String {
                    defaults.set(string, forKey: defaultsKey)
                }
            case .bool(let defaultsKey):
                if let number = value as? NSNumber {
                    defaults.set(number.boolValue, forKey: defaultsKey)
                }
            case .double(let defaultsKey):
                if let number = value as? NSNumber {
                    defaults.set(number.doubleValue, forKey: defaultsKey)
                }
            }
        }
    }

    func remappedSecurityMonitoredUUIDsRaw(from record: CKRecord, fallbackRaw: String) -> String {
        guard let data = record[Self.securityMonitoredAccessoriesField] as? Data,
              let snapshots = try? JSONDecoder().decode([SecurityMonitoredAccessorySnapshot].self, from: data),
              !snapshots.isEmpty
        else { return fallbackRaw }

        let localUUIDs = snapshots.map { snapshot in
            accessoryUUIDResolver?(
                snapshot.homeKitAccessoryUUID,
                snapshot.accessoryName,
                snapshot.roomName
            ) ?? snapshot.homeKitAccessoryUUID
        }

        return localUUIDs.map(\.uuidString).joined(separator: ",")
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudKitSyncService: CKSyncEngineDelegate {

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {

        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { change in
            let recordID: CKRecord.ID
            switch change {
            case .saveRecord(let id):   recordID = id
            case .deleteRecord(let id): recordID = id
            @unknown default: return false
            }
            switch scope {
            case .all:
                return true
            case .allExcluding(let excluded):
                return !excluded.contains(recordID.zoneID)
            case .zoneIDs(let zoneIDs):
                return zoneIDs.contains(recordID.zoneID)
            case .recordIDs(let recordIDs):
                return recordIDs.contains(recordID)
            @unknown default:
                return false
            }
        }
        guard !pending.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [self] recordID in
            await self.buildCKRecord(for: recordID)
        }
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await processEvent(event)
    }
}

// MARK: - Event Processing

private extension CloudKitSyncService {

    func processEvent(_ event: CKSyncEngine.Event) async {
        switch event {

        case .stateUpdate(let e):
            if let data = try? JSONEncoder().encode(e.stateSerialization) {
                UserDefaults.standard.set(data, forKey: Self.engineStateKey)
            }

        case .accountChange(let e):
            handleAccountChange(e)

        case .fetchedRecordZoneChanges(let e):
            applyFetchedChanges(e)

        case .didFetchRecordZoneChanges(let e):
            handleDidFetchRecordZoneChanges(e)

        case .sentDatabaseChanges(let e):
            handleSentDatabaseChanges(e)

        case .sentRecordZoneChanges(let e):
            await handleSentChanges(e)

        case .willFetchChanges, .willSendChanges:
            isSyncing = true

        case .didFetchChanges:
            isSyncing = false
            if !hasCompletedInitialSync { hasCompletedInitialSync = true }

        case .didSendChanges:
            isSyncing = false

        default:
            break
        }
    }

    func handleDidFetchRecordZoneChanges(_ e: CKSyncEngine.Event.DidFetchRecordZoneChanges) {
        guard let error = e.error else { return }

        lastError = error
        SyncDiagnosticsLogger.log(
            "CKSyncEngine zone fetch failed zone=\(e.zoneID.zoneName) error=\(error.localizedDescription)"
        )

        guard Self.isChangeTokenExpired(error) else { return }

        resetSyncEngineKnowledge(reason: "cksyncengine-zone-change-token-expired")
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await fetchZoneChangesDeterministicallyIfNeeded(
                reason: "cksyncengine-token-reset",
                minimumInterval: 0
            )
        }
    }

    func handleAccountChange(_ e: CKSyncEngine.Event.AccountChange) {
        switch e.changeType {
        case .signIn:
            dprint("[CloudKitSync] iCloud sign-in detected — registering pending changes")
            registerPendingLocalChanges()
        case .signOut, .switchAccounts:
            // Clear stored engine state so the next sign-in starts fresh
            UserDefaults.standard.removeObject(forKey: Self.engineStateKey)
            UserDefaults.standard.removeObject(forKey: Self.lastSyncedKey)
            UserDefaults.standard.removeObject(forKey: Self.zoneCreatedKey)
            UserDefaults.standard.removeObject(forKey: Self.syncedThresholdIDsKey)
            lastSyncedAt = nil
            dprint("[CloudKitSync] iCloud account change — sync state cleared")
        @unknown default:
            break
        }
    }

    func applyFetchedChanges(_ e: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        let ctx = modelContainer.mainContext
        appliedFloorplanMarkerSnapshots.removeAll()
        var didApplyFloorplanChange = false
        let modifiedTypes = Dictionary(grouping: e.modifications.map { $0.record.recordType }, by: { $0 })
            .mapValues(\.count)
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        SyncDiagnosticsLogger.log("Fetched zone changes modifications=\(e.modifications.count) deletions=\(e.deletions.count) types=[\(modifiedTypes)]")

        for mod in e.modifications {
            let record = mod.record
            if record.recordType == "Floorplan" {
                didApplyFloorplanChange = true
            }
            descriptor(for: record.recordID)?.applyRecord(record, ctx)
        }

        for deletion in e.deletions {
            guard let descriptor = descriptor(for: deletion.recordID) else { continue }
            if descriptor.recordType == "Floorplan" {
                didApplyFloorplanChange = true
                descriptor.deleteRecord(deletion.recordID, ctx)
                SyncDiagnosticsLogger.log("Applied remote Floorplan deletion record=\(deletion.recordID.recordName)")
                continue
            }
            if descriptor.buildRecord(deletion.recordID, ctx) != nil {
                addPendingRecordZoneChanges([.saveRecord(deletion.recordID)])
                dprint("[CloudKitSync] Remote deletion ignored locally and re-queued: \(deletion.recordID.recordName)")
            }
        }

        try? ctx.save()
        if !e.modifications.isEmpty || !e.deletions.isEmpty {
            markSyncCompleted()
        }
        if didApplyFloorplanChange {
            postFloorplanRemoteChangesNotification()
            SyncDiagnosticsLogger.log("Posted floorplan remote-change notification")
        }
        dprint("[CloudKitSync] Applied \(e.modifications.count) modification(s), \(e.deletions.count) deletion(s)")
    }

    func handleSentDatabaseChanges(_ e: CKSyncEngine.Event.SentDatabaseChanges) {
        if e.savedZones.contains(where: { $0.zoneID == Self.zoneID }) {
            UserDefaults.standard.set(true, forKey: Self.zoneCreatedKey)
            dprint("[CloudKitSync] ✅ Zone created: \(Self.zoneID.zoneName)")
        }
        for failure in e.failedZoneSaves {
            dprint("[CloudKitSync] ❌ Zone save failed: \(failure.error)")
            lastError = failure.error
        }
    }

    func handleSentChanges(_ e: CKSyncEngine.Event.SentRecordZoneChanges) async {
        // Zone was deleted externally or never created — re-queue zone + failed records
        let zoneNotFoundIDs = e.failedRecordSaves.compactMap { f -> CKRecord.ID? in
            (f.error.code == .zoneNotFound) ? f.record.recordID : nil
        }
        if !zoneNotFoundIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.zoneCreatedKey)
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            addPendingRecordZoneChanges(zoneNotFoundIDs.map { .saveRecord($0) })
            dprint("[CloudKitSync] ⚠️ Zone not found (\(zoneNotFoundIDs.count) records) — re-scheduled zone + records")
            return
        }

        // "Server Record Changed" (code 14): the record already exists on CloudKit but our
        // engine state has no etag (e.g. after reinstall or engine state loss). Fix: take the
        // server record from the error (it carries the correct etag), overlay our local field
        // values, cache it, and re-add to pending. The next nextRecordZoneChangeBatch call will
        // return this record — CloudKit accepts it because the etag now matches.
        let conflictFailures = e.failedRecordSaves.filter { $0.error.code == .serverRecordChanged }
        if !conflictFailures.isEmpty {
            let ctx = ModelContext(modelContainer)
            let failedChanges = conflictFailures.map { CKSyncEngine.PendingRecordZoneChange.saveRecord($0.record.recordID) }
            syncEngine.state.remove(pendingRecordZoneChanges: failedChanges)

            var retryChanges: [CKSyncEngine.PendingRecordZoneChange] = []
            for failure in conflictFailures {
                let recordID = failure.record.recordID
                let serverRecord = if let errorServerRecord = failure.error.serverRecord {
                    errorServerRecord
                } else {
                    await fetchServerRecord(recordID)
                }
                guard let serverRecord else {
                    retryChanges.append(.saveRecord(recordID))
                    continue
                }
                applyLocalFields(to: serverRecord, context: ctx)
                conflictResolutionRecords[serverRecord.recordID] = serverRecord
                retryChanges.append(.saveRecord(serverRecord.recordID))
            }
            addPendingRecordZoneChanges(retryChanges)
            dprint("[CloudKitSync] ⚠️ \(conflictFailures.count) conflict(s) — re-queued with server etag")
        }

        let otherFailures = e.failedRecordSaves.filter {
            $0.error.code != .zoneNotFound && $0.error.code != .serverRecordChanged
        }
        if !otherFailures.isEmpty {
            lastError = otherFailures.first?.error
            for f in otherFailures {
                dprint("[CloudKitSync] ❌ \(f.record.recordID.recordName): \(f.error)")
            }
            return
        }
        // Mark successfully uploaded threshold records as synced so they're not re-queued next launch.
        if !e.savedRecords.isEmpty {
            for record in e.savedRecords {
                descriptor(for: record.recordID)?.markSavedRecord(record)
            }
        }
        markSyncCompleted()
        let savedTypes = Dictionary(grouping: e.savedRecords.map(\.recordType), by: { $0 })
            .mapValues(\.count)
            .map { "\($0.key):\($0.value)" }
            .sorted()
            .joined(separator: ",")
        SyncDiagnosticsLogger.log("Sent zone changes saved=\(e.savedRecords.count) deleted=\(e.deletedRecordIDs.count) types=[\(savedTypes)]")
        dprint("[CloudKitSync] ✅ Sent \(e.savedRecords.count) record(s), deleted \(e.deletedRecordIDs.count)")
    }

    func markSyncCompleted() {
        lastSyncedAt = Date()
        UserDefaults.standard.set(lastSyncedAt, forKey: Self.lastSyncedKey)
    }

    private func postFloorplanRemoteChangesNotification() {
        let markerSnapshots = appliedFloorplanMarkerSnapshots
        appliedFloorplanMarkerSnapshots.removeAll()

        NotificationCenter.default.post(
            name: .floorplansDidApplyRemoteChanges,
            object: nil,
            userInfo: [
                FloorplanRemoteChangeNotification.markerSnapshotsByFloorplanIDKey: markerSnapshots
            ]
        )
    }

    func fetchServerRecord(_ recordID: CKRecord.ID) async -> CKRecord? {
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        return await withCheckedContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, _ in
                continuation.resume(returning: record)
            }
        }
    }
}

// MARK: - CKRecord Builder

private extension CloudKitSyncService {

    func buildCKRecord(for recordID: CKRecord.ID) async -> CKRecord? {
        // Conflict-resolved retry: return the cached server record (correct etag) if present.
        if let resolved = conflictResolutionRecords.removeValue(forKey: recordID) {
            return resolved
        }
        let ctx = ModelContext(modelContainer)
        guard let descriptor = descriptor(for: recordID),
              let localRecord = descriptor.buildRecord(recordID, ctx)
        else { return nil }

        // Local-first reconciliation: if the record already exists on CloudKit but this
        // CKSyncEngine state has no system fields/etag, sending `localRecord` would be an
        // insert and fail with "record to insert already exists". Fetch the server record,
        // preserve its etag, and overlay the local fields so the send is an update.
        guard let serverRecord = await fetchServerRecord(recordID) else {
            return localRecord
        }
        descriptor.overlayLocalFields(serverRecord, ctx)
        return serverRecord
    }

    /// Overlays local SwiftData field values onto a server-provided CKRecord,
    /// preserving the server record's recordChangeTag (etag). Used for conflict resolution.
    private func applyLocalFields(to serverRecord: CKRecord, context: ModelContext) {
        descriptor(for: serverRecord.recordID)?.overlayLocalFields(serverRecord, context)
    }
}

// MARK: - Apply Remote Records

private extension CloudKitSyncService {

    func applyFloorplanRecord(_ record: CKRecord, context: ModelContext) {
        guard let uuidStr = record.recordID.recordName
            .split(separator: ":", maxSplits: 1).last.map(String.init),
              let id = UUID(uuidString: uuidStr)
        else { return }

        let remoteUpdatedAt = record["updatedAt"] as? Date ?? .distantPast
        let hasAccessorySnapshot = record["placedAccessoriesJSON"] != nil
        let descriptor = FetchDescriptor<Floorplan>(predicate: #Predicate { $0.id == id })

        if let existing = (try? context.fetch(descriptor))?.first {
            guard remoteUpdatedAt > existing.updatedAt || hasAccessorySnapshot else { return }
            populateFloorplanFields(existing, from: record, context: context)
        } else {
            let fp = Floorplan(name: record["name"] as? String ?? "Untitled")
            fp.id = id
            fp.createdAt = record["createdAt"] as? Date ?? .now
            context.insert(fp)
            populateFloorplanFields(fp, from: record, context: context)
        }
    }

    func populateFloorplanFields(_ fp: Floorplan, from record: CKRecord, context: ModelContext) {
        fp.name                        = record["name"] as? String ?? fp.name
        fp.updatedAt                   = record["updatedAt"] as? Date ?? fp.updatedAt
        fp.tapModeRaw                  = record["tapModeRaw"] as? String ?? fp.tapModeRaw
        fp.exteriorFillColorIndex      = record["exteriorFillColorIndex"] as? Int ?? fp.exteriorFillColorIndex
        fp.drawingVisualExportStyleRaw = record["drawingVisualExportStyleRaw"] as? String ?? fp.drawingVisualExportStyleRaw
        fp.drawingExportRotationRaw    = record["drawingExportRotationRaw"] as? String ?? fp.drawingExportRotationRaw
        fp.homeUUID                    = (record["homeUUID"] as? String).flatMap(UUID.init)
        fp.linkedRoomsJSON             = record["linkedRoomsJSON"] as? Data
        let roomIDMap                  = remapLinkedRooms(on: fp)

        if let asset = record["imageData"] as? CKAsset,
           let url   = asset.fileURL,
           let data  = try? Data(contentsOf: url) {
            if let filename = try? ImageStorageService.saveData(data) {
                fp.imageFilename = filename
                fp.imageData = nil
            }
        }
        if let asset = record["drawingDocumentJSON"] as? CKAsset,
           let url   = asset.fileURL,
           let data  = try? Data(contentsOf: url) {
            fp.drawingDocumentJSON = data
        }

        // Markers: full replace from remote snapshot (remote is always authoritative
        // since the whole Floorplan record is last-write-wins on updatedAt).
        if let data = record["placedAccessoriesJSON"] as? Data,
           let snapshots = try? JSONDecoder().decode([PlacedAccessorySnapshot].self, from: data) {
            dprint("[CloudKitSync] Applying \(snapshots.count) marker snapshot(s) to floorplan \(fp.name)")
            appliedFloorplanMarkerSnapshots[fp.id] = snapshots
            applyAccessorySnapshots(snapshots, to: fp, roomIDMap: roomIDMap, context: context)
        }
    }

    private func applyAccessorySnapshots(
        _ snapshots: [PlacedAccessorySnapshot],
        to fp: Floorplan,
        roomIDMap: [UUID: UUID],
        context: ModelContext
    ) {
        let existingByID = Dictionary(uniqueKeysWithValues: fp.accessories.map { ($0.id, $0) })
        let incomingIDs  = Set(snapshots.map { $0.id })

        // Delete markers no longer in the remote record
        for placed in fp.accessories where !incomingIDs.contains(placed.id) {
            fp.accessories.removeAll { $0.id == placed.id }
            context.delete(placed)
        }

        // Add or update
        var identityCache = cachedMarkerIdentities
        for snap in snapshots {
            if snap.accessoryName != nil || snap.roomName != nil {
                identityCache[snap.id.uuidString] = CachedMarkerIdentity(
                    accessoryName: snap.accessoryName,
                    roomName: snap.roomName
                )
            }

            let localAccessoryUUID = accessoryUUIDResolver?(
                snap.homeKitAccessoryUUID,
                snap.accessoryName,
                snap.roomName
            ) ?? snap.homeKitAccessoryUUID
            let localLinkedRoomUUID = localLinkedRoomUUID(
                from: snap,
                roomIDMap: roomIDMap,
                floorplan: fp
            )
            markerIconOverrideApplyCallback?(localAccessoryUUID, snap.iconOverride)

            if let existing = existingByID[snap.id] {
                if existing.positionX != snap.positionX || existing.positionY != snap.positionY {
                    SyncDiagnosticsLogger.log(
                        "Applied marker move floorplan=\(fp.id.uuidString) marker=\(snap.id.uuidString) old=(\(Self.formatCoordinate(existing.positionX)),\(Self.formatCoordinate(existing.positionY))) new=(\(Self.formatCoordinate(snap.positionX)),\(Self.formatCoordinate(snap.positionY)))"
                    )
                }
                existing.homeKitAccessoryUUID = localAccessoryUUID
                existing.positionX      = snap.positionX
                existing.positionY      = snap.positionY
                existing.linkedRoomUUID = localLinkedRoomUUID
                existing.customLabel    = snap.customLabel
            } else {
                SyncDiagnosticsLogger.log(
                    "Applied marker insert floorplan=\(fp.id.uuidString) marker=\(snap.id.uuidString) position=(\(Self.formatCoordinate(snap.positionX)),\(Self.formatCoordinate(snap.positionY)))"
                )
                let placed = PlacedAccessory(
                    homeKitAccessoryUUID: localAccessoryUUID,
                    position: NormalizedPoint(x: snap.positionX, y: snap.positionY),
                    customLabel:   snap.customLabel,
                    linkedRoomUUID: localLinkedRoomUUID
                )
                placed.id       = snap.id
                placed.floorplan = fp
                context.insert(placed)
                fp.accessories.append(placed)
            }
        }
        cachedMarkerIdentities = identityCache
    }

    private func remapLinkedRooms(on floorplan: Floorplan) -> [UUID: UUID] {
        guard let roomUUIDResolver else { return [:] }

        let currentRooms = floorplan.linkedRooms
        var roomIDMap: [UUID: UUID] = [:]
        var remappedRooms: [LinkedRoom] = []
        var didChange = false

        for room in currentRooms {
            let localRoomUUID = roomUUIDResolver(room.hmRoomUUID, room.name) ?? room.hmRoomUUID
            if localRoomUUID != room.hmRoomUUID {
                roomIDMap[room.hmRoomUUID] = localRoomUUID
                didChange = true
            }

            remappedRooms.append(
                LinkedRoom(
                    hmRoomUUID: localRoomUUID,
                    name: room.name,
                    normalizedRect: room.normalizedRect,
                    normalizedPoints: room.normalizedPoints
                )
            )
        }

        if didChange {
            floorplan.linkedRooms = remappedRooms
        }

        return roomIDMap
    }

    private func localLinkedRoomUUID(
        from snapshot: PlacedAccessorySnapshot,
        roomIDMap: [UUID: UUID],
        floorplan: Floorplan
    ) -> UUID? {
        if let linkedRoomUUID = snapshot.linkedRoomUUID,
           let localRoomUUID = roomIDMap[linkedRoomUUID] {
            return localRoomUUID
        }

        if let linkedRoomUUID = snapshot.linkedRoomUUID,
           floorplan.linkedRooms.contains(where: { $0.hmRoomUUID == linkedRoomUUID }) {
            return linkedRoomUUID
        }

        if let roomName = snapshot.roomName,
           let matchedRoom = floorplan.linkedRooms.first(where: {
               FloorplanRoomMatcher.matches(roomName: roomName, linkedRoom: $0)
           }) {
            return matchedRoom.hmRoomUUID
        }

        let markerPosition = NormalizedPoint(x: snapshot.positionX, y: snapshot.positionY)
        return FloorplanRoomMatcher.linkedRoomID(containing: markerPosition, in: floorplan.linkedRooms)
    }

    func applySettingsRecord(_ record: CKRecord, context: ModelContext) {
        let remoteModifiedAt = record["modifiedAt"] as? Date ?? .distantPast
        let remoteMasterID   = record["masterDeviceID"] as? String ?? ""
        let remoteSecurityMonitoredRaw = remappedSecurityMonitoredUUIDsRaw(
            from: record,
            fallbackRaw: record["securityMonitoredUUIDsRaw"] as? String ?? ""
        )
        let appliedSettings: SyncableSettings

        if !remoteMasterID.isEmpty {
            UserDefaults.standard.set(true, forKey: Self.automaticMasterClaimCompletedKey)
        }

        if let existing = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first {
            dprint("[CloudKitSync] Applying remote settings ai=\((record["aiIsEnabled"] as? NSNumber)?.boolValue ?? false) master=\(remoteMasterID)")
            populateSettingsFields(existing, from: record)
            appliedSettings = existing
        } else {
            let s = SyncableSettings(
                aiProviderRaw:             record["aiProviderRaw"] as? String ?? "claude",
                aiIsEnabled:               (record["aiIsEnabled"] as? NSNumber)?.boolValue ?? false,
                aiSuggestionsEnabled:      (record["aiSuggestionsEnabled"] as? NSNumber)?.boolValue ?? false,
                aiAnomalyDetectionEnabled: (record["aiAnomalyDetectionEnabled"] as? NSNumber)?.boolValue ?? false,
                aiRuleEngineEnabled:       (record["aiRuleEngineEnabled"] as? NSNumber)?.boolValue ?? false,
                aiHasDataConsent:          (record["aiHasDataConsent"] as? NSNumber)?.boolValue ?? false,
                securityMonitoredUUIDsRaw: remoteSecurityMonitoredRaw,
                masterDeviceID:            remoteMasterID
            )
            s.modifiedAt = remoteModifiedAt
            context.insert(s)
            dprint("[CloudKitSync] Inserted remote settings ai=\(s.aiIsEnabled) master=\(remoteMasterID)")
            appliedSettings = s
        }

        applyRemoteSettingsToRuntime(appliedSettings, record: record)

        // If a master device is already registered and it's not this device,
        // the account already exists → auto-complete onboarding on this device.
        if !remoteMasterID.isEmpty && remoteMasterID != DeviceIdentity.id {
            onboardingAutoCompleteCallback?()
        }
    }

    func populateSettingsFields(_ s: SyncableSettings, from record: CKRecord) {
        s.aiProviderRaw             = record["aiProviderRaw"] as? String ?? s.aiProviderRaw
        s.aiIsEnabled               = (record["aiIsEnabled"] as? NSNumber)?.boolValue ?? s.aiIsEnabled
        s.aiSuggestionsEnabled      = (record["aiSuggestionsEnabled"] as? NSNumber)?.boolValue ?? s.aiSuggestionsEnabled
        s.aiAnomalyDetectionEnabled = (record["aiAnomalyDetectionEnabled"] as? NSNumber)?.boolValue ?? s.aiAnomalyDetectionEnabled
        s.aiRuleEngineEnabled       = (record["aiRuleEngineEnabled"] as? NSNumber)?.boolValue ?? s.aiRuleEngineEnabled
        s.aiHasDataConsent          = (record["aiHasDataConsent"] as? NSNumber)?.boolValue ?? s.aiHasDataConsent
        s.securityMonitoredUUIDsRaw = remappedSecurityMonitoredUUIDsRaw(
            from: record,
            fallbackRaw: record["securityMonitoredUUIDsRaw"] as? String ?? s.securityMonitoredUUIDsRaw
        )
        s.masterDeviceID            = record["masterDeviceID"] as? String ?? s.masterDeviceID
        s.modifiedAt                = record["modifiedAt"] as? Date ?? s.modifiedAt
    }

    func applyRemoteSettingsToRuntime(_ settings: SyncableSettings, record: CKRecord) {
        isApplyingRemoteSettings = true
        applyUserPreferences(from: record)
        remoteSettingsApplyCallback?(settings)
        isApplyingRemoteSettings = false
    }

    func deleteFloorplanRecord(name: String, context: ModelContext) {
        let uuidStr = String(name.dropFirst(Self.floorplanPrefix.count))
        guard let id = UUID(uuidString: uuidStr) else { return }
        let descriptor = FetchDescriptor<Floorplan>(predicate: #Predicate { $0.id == id })
        if let fp = (try? context.fetch(descriptor))?.first {
            context.delete(fp)
        }
    }

    // MARK: - AutomationOpportunity

    func applyOpportunityRecord(_ record: CKRecord, context: ModelContext) {
        guard let uuidStr = record["id"] as? String,
              let id = UUID(uuidString: uuidStr)
        else { return }

        let remoteModifiedAt = record["modifiedAt"] as? Date ?? .distantPast
        let descriptor = FetchDescriptor<AutomationOpportunity>(predicate: #Predicate { $0.id == id })

        if let existing = (try? context.fetch(descriptor))?.first {
            guard remoteModifiedAt > existing.modifiedAt else { return }
            populateOpportunityFields(existing, from: record)
        } else {
            let opp = AutomationOpportunity(
                id: id,
                profileID: (record["profileID"] as? String).flatMap(UUID.init),
                createdAt: record["createdAt"] as? Date ?? .now,
                lastUpdatedAt: record["lastUpdatedAt"] as? Date ?? .now,
                title: record["title"] as? String ?? "",
                naturalLanguage: record["naturalLanguage"] as? String ?? "",
                roomName: record["roomName"] as? String ?? "",
                patternID: (record["patternID"] as? String).flatMap(UUID.init) ?? UUID(),
                confidence: record["confidence"] as? Double ?? 0,
                observations: record["observations"] as? Int ?? 0,
                firstObservedAt: record["firstObservedAt"] as? Date ?? .now,
                lastObservedAt: record["lastObservedAt"] as? Date ?? .now,
                avgTimeString: record["avgTimeString"] as? String,
                timeDeviationMinutes: record["timeDeviationMinutes"] as? Int ?? 0,
                dayTypeLabel: record["dayTypeLabel"] as? String ?? "",
                patternTypeRaw: record["patternTypeRaw"] as? String ?? "",
                triggerType: record["triggerType"] as? String ?? "",
                triggerTime: record["triggerTime"] as? String,
                triggerWeekdaysRaw: record["triggerWeekdaysRaw"] as? String,
                triggerSensorType: record["triggerSensorType"] as? String,
                triggerThreshold: record["triggerThreshold"] as? Double,
                triggerDirection: record["triggerDirection"] as? String,
                triggerConditionsRaw: record["triggerConditionsRaw"] as? String,
                effectAccessoryIDString: record["effectAccessoryIDString"] as? String,
                effectActionRaw: record["effectActionRaw"] as? String ?? "",
                effectValue: record["effectValue"] as? Double,
                effectValue2: record["effectValue2"] as? Double,
                effectSceneName: record["effectSceneName"] as? String,
                statusRaw: record["statusRaw"] as? String ?? OpportunityStatus.pending.rawValue,
                snoozedUntil: record["snoozedUntil"] as? Date,
                dismissedAt: record["dismissedAt"] as? Date,
                approvedAt: record["approvedAt"] as? Date,
                originRaw: record["originRaw"] as? String ?? OpportunityOrigin.detected.rawValue
            )
            opp.modifiedAt = remoteModifiedAt
            context.insert(opp)
        }
    }

    func populateOpportunityFields(_ opp: AutomationOpportunity, from record: CKRecord) {
        opp.modifiedAt              = record["modifiedAt"] as? Date ?? opp.modifiedAt
        opp.lastUpdatedAt           = record["lastUpdatedAt"] as? Date ?? opp.lastUpdatedAt
        opp.title                   = record["title"] as? String ?? opp.title
        opp.naturalLanguage         = record["naturalLanguage"] as? String ?? opp.naturalLanguage
        opp.confidence              = record["confidence"] as? Double ?? opp.confidence
        opp.observations            = record["observations"] as? Int ?? opp.observations
        opp.lastObservedAt          = record["lastObservedAt"] as? Date ?? opp.lastObservedAt
        opp.avgTimeString           = record["avgTimeString"] as? String ?? opp.avgTimeString
        opp.triggerTime             = record["triggerTime"] as? String ?? opp.triggerTime
        opp.triggerWeekdaysRaw      = record["triggerWeekdaysRaw"] as? String ?? opp.triggerWeekdaysRaw
        opp.triggerThreshold        = record["triggerThreshold"] as? Double ?? opp.triggerThreshold
        opp.triggerDirection        = record["triggerDirection"] as? String ?? opp.triggerDirection
        opp.triggerConditionsRaw    = record["triggerConditionsRaw"] as? String ?? opp.triggerConditionsRaw
        opp.effectAccessoryIDString = record["effectAccessoryIDString"] as? String ?? opp.effectAccessoryIDString
        opp.effectActionRaw         = record["effectActionRaw"] as? String ?? opp.effectActionRaw
        opp.effectValue             = record["effectValue"] as? Double ?? opp.effectValue
        opp.effectValue2            = record["effectValue2"] as? Double ?? opp.effectValue2
        opp.effectSceneName         = record["effectSceneName"] as? String ?? opp.effectSceneName
        opp.statusRaw               = record["statusRaw"] as? String ?? opp.statusRaw
        opp.snoozedUntil            = record["snoozedUntil"] as? Date ?? opp.snoozedUntil
        opp.dismissedAt             = record["dismissedAt"] as? Date ?? opp.dismissedAt
        opp.approvedAt              = record["approvedAt"] as? Date ?? opp.approvedAt
    }

    func deleteOpportunityRecord(name: String, context: ModelContext) {
        let uuidStr = String(name.dropFirst(Self.opportunityPrefix.count))
        guard let id = UUID(uuidString: uuidStr) else { return }
        let descriptor = FetchDescriptor<AutomationOpportunity>(predicate: #Predicate { $0.id == id })
        if let opp = (try? context.fetch(descriptor))?.first {
            context.delete(opp)
        }
    }

    // MARK: - SensorAlertThreshold

    func applyThresholdRecord(_ record: CKRecord, context: ModelContext) {
        guard let uuidStr = record["id"] as? String,
              let id = UUID(uuidString: uuidStr),
              let serviceTypeRaw = record["serviceTypeRaw"] as? String
        else { return }

        let descriptor = FetchDescriptor<SensorAlertThreshold>(predicate: #Predicate { $0.id == id })

        if let existing = (try? context.fetch(descriptor))?.first {
            populateThresholdFields(existing, from: record)
        } else {
            let t = SensorAlertThreshold(
                id: id,
                serviceType: SensorServiceType(rawValue: serviceTypeRaw) ?? .temperature,
                roomName: record["roomName"] as? String,
                warningValue: record["warningValue"] as? Double ?? 0,
                dangerValue: record["dangerValue"] as? Double ?? 0,
                isEnabled: (record["isEnabled"] as? NSNumber)?.boolValue ?? true
            )
            context.insert(t)
        }
        // Threshold downloaded from CloudKit is already in sync — no need to re-upload it.
        var synced = syncedThresholdIDs
        synced.insert(uuidStr)
        syncedThresholdIDs = synced
    }

    func populateThresholdFields(_ t: SensorAlertThreshold, from record: CKRecord) {
        t.serviceTypeRaw = record["serviceTypeRaw"] as? String ?? t.serviceTypeRaw
        t.roomName       = record["roomName"] as? String ?? t.roomName
        t.warningValue   = record["warningValue"] as? Double ?? t.warningValue
        t.dangerValue    = record["dangerValue"] as? Double ?? t.dangerValue
        t.isEnabled      = (record["isEnabled"] as? NSNumber)?.boolValue ?? t.isEnabled
    }

    func deleteThresholdRecord(name: String, context: ModelContext) {
        let uuidStr = String(name.dropFirst(Self.thresholdPrefix.count))
        guard let id = UUID(uuidString: uuidStr) else { return }
        let descriptor = FetchDescriptor<SensorAlertThreshold>(predicate: #Predicate { $0.id == id })
        if let t = (try? context.fetch(descriptor))?.first {
            context.delete(t)
        }
    }

    // MARK: - AI Output Records

    func applyInsightRecord(_ record: CKRecord, context: ModelContext) {
        guard let uuidStr = record["id"] as? String,
              let id = UUID(uuidString: uuidStr)
        else { return }

        let remoteGeneratedAt = record["generatedAt"] as? Date ?? .distantPast
        let descriptor = FetchDescriptor<PersistedInsight>(predicate: #Predicate { $0.id == id })

        if let existing = (try? context.fetch(descriptor))?.first {
            guard remoteGeneratedAt >= existing.generatedAt else { return }
            populateInsightFields(existing, from: record)
        } else {
            let insight = PersistedInsight(
                id: id,
                roomName: record["roomName"] as? String ?? "",
                generatedAt: remoteGeneratedAt,
                expiresAt: record["expiresAt"] as? Date ?? remoteGeneratedAt.addingTimeInterval(2 * 3600),
                message: record["message"] as? String ?? "",
                severityRaw: record["severityRaw"] as? String ?? InsightSeverity.info.rawValue,
                intentsRaw: (record["intentsRaw"] as? String)?.split(separator: ",").map(String.init) ?? [],
                nextActionsJSON: record["nextActionsJSON"] as? String ?? "[]",
                statusRaw: record["statusRaw"] as? String ?? InsightPersistedStatus.active.rawValue,
                intelligenceLevelRaw: record["intelligenceLevelRaw"] as? String,
                patternKey: record["patternKey"] as? String,
                whyExplanation: record["whyExplanation"] as? String,
                confidenceScore: record["confidenceScore"] as? Double,
                sourceAccessoryID: record["sourceAccessoryID"] as? String,
                sourceAccessoryName: record["sourceAccessoryName"] as? String,
                sourceServiceType: record["sourceServiceType"] as? String,
                promptVersion: record["promptVersion"] as? String
            )
            context.insert(insight)
        }
    }

    func populateInsightFields(_ insight: PersistedInsight, from record: CKRecord) {
        insight.roomName             = record["roomName"] as? String ?? insight.roomName
        insight.generatedAt          = record["generatedAt"] as? Date ?? insight.generatedAt
        insight.expiresAt            = record["expiresAt"] as? Date ?? insight.expiresAt
        insight.message              = record["message"] as? String ?? insight.message
        insight.severityRaw          = record["severityRaw"] as? String ?? insight.severityRaw
        insight.intentsRaw           = (record["intentsRaw"] as? String)?.split(separator: ",").map(String.init) ?? insight.intentsRaw
        insight.nextActionsJSON      = record["nextActionsJSON"] as? String ?? insight.nextActionsJSON
        insight.statusRaw            = record["statusRaw"] as? String ?? insight.statusRaw
        insight.intelligenceLevelRaw = record["intelligenceLevelRaw"] as? String ?? insight.intelligenceLevelRaw
        insight.patternKey           = record["patternKey"] as? String ?? insight.patternKey
        insight.whyExplanation       = record["whyExplanation"] as? String ?? insight.whyExplanation
        insight.confidenceScore      = record["confidenceScore"] as? Double ?? insight.confidenceScore
        insight.sourceAccessoryID    = record["sourceAccessoryID"] as? String ?? insight.sourceAccessoryID
        insight.sourceAccessoryName  = record["sourceAccessoryName"] as? String ?? insight.sourceAccessoryName
        insight.sourceServiceType    = record["sourceServiceType"] as? String ?? insight.sourceServiceType
        insight.promptVersion        = record["promptVersion"] as? String ?? insight.promptVersion
    }

    func applyBehaviorRecord(_ record: CKRecord, context: ModelContext) {
        guard let uuidStr = record["id"] as? String,
              let id = UUID(uuidString: uuidStr)
        else { return }

        let remoteModifiedAt = record["modifiedAt"] as? Date ?? .distantPast
        let descriptor = FetchDescriptor<PersistedBehavioralPattern>(predicate: #Predicate { $0.id == id })

        if let existing = (try? context.fetch(descriptor))?.first {
            guard remoteModifiedAt > existing.modifiedAt else { return }
            populateBehaviorFields(existing, from: record)
        } else {
            let pattern = PersistedBehavioralPattern(
                id: id,
                profileID: (record["profileID"] as? String).flatMap(UUID.init),
                patternTypeRaw: record["patternTypeRaw"] as? String ?? BehavioralPatternType.temporal.rawValue,
                detectedAt: record["detectedAt"] as? Date ?? .now,
                accessoryName: record["accessoryName"] as? String ?? "",
                accessoryID: (record["accessoryID"] as? String).flatMap(UUID.init),
                roomName: record["roomName"] as? String ?? "",
                eventTypeRaw: record["eventTypeRaw"] as? String ?? "",
                actionRaw: record["actionRaw"] as? String ?? BehavioralAction.on.rawValue,
                numericValue: record["numericValue"] as? Double,
                avgMinuteOfDay: record["avgMinuteOfDay"] as? Int ?? 0,
                timeDeviationMinutes: record["timeDeviationMinutes"] as? Int ?? 0,
                weekdaysRaw: record["weekdaysRaw"] as? String,
                dayTypeRaw: record["dayTypeRaw"] as? String,
                causeSignature: record["causeSignature"] as? String,
                causeName: record["causeName"] as? String,
                avgGapSeconds: record["avgGapSeconds"] as? Double,
                observations: record["observations"] as? Int ?? 0,
                validations: record["validations"] as? Int ?? 0,
                firstObservedAt: record["firstObservedAt"] as? Date ?? .now,
                lastObservedAt: record["lastObservedAt"] as? Date ?? .now,
                stabilityDays: record["stabilityDays"] as? Int ?? 0,
                distinctActiveDays: record["distinctActiveDays"] as? Int,
                statusRaw: record["statusRaw"] as? String ?? BehavioralPatternStatus.active.rawValue,
                dismissedAt: record["dismissedAt"] as? Date,
                approvedAt: record["approvedAt"] as? Date,
                naturalLanguageDescription: record["naturalLanguageDescription"] as? String ?? ""
            )
            pattern.modifiedAt = remoteModifiedAt
            context.insert(pattern)
        }
    }

    func populateBehaviorFields(_ pattern: PersistedBehavioralPattern, from record: CKRecord) {
        pattern.modifiedAt                 = record["modifiedAt"] as? Date ?? pattern.modifiedAt
        pattern.observations               = record["observations"] as? Int ?? pattern.observations
        pattern.validations                = record["validations"] as? Int ?? pattern.validations
        pattern.lastObservedAt             = record["lastObservedAt"] as? Date ?? pattern.lastObservedAt
        pattern.distinctActiveDays         = record["distinctActiveDays"] as? Int ?? pattern.distinctActiveDays
        pattern.statusRaw                  = record["statusRaw"] as? String ?? pattern.statusRaw
        pattern.dismissedAt                = record["dismissedAt"] as? Date ?? pattern.dismissedAt
        pattern.approvedAt                 = record["approvedAt"] as? Date ?? pattern.approvedAt
        pattern.naturalLanguageDescription = record["naturalLanguageDescription"] as? String ?? pattern.naturalLanguageDescription
        pattern.weekdaysRaw                = record["weekdaysRaw"] as? String ?? pattern.weekdaysRaw
        pattern.avgMinuteOfDay             = record["avgMinuteOfDay"] as? Int ?? pattern.avgMinuteOfDay
        pattern.timeDeviationMinutes       = record["timeDeviationMinutes"] as? Int ?? pattern.timeDeviationMinutes
        pattern.numericValue               = record["numericValue"] as? Double ?? pattern.numericValue
        pattern.causeSignature             = record["causeSignature"] as? String ?? pattern.causeSignature
        pattern.causeName                  = record["causeName"] as? String ?? pattern.causeName
        pattern.avgGapSeconds              = record["avgGapSeconds"] as? Double ?? pattern.avgGapSeconds
    }

    func applyHabitRecord(_ record: CKRecord, context: ModelContext) {
        guard let uuidStr = record["id"] as? String,
              let id = UUID(uuidString: uuidStr),
              let accessoryIDString = record["accessoryID"] as? String,
              let accessoryID = UUID(uuidString: accessoryIDString)
        else { return }

        let remoteModifiedAt = record["modifiedAt"] as? Date ?? .distantPast
        let descriptor = FetchDescriptor<HabitPattern>(predicate: #Predicate { $0.id == id })

        if let existing = (try? context.fetch(descriptor))?.first {
            guard remoteModifiedAt > existing.modifiedAt else { return }
            populateHabitFields(existing, from: record)
        } else {
            let habit = HabitPattern(
                id: id,
                patternTypeRaw: record["patternTypeRaw"] as? String ?? PatternType.accessory.rawValue,
                accessoryName: record["accessoryName"] as? String ?? "",
                accessoryID: accessoryID,
                sceneName: record["sceneName"] as? String,
                roomName: record["roomName"] as? String ?? "",
                patternDescription: record["patternDescription"] as? String ?? "",
                detectedAt: record["detectedAt"] as? Date ?? .now,
                confidence: record["confidence"] as? Double ?? 0,
                suggestedRuleJSON: record["suggestedRuleJSON"] as? String ?? "{}",
                statusRaw: record["statusRaw"] as? String ?? PatternStatus.pending.rawValue
            )
            habit.modifiedAt = remoteModifiedAt
            context.insert(habit)
        }
    }

    func populateHabitFields(_ habit: HabitPattern, from record: CKRecord) {
        habit.patternTypeRaw     = record["patternTypeRaw"] as? String ?? habit.patternTypeRaw
        habit.accessoryName      = record["accessoryName"] as? String ?? habit.accessoryName
        habit.sceneName          = record["sceneName"] as? String ?? habit.sceneName
        habit.roomName           = record["roomName"] as? String ?? habit.roomName
        habit.patternDescription = record["patternDescription"] as? String ?? habit.patternDescription
        habit.detectedAt         = record["detectedAt"] as? Date ?? habit.detectedAt
        habit.confidence         = record["confidence"] as? Double ?? habit.confidence
        habit.suggestedRuleJSON  = record["suggestedRuleJSON"] as? String ?? habit.suggestedRuleJSON
        habit.statusRaw          = record["statusRaw"] as? String ?? habit.statusRaw
        habit.modifiedAt         = record["modifiedAt"] as? Date ?? habit.modifiedAt
    }
}
