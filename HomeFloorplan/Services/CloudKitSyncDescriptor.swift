import CloudKit
import Foundation
import SwiftData

// MARK: - CloudKitSyncDescriptor

/// Describes how a SwiftData model family maps to CloudKit.
///
/// This is intentionally not a SwiftData @Model and must never be added to the
/// app schema. It only lets CloudKitSyncService route records without hardcoding
/// every synced table in the engine callbacks.
@MainActor
struct CloudKitSyncDescriptor {
    let recordType: String
    let recordPrefix: String
    let pendingChanges: (_ context: ModelContext, _ cutoff: Date?) -> [CKSyncEngine.PendingRecordZoneChange]
    let buildRecord: (_ recordID: CKRecord.ID, _ context: ModelContext) -> CKRecord?
    let applyRecord: (_ record: CKRecord, _ context: ModelContext) -> Void
    let deleteRecord: (_ recordID: CKRecord.ID, _ context: ModelContext) -> Void
    let overlayLocalFields: (_ serverRecord: CKRecord, _ context: ModelContext) -> Void
    let markSavedRecord: (_ record: CKRecord) -> Void

    func matches(_ recordID: CKRecord.ID) -> Bool {
        recordID.recordName.hasPrefix(recordPrefix)
    }

    func idString(from recordID: CKRecord.ID) -> String {
        String(recordID.recordName.dropFirst(recordPrefix.count))
    }
}
