import Foundation

// MARK: - EnergyUsageRecord

/// Per-accessory energy usage summary derived from AccessoryEvent history.
/// Produced by EnergyUsageTracker; consumed by EnergyInsightBuilder and EnergyDashboardCard.
struct EnergyUsageRecord: Identifiable {

    let id:                  UUID
    let accessoryID:         UUID
    let accessoryName:       String
    let roomName:            String
    /// Maps to AccessoryEvent.eventType ("light", "switch", "blind", "contact", "motion").
    let eventType:           String

    /// Total ON-time in the last 24 hours (hours).
    let totalHoursToday:     Double
    /// Total ON-time in the last 7 days (hours).
    let totalHoursWeek:      Double
    /// Number of distinct calendar days (within the 7-day window) in which the accessory was on.
    let activeDaysInWindow:  Int
    /// Average daily ON-time, computed over active days only (not calendar days).
    /// Prevents dilution for accessories used only on some days of the week.
    var avgDailyHours:       Double { totalHoursWeek / max(1.0, Double(activeDaysInWindow)) }
    /// Duration of the longest single continuous ON session in the 7-day window (hours).
    let longestSessionHours: Double
    /// Number of activation cycles (ON events) in the last 24 hours.
    let sessionCountToday:   Int
    /// True if the most-recent event recorded was an ON event.
    let isCurrentlyOn:       Bool
    /// Timestamp when the current ON session started. Nil if the accessory is currently off.
    let currentSessionStart: Date?

    /// How many hours the accessory has been on in the current session.
    /// Returns nil when the accessory is currently off.
    var currentSessionHours: Double? {
        guard isCurrentlyOn, let start = currentSessionStart else { return nil }
        return Date().timeIntervalSince(start) / 3600
    }
}
