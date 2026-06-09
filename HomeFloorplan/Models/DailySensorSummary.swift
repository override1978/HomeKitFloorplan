import Foundation
import SwiftData

// MARK: - DailySensorSummary

/// Permanent daily aggregate of SensorReading records for a single room + sensor type.
///
/// Created by DataLifecycleService before raw SensorReading records expire (30-day window).
/// Survives indefinitely and enables long-term trend analysis without raw telemetry.
///
/// Raw → Aggregate pipeline:
///   SensorReading (30-day raw)  →  DailySensorSummary (permanent)
@Model
final class DailySensorSummary {

    /// Primary key.
    var id: UUID

    /// Always Calendar.current.startOfDay(for:) — midnight of the represented day.
    var date: Date

    /// HomeKit room name at time of measurement.
    var roomName: String

    /// SensorServiceType.rawValue: "temperature", "humidity", "carbonDioxide", etc.
    var serviceTypeRaw: String

    /// Number of SensorReading records aggregated into this summary.
    var sampleCount: Int

    /// Mean sensor value for the day.
    var average: Double

    /// Minimum recorded value.
    var minimum: Double

    /// Maximum recorded value.
    var maximum: Double

    /// Population standard deviation across all samples.
    var standardDeviation: Double

    /// Highest single reading value (same as maximum, kept separate for semantics).
    var peakValue: Double

    /// Timestamp of the peak reading within the day.
    var peakAt: Date

    /// True when the day has fewer than 8 valid readings — sensor was likely offline
    /// or unreachable for most of the day. Excluded from baseline computation.
    var isOutlierDay: Bool

    init(
        id: UUID = UUID(),
        date: Date,
        roomName: String,
        serviceTypeRaw: String,
        sampleCount: Int,
        average: Double,
        minimum: Double,
        maximum: Double,
        standardDeviation: Double,
        peakValue: Double,
        peakAt: Date,
        isOutlierDay: Bool = false
    ) {
        self.id               = id
        self.date             = date
        self.roomName         = roomName
        self.serviceTypeRaw   = serviceTypeRaw
        self.sampleCount      = sampleCount
        self.average          = average
        self.minimum          = minimum
        self.maximum          = maximum
        self.standardDeviation = standardDeviation
        self.peakValue        = peakValue
        self.peakAt           = peakAt
        self.isOutlierDay     = isOutlierDay
    }
}
