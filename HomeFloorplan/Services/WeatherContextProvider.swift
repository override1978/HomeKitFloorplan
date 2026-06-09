import Foundation

// MARK: - WeatherContextProvider

/// Static utilities that translate a WeatherSnapshot into AI-consumable artefacts:
///   1. `payloadDict`          — JSON fields injected into the LLM user-prompt.
///   2. `systemPromptNote`     — one-line context string added to the system prompt.
///   3. `applyWeatherCorrection` — shifts the indoor temperature baseline avg when
///      outdoor temperature deviates from its seasonal norm, reducing false anomalies
///      on unusually hot or cold days (coupling factor = 0.30).
enum WeatherContextProvider {

    // MARK: - Seasonal outdoor temperature norms (°C)

    /// Expected outdoor temperature by season, used to compute baseline corrections.
    private static let outdoorTempNorm: [CalendarSeason: Double] = [
        .winter: 5,
        .spring: 15,
        .summer: 28,
        .autumn: 12,
    ]

    /// Coupling factor: fraction of outdoor-temperature deviation that propagates indoors.
    /// 0.30 = 30 % transfer (well-insulated home assumption).
    private static let couplingFactor: Double = 0.30

    // MARK: - LLM Payload

    /// Returns a `[String: Any]` dict to be merged into the AI user-prompt JSON.
    static func payloadDict(snapshot: WeatherSnapshot) -> [String: Any] {
        [
            "outdoorTempC":       round(snapshot.outdoorTemperature  * 10) / 10,
            "outdoorHumidity":    round(snapshot.outdoorHumidity      * 100) / 100,
            "apparentTempC":      round(snapshot.apparentTemperature * 10) / 10,
            "condition":          snapshot.condition,
            "uvIndex":            snapshot.uvIndex,
            "windKmh":            round(snapshot.windSpeedKmh        * 10) / 10,
        ]
    }

    // MARK: - System Prompt Note

    /// One-line English context string for the LLM system prompt.
    static func systemPromptNote(snapshot: WeatherSnapshot) -> String {
        let temp = String(format: "%.1f", snapshot.outdoorTemperature)
        let hum  = String(format: "%.0f%%", snapshot.outdoorHumidity * 100)
        return "Outdoor: \(temp)°C (\(snapshot.condition)), humidity \(hum), UV \(snapshot.uvIndex). Use outdoor context to inform indoor reasoning."
    }

    // MARK: - Baseline Correction (Sprint 31.3)

    /// Adjusts the indoor temperature baseline average to compensate for outdoor
    /// temperature anomalies.  Only the `"temperature"` sensor type is corrected;
    /// other sensor types (humidity, CO₂, etc.) are returned unchanged.
    ///
    /// Formula: correction = (outdoorTemp − seasonalNorm) × couplingFactor
    ///   • +35 °C vs summer norm 28 °C → +2.1 °C shift — raises the "normal" band
    ///   • -5 °C vs winter norm 5 °C   → -3.0 °C shift — lowers it
    ///
    /// The standard deviation is intentionally not adjusted: the AI should still
    /// flag large absolute deviations even on extreme-weather days.
    static func applyWeatherCorrection(
        to baseline: [String: (avg: Double, stdDev: Double)],
        outdoorTemp: Double,
        season: CalendarSeason
    ) -> [String: (avg: Double, stdDev: Double)] {
        guard let norm = outdoorTempNorm[season] else { return baseline }
        let correction = (outdoorTemp - norm) * couplingFactor

        guard abs(correction) > 0.1 else { return baseline }   // skip negligible adjustments

        var adjusted = baseline
        if var tempStats = adjusted["temperature"] {
            tempStats = (avg: tempStats.avg + correction, stdDev: tempStats.stdDev)
            adjusted["temperature"] = tempStats
        }
        return adjusted
    }
}
