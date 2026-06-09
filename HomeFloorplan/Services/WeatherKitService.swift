import Foundation
import WeatherKit
import CoreLocation
import Observation

// MARK: - WeatherSnapshot

/// Point-in-time snapshot of current outdoor conditions.
struct WeatherSnapshot: Equatable {
    let outdoorTemperature: Double    // °C
    let outdoorHumidity: Double       // 0–1
    let apparentTemperature: Double   // °C
    let condition: String             // WeatherCondition rawValue (e.g. "clear", "cloudy")
    let symbolName: String            // SF Symbol name
    let uvIndex: Int
    let windSpeedKmh: Double
}

// MARK: - TomorrowForecast

/// Day-level forecast for tomorrow.
struct TomorrowForecast: Equatable {
    let maxTemperature: Double         // °C
    let minTemperature: Double         // °C
    let condition: String              // WeatherCondition rawValue
    let precipitationProbability: Double  // 0–1
    let uvIndex: Int
}

// MARK: - WeatherKitService

/// Fetches local weather from WeatherKit using the home location stored in UserDefaults.
///
/// - Requires: WeatherKit capability in project entitlements.
/// - Requires: `NSWeatherKitUsageDescription` in Info.plist.
/// - Reads `location.home.lat` / `location.home.lon` set by LocationPresenceService.
/// - Graceful degradation: if location is not configured or WeatherKit throws,
///   `currentWeather` and `tomorrowForecast` remain nil without surfacing errors.
@Observable
@MainActor
final class WeatherKitService {

    // MARK: - State

    private(set) var currentWeather: WeatherSnapshot?
    private(set) var tomorrowForecast: TomorrowForecast?
    private(set) var lastUpdated: Date?
    private(set) var isLoading = false

    // MARK: - Private

    private let service = WeatherService.shared
    private var lastRefreshAt: Date?
    private let refreshCooldown: TimeInterval = 30 * 60  // 30 min

    // MARK: - Public API

    /// Fetches only if the last successful refresh is older than 30 minutes.
    func refreshIfNeeded() async {
        if let last = lastRefreshAt,
           Date().timeIntervalSince(last) < refreshCooldown { return }
        await refresh()
    }

    /// Forces an immediate fetch.
    func refresh() async {
        let lat = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey)
        let lon = UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey)
        guard lat != 0 || lon != 0 else { return }

        let location = CLLocation(latitude: lat, longitude: lon)
        isLoading = true
        defer { isLoading = false }

        do {
            let (current, daily) = try await service.weather(
                for: location,
                including: .current, .daily
            )

            currentWeather = WeatherSnapshot(
                outdoorTemperature:  current.temperature.converted(to: .celsius).value,
                outdoorHumidity:     current.humidity,
                apparentTemperature: current.apparentTemperature.converted(to: .celsius).value,
                condition:           current.condition.rawValue,
                symbolName:          current.symbolName,
                uvIndex:             current.uvIndex.value,
                windSpeedKmh:        current.wind.speed.converted(to: .kilometersPerHour).value
            )

            // daily.forecast[0] = today, [1] = tomorrow
            let forecast = daily.forecast
            if forecast.count > 1 {
                let tmr = forecast[1]
                tomorrowForecast = TomorrowForecast(
                    maxTemperature:          tmr.highTemperature.converted(to: .celsius).value,
                    minTemperature:          tmr.lowTemperature.converted(to: .celsius).value,
                    condition:               tmr.condition.rawValue,
                    precipitationProbability: tmr.precipitationChance,
                    uvIndex:                 tmr.uvIndex.value
                )
            }

            lastUpdated   = Date()
            lastRefreshAt = Date()
        } catch {
            // Graceful degradation — prior values remain until next successful fetch
            dprint("⛅ [WeatherKit] fetch error: \(error.localizedDescription)")
        }
    }
}
