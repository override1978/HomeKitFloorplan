import Foundation
import CoreLocation
import Observation

// MARK: - LocationPresenceService

/// Opt-in geofencing service that detects home departure and arrival while the app has location access.
///
/// The user must explicitly call `enable(latitude:longitude:)`. Location data is
/// never used for any purpose beyond determining whether the user is inside the
/// home geofence — no coordinates are stored remotely.
///
/// CLLocationManagerDelegate callbacks are nonisolated; they bridge to @MainActor
/// via `Task { @MainActor in ... }` to avoid Sendability violations.
@Observable
@MainActor
final class LocationPresenceService: NSObject {

    // MARK: - State

    /// Presence derived from geofencing events, or nil when not yet known.
    private(set) var presenceState:       PresenceState?
    /// True when the CLCircularRegion is actively monitored.
    private(set) var isMonitoring:        Bool = false
    /// Non-nil when authorization was denied or monitoring failed.
    private(set) var authorizationError:  String?

    // MARK: - UserDefaults keys

    static let enabledKey    = "location.presence.enabled"
    static let homeLatKey    = "location.home.lat"
    static let homeLonKey    = "location.home.lon"
    static let homeRadiusKey = "location.home.radius"

    private static let regionID = "com.homefloorplan.homeRegion"

    // MARK: - Private

    private let manager:    CLLocationManager
    private var homeRegion: CLCircularRegion?

    // MARK: - Init

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate         = self
        manager.desiredAccuracy  = kCLLocationAccuracyHundredMeters
        if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            restoreMonitoring()
        }
    }

    // MARK: - Public API

    /// Requests location authorization and starts monitoring the home geofence.
    ///
    /// - Parameters:
    ///   - latitude:      Home coordinate latitude.
    ///   - longitude:     Home coordinate longitude.
    ///   - radiusMeters:  Geofence radius (default 150 m).
    func enable(latitude: Double, longitude: Double, radiusMeters: Double = 150) {
        UserDefaults.standard.set(true,         forKey: Self.enabledKey)
        UserDefaults.standard.set(latitude,     forKey: Self.homeLatKey)
        UserDefaults.standard.set(longitude,    forKey: Self.homeLonKey)
        UserDefaults.standard.set(radiusMeters, forKey: Self.homeRadiusKey)
        startMonitoring(lat: latitude, lon: longitude, radius: radiusMeters)
    }

    /// Stops monitoring and clears the stored home location.
    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        if let region = homeRegion { manager.stopMonitoring(for: region) }
        homeRegion     = nil
        isMonitoring   = false
        presenceState  = nil
    }

    // MARK: - Private

    private func restoreMonitoring() {
        let lat    = UserDefaults.standard.double(forKey: Self.homeLatKey)
        let lon    = UserDefaults.standard.double(forKey: Self.homeLonKey)
        let radius = UserDefaults.standard.double(forKey: Self.homeRadiusKey)
        guard lat != 0, lon != 0 else { return }
        startMonitoring(lat: lat, lon: lon, radius: radius > 0 ? radius : 150)
    }

    private func startMonitoring(lat: Double, lon: Double, radius: Double) {
        let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let region = CLCircularRegion(center: center, radius: radius,
                                      identifier: Self.regionID)
        region.notifyOnEntry = true
        region.notifyOnExit  = true
        homeRegion = region

        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startMonitoring(for: region)
            isMonitoring    = true
            authorizationError = nil
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            authorizationError = String(localized: "location.authDenied",
                defaultValue: "Permesso posizione negato. Abilitalo in Impostazioni > Privacy.")
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationPresenceService: CLLocationManagerDelegate {

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                if let region = homeRegion {
                    manager.startMonitoring(for: region)
                    isMonitoring       = true
                    authorizationError = nil
                }
            case .denied, .restricted:
                isMonitoring       = false
                authorizationError = String(localized: "location.authDenied",
                    defaultValue: "Permesso posizione negato. Abilitalo in Impostazioni > Privacy.")
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didEnterRegion region: CLRegion) {
        guard region.identifier == LocationPresenceService.regionID else { return }
        Task { @MainActor [weak self] in self?.presenceState = .home }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didExitRegion region: CLRegion) {
        guard region.identifier == LocationPresenceService.regionID else { return }
        Task { @MainActor [weak self] in self?.presenceState = .away }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        Task { @MainActor [weak self] in
            self?.isMonitoring = false
        }
    }
}
