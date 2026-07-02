import Foundation
import SwiftData

// MARK: - OpportunityMigrationService

/// One-shot migration: reads legacy VersionedStore opportunity JSON files and
/// inserts records into SwiftData. Runs once at app launch, gated by UserDefaults.
struct OpportunityMigrationService {
    static let migrationDoneKey = "migration.opportunities.v1.done"

    @MainActor
    static func runIfNeeded(context: ModelContext) async {
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationDoneKey) else { return }

        let storeDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VersionedStore", isDirectory: true)

        let allFiles = (try? FileManager.default.contentsOfDirectory(
            at: storeDir, includingPropertiesForKeys: nil)) ?? []

        // Match "behavioral.opportunities.v1*.json" but skip .backup.json files
        let opportunityFiles = allFiles.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("behavioral.opportunities.v1") &&
                   name.hasSuffix(".json") &&
                   !name.hasSuffix(".backup.json")
        }

        guard !opportunityFiles.isEmpty else {
            dprint("[OpportunityMigration] no legacy files found — marking done")
            ud.set(true, forKey: migrationDoneKey)
            return
        }

        var totalMigrated = 0
        for fileURL in opportunityFiles {
            let stem      = (fileURL.lastPathComponent as NSString).deletingPathExtension
            let profileID = extractProfileID(from: stem)

            // Reuse VersionedStore's own load logic (handles envelope + legacy raw JSON + v1→v2)
            let store = VersionedStore<[LegacyCodableOpportunity]>(key: stem, version: 2, migrate: { _, payload in
                try? JSONDecoder().decode([LegacyCodableOpportunity].self, from: payload)
            })

            guard let legacyList = store.load() else {
                dprint("[OpportunityMigration] could not decode \(stem)")
                continue
            }

            for legacy in legacyList {
                let opp = AutomationOpportunity(
                    id:                      legacy.id,
                    profileID:               profileID,
                    createdAt:               legacy.createdAt,
                    lastUpdatedAt:           legacy.lastUpdatedAt,
                    title:                   legacy.title,
                    naturalLanguage:         legacy.naturalLanguage,
                    roomName:                legacy.roomName,
                    patternID:               legacy.patternID,
                    confidence:              legacy.confidence,
                    observations:            legacy.observations,
                    firstObservedAt:         legacy.firstObservedAt,
                    lastObservedAt:          legacy.lastObservedAt,
                    avgTimeString:           legacy.avgTimeString,
                    timeDeviationMinutes:    legacy.timeDeviationMinutes,
                    dayTypeLabel:            legacy.dayTypeLabel,
                    patternTypeRaw:          legacy.patternType.rawValue,
                    triggerType:             legacy.triggerType,
                    triggerTime:             legacy.triggerTime,
                    triggerWeekdaysRaw:      legacy.triggerWeekdaysRaw,
                    triggerSensorType:       legacy.triggerSensorType,
                    triggerThreshold:        legacy.triggerThreshold,
                    triggerDirection:        legacy.triggerDirection,
                    effectAccessoryIDString: legacy.effectAccessoryIDString,
                    effectActionRaw:         legacy.effectActionRaw,
                    effectValue:             legacy.effectValue,
                    effectValue2:            legacy.effectValue2,
                    effectSceneName:         legacy.effectSceneName,
                    statusRaw:               legacy.status.rawValue,
                    snoozedUntil:            legacy.snoozedUntil,
                    dismissedAt:             legacy.dismissedAt,
                    approvedAt:              legacy.approvedAt,
                    originRaw:               legacy.origin.rawValue
                )
                context.insert(opp)
                totalMigrated += 1
            }
            dprint("[OpportunityMigration] \(stem): \(legacyList.count) opportunities")
        }

        try? context.save()
        ud.set(true, forKey: migrationDoneKey)
        dprint("[OpportunityMigration] complete — \(totalMigrated) total migrated")
    }

    /// Extracts profileID from "behavioral.opportunities.v1.<UUID>" filename stem.
    private static func extractProfileID(from stem: String) -> UUID? {
        let prefix = "behavioral.opportunities.v1."
        guard stem.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(stem.dropFirst(prefix.count)))
    }
}

// MARK: - LegacyCodableOpportunity

