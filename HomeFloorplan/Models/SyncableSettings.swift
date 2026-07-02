import Foundation
import SwiftData

// MARK: - SyncableSettings

/// Singleton SwiftData record for settings that are in CloudKit sync scope.
///
/// Always exactly one record in the store (enforced by a fixed `id`).
/// In FASE 1, this record will be pushed/pulled via CloudKit.
/// Reading uses the fixed `singletonID`; writing uses upsert (create if absent, update if present).
@Model
final class SyncableSettings {

    /// Fixed UUID used as the singleton primary key.
    static let singletonID = UUID(uuidString: "00000001-0000-0000-0000-000000000000")!

    @Attribute(.unique) var id: UUID

    // — AI Settings —
    var aiProviderRaw: String           // AIProvider.rawValue
    var aiIsEnabled: Bool
    var aiSuggestionsEnabled: Bool
    var aiAnomalyDetectionEnabled: Bool
    var aiRuleEngineEnabled: Bool
    var aiHasDataConsent: Bool

    // — Security —
    /// Comma-separated UUIDs of monitored security sensors (same format as @AppStorage).
    var securityMonitoredUUIDsRaw: String

    // — Device Role —
    /// UUID of the device that claimed the Master role. Empty means no master claimed yet.
    /// Master: runs behavioral analysis. Slave: receives data only.
    var masterDeviceID: String

    // — Sync metadata —
    var modifiedAt: Date

    // MARK: - Init

    init(
        aiProviderRaw: String,
        aiIsEnabled: Bool,
        aiSuggestionsEnabled: Bool,
        aiAnomalyDetectionEnabled: Bool,
        aiRuleEngineEnabled: Bool,
        aiHasDataConsent: Bool,
        securityMonitoredUUIDsRaw: String,
        masterDeviceID: String = ""
    ) {
        self.id                         = Self.singletonID
        self.aiProviderRaw              = aiProviderRaw
        self.aiIsEnabled                = aiIsEnabled
        self.aiSuggestionsEnabled       = aiSuggestionsEnabled
        self.aiAnomalyDetectionEnabled  = aiAnomalyDetectionEnabled
        self.aiRuleEngineEnabled        = aiRuleEngineEnabled
        self.aiHasDataConsent           = aiHasDataConsent
        self.securityMonitoredUUIDsRaw  = securityMonitoredUUIDsRaw
        self.masterDeviceID             = masterDeviceID
        self.modifiedAt                 = .now
    }
}
