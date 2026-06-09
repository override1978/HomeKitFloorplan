import Foundation

// MARK: - PredictiveAlertEngine

/// Reads EnvironmentalRecurrencePattern from UserDefaults and generates
/// PredictiveEnvironmentAlert instances when the current time falls within
/// ±2 hours of a pattern's expected exceedance window (Sprint 25.C).
///
/// Rate limit: max 1 alert per (roomName, sensorType) per calendar day.
/// Intended to be called from HomeKnowledgeService.refresh() on the main actor.
enum PredictiveAlertEngine {

    private static let windowHours:       Double = 2.0
    private static let rateLimitKeyPrefix        = "predictive.lastAlertDay"
    private static let minimumConfidence: Double = 0.50

    // MARK: - Generate

    /// Returns alerts whose expected peak window falls within ±2h of the current time.
    static func generateAlerts() -> [PredictiveEnvironmentAlert] {
        let patterns = EnvironmentalPatternAnalyzer.loadPatterns()
        guard !patterns.isEmpty else { return [] }

        let now         = Date()
        let cal         = Calendar.current
        let currentWD   = cal.component(.weekday, from: now)
        let currentHour = cal.component(.hour, from: now)
        let todayStart  = cal.startOfDay(for: now)

        var alerts: [PredictiveEnvironmentAlert] = []

        for pattern in patterns {
            guard pattern.confidence >= minimumConfidence else { continue }
            guard pattern.weekday == currentWD            else { continue }

            let hoursUntil = Double(pattern.hourOfDay - currentHour)
            guard abs(hoursUntil) <= windowHours else { continue }

            // Rate limit: one alert per (room, sensor) per day
            let rateLimitKey = "\(rateLimitKeyPrefix).\(pattern.roomName).\(pattern.sensorTypeRaw)"
            if let lastDay = UserDefaults.standard.object(forKey: rateLimitKey) as? Date,
               lastDay >= todayStart { continue }

            let message = buildMessage(pattern: pattern, hoursUntil: hoursUntil, cal: cal)

            alerts.append(PredictiveEnvironmentAlert(
                id:             UUID(),
                roomName:       pattern.roomName,
                sensorTypeRaw:  pattern.sensorTypeRaw,
                hoursUntilPeak: hoursUntil,
                message:        message,
                confidence:     pattern.confidence,
                weekday:        pattern.weekday,
                hourOfDay:      pattern.hourOfDay,
                generatedAt:    now
            ))

            // Record the rate-limit timestamp
            UserDefaults.standard.set(todayStart, forKey: rateLimitKey)
        }

        // Soonest expected peak first
        return alerts.sorted { abs($0.hoursUntilPeak) < abs($1.hoursUntilPeak) }
    }

    // MARK: - Message building

    private static func buildMessage(
        pattern:    EnvironmentalRecurrencePattern,
        hoursUntil: Double,
        cal:        Calendar
    ) -> String {
        let sensorName  = localizedSensorName(pattern.sensorTypeRaw)
        let weekdayName = localizedWeekday(pattern.weekday, cal: cal)

        if hoursUntil > 0 {
            let h        = max(1, Int(hoursUntil.rounded()))
            let hourUnit = h == 1
                ? String(localized: "predictive.hour",  defaultValue: "hour")
                : String(localized: "predictive.hours", defaultValue: "hours")
            return String(
                format: String(localized: "predictive.alert.upcoming",
                               defaultValue: "In about %lld %@ it is likely that %@ will exceed normal levels of %@ (as every %@)."),
                Int64(h), hourUnit, pattern.roomName, sensorName, weekdayName
            )
        } else {
            return String(
                format: String(localized: "predictive.alert.inProgress",
                               defaultValue: "%@ tends to have high %@ at this time every %@."),
                pattern.roomName, sensorName, weekdayName
            )
        }
    }

    private static func localizedSensorName(_ raw: String) -> String {
        switch raw {
        case "temperature":   return String(localized: "sensor.name.temperature",   defaultValue: "temperature")
        case "humidity":      return String(localized: "sensor.name.humidity",       defaultValue: "humidity")
        case "carbonDioxide": return String(localized: "sensor.name.carbonDioxide",  defaultValue: "CO\u{2082}")
        case "airQuality":    return String(localized: "sensor.name.airQuality",     defaultValue: "air quality")
        case "vocDensity":    return String(localized: "sensor.name.vocDensity",     defaultValue: "VOC")
        default:              return raw
        }
    }

    // weekday: 1 = Sunday … 7 = Saturday (Calendar convention)
    private static func localizedWeekday(_ weekday: Int, cal: Calendar) -> String {
        let symbols = cal.weekdaySymbols   // index 0 = Sunday
        let idx     = weekday - 1
        guard idx >= 0, idx < symbols.count else { return "" }
        return symbols[idx].lowercased()
    }
}
