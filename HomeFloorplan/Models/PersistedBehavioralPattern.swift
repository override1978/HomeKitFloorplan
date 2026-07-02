import Foundation
import SwiftData

// MARK: - PersistedBehavioralPattern

/// SwiftData persistence layer for BehavioralPattern structs.
///
/// BehavioralPattern stays a struct so PatternDetectionEngine is unchanged.
/// This @Model stores the same data in SwiftData for backup and future CloudKit sync.
/// Enum fields use rawValue strings for CloudKit field-level access.
/// Array fields (weekdays) use comma-separated strings.
@Model
final class PersistedBehavioralPattern {

    @Attribute(.unique) var id: UUID
    var profileID: UUID?
    var modifiedAt: Date

    var patternTypeRaw: String  // BehavioralPatternType.rawValue
    var detectedAt: Date

    // — What happens —
    var accessoryName: String
    var accessoryID: UUID?
    var roomName: String
    var eventTypeRaw: String
    var actionRaw: String       // BehavioralAction.rawValue
    var numericValue: Double?

    // — Temporal trigger —
    var avgMinuteOfDay: Int
    var timeDeviationMinutes: Int
    var weekdaysRaw: String?    // comma-separated Calendar weekday ints
    var dayTypeRaw: String?     // DayType.rawValue

    // — Sequential trigger —
    var causeSignature: String?
    var causeName: String?
    var avgGapSeconds: Double?

    // — Confidence tracking —
    var observations: Int
    var validations: Int
    var firstObservedAt: Date
    var lastObservedAt: Date
    var stabilityDays: Int
    var distinctActiveDays: Int?

    // — Status —
    var statusRaw: String       // BehavioralPatternStatus.rawValue
    var dismissedAt: Date?
    var approvedAt: Date?

    // — Presentation —
    var naturalLanguageDescription: String

    // MARK: - Designated Init

    init(
        id: UUID,
        profileID: UUID?,
        patternTypeRaw: String,
        detectedAt: Date,
        accessoryName: String,
        accessoryID: UUID?,
        roomName: String,
        eventTypeRaw: String,
        actionRaw: String,
        numericValue: Double?,
        avgMinuteOfDay: Int,
        timeDeviationMinutes: Int,
        weekdaysRaw: String?,
        dayTypeRaw: String?,
        causeSignature: String?,
        causeName: String?,
        avgGapSeconds: Double?,
        observations: Int,
        validations: Int,
        firstObservedAt: Date,
        lastObservedAt: Date,
        stabilityDays: Int,
        distinctActiveDays: Int?,
        statusRaw: String,
        dismissedAt: Date?,
        approvedAt: Date?,
        naturalLanguageDescription: String
    ) {
        self.id                         = id
        self.profileID                  = profileID
        self.modifiedAt                 = .now
        self.patternTypeRaw             = patternTypeRaw
        self.detectedAt                 = detectedAt
        self.accessoryName              = accessoryName
        self.accessoryID                = accessoryID
        self.roomName                   = roomName
        self.eventTypeRaw               = eventTypeRaw
        self.actionRaw                  = actionRaw
        self.numericValue               = numericValue
        self.avgMinuteOfDay             = avgMinuteOfDay
        self.timeDeviationMinutes       = timeDeviationMinutes
        self.weekdaysRaw                = weekdaysRaw
        self.dayTypeRaw                 = dayTypeRaw
        self.causeSignature             = causeSignature
        self.causeName                  = causeName
        self.avgGapSeconds              = avgGapSeconds
        self.observations               = observations
        self.validations                = validations
        self.firstObservedAt            = firstObservedAt
        self.lastObservedAt             = lastObservedAt
        self.stabilityDays              = stabilityDays
        self.distinctActiveDays         = distinctActiveDays
        self.statusRaw                  = statusRaw
        self.dismissedAt                = dismissedAt
        self.approvedAt                 = approvedAt
        self.naturalLanguageDescription = naturalLanguageDescription
    }
}

// MARK: - Struct ↔ @Model Conversion

extension PersistedBehavioralPattern {

