import SwiftUI
import MapKit
import CoreLocation

// MARK: - HomeLocationPickerView

/// Full-screen map picker for selecting the home coordinate used by WeatherKit.
///
/// UX: the map moves freely; a fixed house-pin overlay stays centred on screen.
/// Confirming saves whatever coordinate is under the pin. A "Use current location"
/// button fires a one-shot CLLocationManager request and re-centres the camera.
struct HomeLocationPickerView: View {

    /// Called with the confirmed coordinate and optional reverse-geocoded city name.
    let onConfirm: (CLLocationCoordinate2D, String?) -> Void

    // Map state
    @State private var position:     MapCameraPosition
    @State private var centerCoord:  CLLocationCoordinate2D
    @State private var locationName: String = ""
    @State private var isGeocoding   = false

    // One-shot location fetch
    @State private var fetcher = LocationFetcher()

    @Environment(\.dismiss) private var dismiss

    init(
        initialCoord: CLLocationCoordinate2D?,
        onConfirm: @escaping (CLLocationCoordinate2D, String?) -> Void
    ) {
        self.onConfirm = onConfirm
        let coord = initialCoord ?? CLLocationCoordinate2D(latitude: 45.4654, longitude: 9.1866)
        _centerCoord = State(initialValue: coord)
        _position    = State(initialValue: .region(MKCoordinateRegion(
            center: coord,
            latitudinalMeters: 5_000,
            longitudinalMeters: 5_000
        )))
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                map
                pinOverlay
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(String(localized: "settings.homeLocation.picker.title",
                                    defaultValue: "Set Home Location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task { reverseGeocode(centerCoord) }
        }
    }

    // MARK: - Map

    private var map: some View {
        Map(position: $position)
            .onMapCameraChange(frequency: .onEnd) { ctx in
                centerCoord = ctx.camera.centerCoordinate
                reverseGeocode(centerCoord)
            }
    }

    // MARK: - Pin overlay (fixed at screen centre)

    private var pinOverlay: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                Image(systemName: "house.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
            }

            // Pin stem
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2, height: 10)

            // Shadow dot at tip
            Ellipse()
                .fill(Color.black.opacity(0.20))
                .frame(width: 10, height: 4)
        }
        // Shift up so the tip of the stem sits at the visual centre of the map.
        .offset(y: -(20 + 5 + 2))
        .allowsHitTesting(false)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 12) {
                // Current location label
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    Group {
                        if isGeocoding {
                            ProgressView().scaleEffect(0.85)
                        } else if !locationName.isEmpty {
                            Text(locationName)
                                .font(.subheadline.weight(.medium))
                        } else {
                            Text(String(format: "%.4f, %.4f",
                                        centerCoord.latitude, centerCoord.longitude))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }

                // Use current location button
                Button {
                    Task { await useCurrentLocation() }
                } label: {
                    if fetcher.isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label(
                            String(localized: "settings.homeLocation.picker.useCurrentLocation",
                                   defaultValue: "Use current location"),
                            systemImage: "location.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(fetcher.isLoading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button(String(localized: "settings.homeLocation.picker.cancel",
                          defaultValue: "Cancel")) {
                dismiss()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(String(localized: "settings.homeLocation.picker.confirm",
                          defaultValue: "Confirm")) {
                onConfirm(centerCoord, locationName.isEmpty ? nil : locationName)
                dismiss()
            }
            .fontWeight(.semibold)
        }
    }

    // MARK: - Helpers

    private func reverseGeocode(_ coord: CLLocationCoordinate2D) {
        isGeocoding = true
        Task {
            let loc        = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let placemarks = try? await CLGeocoder().reverseGeocodeLocation(loc)
            locationName   = [placemarks?.first?.locality, placemarks?.first?.country]
                .compactMap { $0 }.joined(separator: ", ")
            isGeocoding = false
        }
    }

    private func useCurrentLocation() async {
        do {
            let loc = try await fetcher.fetch()
            centerCoord = loc.coordinate
            position    = .region(MKCoordinateRegion(
                center: loc.coordinate,
                latitudinalMeters: 5_000,
                longitudinalMeters: 5_000
            ))
            reverseGeocode(loc.coordinate)
        } catch {
            // User denied or location unavailable — stay on current map position.
        }
    }
}

// MARK: - LocationFetcher

/// One-shot CLLocationManager wrapper: calls `requestLocation()` once and delivers
/// the result via async/await. Handles `requestWhenInUseAuthorization()` if needed.
@Observable
@MainActor
private final class LocationFetcher: NSObject, CLLocationManagerDelegate {

    private(set) var isLoading = false

    private let manager   = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate        = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func fetch() async throws -> CLLocation {
        isLoading = true
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                cont.resume(throwing: FetchError.denied)
                self.continuation = nil
                self.isLoading    = false
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.first else { return }
        Task { @MainActor [weak self] in
            self?.continuation?.resume(returning: loc)
            self?.continuation = nil
            self?.isLoading    = false
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.continuation?.resume(throwing: error)
            self?.continuation = nil
            self?.isLoading    = false
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .denied, .restricted:
                self?.continuation?.resume(throwing: FetchError.denied)
                self?.continuation = nil
                self?.isLoading    = false
            default:
                break
            }
        }
    }

    enum FetchError: LocalizedError {
        case denied
        var errorDescription: String? {
            String(localized: "settings.homeLocation.picker.locationDenied",
                   defaultValue: "Location access denied. Move the map to your home manually.")
        }
    }
}