/// Mirror of the pre-migration `struct AutomationOpportunity: Codable`.
/// Used only by OpportunityMigrationService to decode legacy VersionedStore JSON.
private struct LegacyCodableOpportunity: Codable {
    var id:            UUID
    var createdAt:     Date
    var lastUpdatedAt: Date
    var title:           String
    var naturalLanguage: String
    var roomName:        String
    var patternID:             UUID
    var confidence:            Double
    var observations:          Int
    var firstObservedAt:       Date
    var lastObservedAt:        Date
    var avgTimeString:         String?
    var timeDeviationMinutes:  Int
    var dayTypeLabel:          String
    var patternType:           BehavioralPatternType
    var triggerType:           String
    var triggerTime:           String?
    var triggerWeekdaysRaw:    String?
    var triggerSensorType:     String?
    var triggerThreshold:      Double?
    var triggerDirection:      String?
    var effectAccessoryIDString: String?
    var effectActionRaw:         String
    var effectValue:             Double?
    var effectValue2:            Double?
    var effectSceneName:         String?
    var status:      OpportunityStatus
    var snoozedUntil: Date?
    var dismissedAt:  Date?
    var approvedAt:   Date?
    var origin: OpportunityOrigin

    enum CodingKeys: String, CodingKey {
        case id, createdAt, lastUpdatedAt
        case title, naturalLanguage, roomName
        case patternID, confidence, observations
        case firstObservedAt, lastObservedAt, avgTimeString
        case timeDeviationMinutes, dayTypeLabel, patternType
        case triggerType, triggerTime, triggerWeekdaysRaw
        case triggerSensorType, triggerThreshold, triggerDirection
        case effectAccessoryIDString, effectActionRaw, effectValue, effectValue2, effectSceneName
        case status, snoozedUntil, dismissedAt, approvedAt
        case origin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                      = try c.decode(UUID.self,                  forKey: .id)
        createdAt               = try c.decode(Date.self,                  forKey: .createdAt)
        lastUpdatedAt           = try c.decode(Date.self,                  forKey: .lastUpdatedAt)
        title                   = try c.decode(String.self,                forKey: .title)
        naturalLanguage         = try c.decode(String.self,                forKey: .naturalLanguage)
        roomName                = try c.decode(String.self,                forKey: .roomName)
        patternID               = try c.decode(UUID.self,                  forKey: .patternID)
        confidence              = try c.decode(Double.self,                forKey: .confidence)
        observations            = try c.decode(Int.self,                   forKey: .observations)
        firstObservedAt         = try c.decode(Date.self,                  forKey: .firstObservedAt)
        lastObservedAt          = try c.decode(Date.self,                  forKey: .lastObservedAt)
        avgTimeString           = try c.decodeIfPresent(String.self,       forKey: .avgTimeString)
        timeDeviationMinutes    = try c.decode(Int.self,                   forKey: .timeDeviationMinutes)
        dayTypeLabel            = try c.decode(String.self,                forKey: .dayTypeLabel)
        patternType             = try c.decode(BehavioralPatternType.self, forKey: .patternType)
        triggerType             = try c.decode(String.self,                forKey: .triggerType)
        triggerTime             = try c.decodeIfPresent(String.self,       forKey: .triggerTime)
        triggerWeekdaysRaw      = try c.decodeIfPresent(String.self,       forKey: .triggerWeekdaysRaw)
        triggerSensorType       = try c.decodeIfPresent(String.self,       forKey: .triggerSensorType)
        triggerThreshold        = try c.decodeIfPresent(Double.self,       forKey: .triggerThreshold)
        triggerDirection        = try c.decodeIfPresent(String.self,       forKey: .triggerDirection)
        effectAccessoryIDString = try c.decodeIfPresent(String.self,       forKey: .effectAccessoryIDString)
        effectActionRaw         = try c.decode(String.self,                forKey: .effectActionRaw)
        effectValue             = try c.decodeIfPresent(Double.self,       forKey: .effectValue)
        effectValue2            = try c.decodeIfPresent(Double.self,       forKey: .effectValue2)
        effectSceneName         = try c.decodeIfPresent(String.self,       forKey: .effectSceneName)
        status                  = try c.decode(OpportunityStatus.self,     forKey: .status)
        snoozedUntil            = try c.decodeIfPresent(Date.self,         forKey: .snoozedUntil)
        dismissedAt             = try c.decodeIfPresent(Date.self,         forKey: .dismissedAt)
        approvedAt              = try c.decodeIfPresent(Date.self,         forKey: .approvedAt)
        // Legacy JSON without `origin` defaults to .detected
        origin = try c.decodeIfPresent(OpportunityOrigin.self, forKey: .origin) ?? .detected
    }
}