    /// Creates a new @Model record from a BehavioralPattern struct.
    convenience init(from pattern: BehavioralPattern, profileID: UUID? = nil) {
        self.init(
            id:                         pattern.id,
            profileID:                  profileID,
            patternTypeRaw:             pattern.patternType.rawValue,
            detectedAt:                 pattern.detectedAt,
            accessoryName:              pattern.accessoryName,
            accessoryID:                pattern.accessoryID,
            roomName:                   pattern.roomName,
            eventTypeRaw:               pattern.eventTypeRaw,
            actionRaw:                  pattern.action.rawValue,
            numericValue:               pattern.numericValue,
            avgMinuteOfDay:             pattern.avgMinuteOfDay,
            timeDeviationMinutes:       pattern.timeDeviationMinutes,
            weekdaysRaw:                pattern.weekdays.isEmpty
                                            ? nil
                                            : pattern.weekdays.map(String.init).joined(separator: ","),
            dayTypeRaw:                 pattern.dayType?.rawValue,
            causeSignature:             pattern.causeSignature,
            causeName:                  pattern.causeName,
            avgGapSeconds:              pattern.avgGapSeconds,
            observations:               pattern.observations,
            validations:                pattern.validations,
            firstObservedAt:            pattern.firstObservedAt,
            lastObservedAt:             pattern.lastObservedAt,
            stabilityDays:              pattern.stabilityDays,
            distinctActiveDays:         pattern.distinctActiveDays,
            statusRaw:                  pattern.status.rawValue,
            dismissedAt:                pattern.dismissedAt,
            approvedAt:                 pattern.approvedAt,
            naturalLanguageDescription: pattern.naturalLanguageDescription
        )
    }

    /// Updates mutable fields in-place from a BehavioralPattern struct (used during upsert).
    func update(from pattern: BehavioralPattern) {
        observations               = pattern.observations
        validations                = pattern.validations
        lastObservedAt             = pattern.lastObservedAt
        distinctActiveDays         = pattern.distinctActiveDays
        statusRaw                  = pattern.status.rawValue
        dismissedAt                = pattern.dismissedAt
        approvedAt                 = pattern.approvedAt
        naturalLanguageDescription = pattern.naturalLanguageDescription
        weekdaysRaw                = pattern.weekdays.isEmpty
                                         ? nil
                                         : pattern.weekdays.map(String.init).joined(separator: ",")
        avgMinuteOfDay             = pattern.avgMinuteOfDay
        timeDeviationMinutes       = pattern.timeDeviationMinutes
        numericValue               = pattern.numericValue
        causeSignature             = pattern.causeSignature
        causeName                  = pattern.causeName
        avgGapSeconds              = pattern.avgGapSeconds
        modifiedAt                 = .now
    }

    /// Converts this @Model record back to a BehavioralPattern struct.
    func toBehavioralPattern() -> BehavioralPattern {
        BehavioralPattern(
            id:                         id,
            patternType:                BehavioralPatternType(rawValue: patternTypeRaw) ?? .temporal,
            detectedAt:                 detectedAt,
            accessoryName:              accessoryName,
            accessoryID:                accessoryID,
            roomName:                   roomName,
            eventTypeRaw:               eventTypeRaw,
            action:                     BehavioralAction(rawValue: actionRaw) ?? .on,
            numericValue:               numericValue,
            avgMinuteOfDay:             avgMinuteOfDay,
            timeDeviationMinutes:       timeDeviationMinutes,
            weekdays:                   weekdaysRaw?
                                            .split(separator: ",")
                                            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                                            ?? [],
            dayType:                    dayTypeRaw.flatMap { DayType(rawValue: $0) },
            causeSignature:             causeSignature,
            causeName:                  causeName,
            avgGapSeconds:              avgGapSeconds,
            observations:               observations,
            validations:                validations,
            firstObservedAt:            firstObservedAt,
            lastObservedAt:             lastObservedAt,
            stabilityDays:              stabilityDays,
            distinctActiveDays:         distinctActiveDays,
            status:                     BehavioralPatternStatus(rawValue: statusRaw) ?? .active,
            dismissedAt:                dismissedAt,
            approvedAt:                 approvedAt,
            naturalLanguageDescription: naturalLanguageDescription
        )
    }
}
