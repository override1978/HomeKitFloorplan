import Foundation
import SwiftData

struct AppSettingsSyncCoordinator {
    let sharedModelContainer: ModelContainer
    let cloudKitSync: CloudKitSyncService
    let securityNotifier: SecurityNotificationService

    func markSettingsNeedsSync() {
        cloudKitSync.markSettingsNeedsSync()
    }

    func updateSecurityMonitoredUUIDs(_ newValue: String) {
        securityNotifier.updateMonitored(uuidsRaw: newValue)
        guard !cloudKitSync.isApplyingRemoteSettings else { return }
        let context = ModelContext(sharedModelContainer)
        guard let settings = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return
        }
        settings.securityMonitoredUUIDsRaw = newValue
        settings.modifiedAt = .now
        try? context.save()
        cloudKitSync.syncAfterSave()
    }
}
