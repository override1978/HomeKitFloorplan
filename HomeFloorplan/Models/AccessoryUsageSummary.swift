import Foundation
import SwiftData

// MARK: - AccessoryUsageSummary

/// Permanent weekly aggregate of AccessoryEvent records for a single accessory.
///
/// Created by DataLifecycleService from closed ISO weeks (Monday–Sunday) before raw
/// AccessoryEvent records expire at 30 days. Enables long-term usage pattern analysis
/// (activation frequency, peak hour, weekday distribution) without raw telemetry.
///
/// Raw → Aggregate pipeline:
///   AccessoryEvent (30-day raw)  →  AccessoryUsageSummary (permanent)
@Model
final class AccessoryUsageSummary {

    /// Primary key.
    var id: UUID

    /// Midnight on the ISO Monday that begins the represented week.
    var weekStartDate: Date

    /// HMAccessory.uniqueIdentifier of the accessory.
    var accessoryID: UUID

    /// Display name of the accessory at time of aggregation.
    var accessoryName: String

    /// HomeKit room name (empty string if not available).
    var roomName: String

    /// AccessoryEvent.eventType: "light", "switch", "motion", "contact", "blind".
    var eventType: String

    /// Count of events where state == true (on / open / detected).
    var onCount: Int

    /// Count of events where state == false (off / closed).
    var offCount: Int

    /// Average hour of day (0.0–23.99) when on-events occurred.
    var avgActivationHour: Double

    // MARK: Weekday distribution for on-events (Sunday=1 … Saturday=7)
    var wdSun: Int
    var wdMon: Int
    var wdTue: Int
    var wdWed: Int
    var wdThu: Int
    var wdFri: Int
    var wdSat: Int

    init(
        id: UUID = UUID(),
        weekStartDate: Date,
        accessoryID: UUID,
        accessoryName: String,
        roomName: String,
        eventType: String,
        onCount: Int,
        offCount: Int,
        avgActivationHour: Double,
        wdSun: Int = 0,
        wdMon: Int = 0,
        wdTue: Int = 0,
        wdWed: Int = 0,
        wdThu: Int = 0,
        wdFri: Int = 0,
        wdSat: Int = 0
    ) {
        self.id                 = id
        self.weekStartDate      = weekStartDate
        self.accessoryID        = accessoryID
        self.accessoryName      = accessoryName
        self.roomName           = roomName
        self.eventType          = eventType
        self.onCount            = onCount
        self.offCount           = offCount
        self.avgActivationHour  = avgActivationHour
        self.wdSun              = wdSun
        self.wdMon              = wdMon
        self.wdTue              = wdTue
        self.wdWed              = wdWed
        self.wdThu              = wdThu
        self.wdFri              = wdFri
        self.wdSat              = wdSat
    }

    /// Weekday distribution array indexed Sunday=0 … Saturday=6.
    var weekdayDistribution: [Int] {
        [wdSun, wdMon, wdTue, wdWed, wdThu, wdFri, wdSat]
    }

    /// Peak weekday (1–7, Sunday=1) for on-events. Nil if no on-events this week.
    var peakWeekday: Int? {
        let dist = [(1, wdSun), (2, wdMon), (3, wdTue), (4, wdWed), (5, wdThu), (6, wdFri), (7, wdSat)]
        return dist.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil }
    }
}
