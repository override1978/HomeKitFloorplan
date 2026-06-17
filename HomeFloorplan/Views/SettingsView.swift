import SwiftUI
import HomeKit
import CoreLocation

struct SettingsView: View {
    @Environment(HomeKitService.self)       private var homeKit
    @Environment(OnboardingService.self)    private var onboarding
    @Environment(WeatherKitService.self)    private var weatherKit
    @Environment(SmartLightingEngine.self)  private var smartLightingEngine

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    private var currentMarkerSize: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }

    /// Timeout salvo in secondi. Default 90s (= 1m 30s).
    @AppStorage("idleTimeout")
    private var idleTimeoutSeconds: Double = 90

    /// Unità di misura temperatura (celsius / fahrenheit).
    @AppStorage(TemperatureUnit.appStorageKey)
    private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    // MARK: - Home Location state
    @State private var showsLocationPicker = false
    @AppStorage("homeLocation.cityName") private var homeLocationCityName: String = ""

    var body: some View {
        Form {
            // MARK: - HomeKit
            
            Section {
                homeKitSection
            } header: {
                Text("HomeKit")
            } footer: {
                if homeKit.availableHomes.count > 1 {
                    Text(String(localized: "settings.homekit.footer.multi", defaultValue: "You can have multiple homes configured in Apple Home. Choose which one to manage with HomeFloorplan."))
                } else {
                    Text(String(localized: "settings.homekit.footer.single", defaultValue: "The active home determines which accessories and floorplans are visible."))
                }
            }
            
            // MARK: - Marker
            
            Section {
                MarkerPreviewView(size: currentMarkerSize)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: markerSizeRaw)
                
                Picker(String(localized: "settings.marker.size.picker", defaultValue: "Size"), selection: $markerSizeRaw) {
                    ForEach(MarkerSize.allCases) { size in
                        Text(size.localized).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(String(localized: "settings.marker.size.header", defaultValue: "Marker size"))
            } footer: {
                Text(String(localized: "settings.marker.size.footer", defaultValue: "The marker size applies to all floorplans."))
            }
            
            // MARK: - Screensaver

            Section {
                Picker(String(localized: "settings.screensaver.picker", defaultValue: "Activate after"), selection: $idleTimeoutSeconds) {
                    Text(String(localized: "settings.screensaver.30s",    defaultValue: "30 seconds")).tag(30.0)
                    Text(String(localized: "settings.screensaver.1m",     defaultValue: "1 minute")).tag(60.0)
                    Text(String(localized: "settings.screensaver.1m30s",  defaultValue: "1 min 30 sec")).tag(90.0)
                    Text(String(localized: "settings.screensaver.2m",     defaultValue: "2 minutes")).tag(120.0)
                    Text(String(localized: "settings.screensaver.5m",     defaultValue: "5 minutes")).tag(300.0)
                    Text(String(localized: "settings.screensaver.10m",    defaultValue: "10 minutes")).tag(600.0)
                    Text(String(localized: "settings.screensaver.never",  defaultValue: "Never")).tag(0.0)
                }
                .pickerStyle(.menu)
            } header: {
                Text(String(localized: "settings.screensaver.header", defaultValue: "Screen Saver"))
            } footer: {
                Text(String(localized: "settings.screensaver.footer", defaultValue: "The screen saver activates after the chosen idle period. Select \"Never\" to disable it."))
            }
            .onChange(of: idleTimeoutSeconds) { _, newValue in
                if newValue == 0 {
                    // Disabilitato: imposta un timeout molto lungo per evitare l'attivazione
                    IdleTimerService.shared.timeout = .infinity
                } else {
                    IdleTimerService.shared.timeout = newValue
                }
                IdleTimerService.shared.resetTimer()
            }

            // MARK: - Ambiente

            Section {
                // Unità temperatura
                Picker(selection: $temperatureUnitRaw) {
                    Text("°C – Celsius").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F – Fahrenheit").tag(TemperatureUnit.fahrenheit.rawValue)
                } label: {
                    Label(String(localized: "settings.environment.temperature", defaultValue: "Temperature"), systemImage: "thermometer.medium")
                }
                .pickerStyle(.menu)

                NavigationLink {
                    EnvironmentSettingsView()
                } label: {
                    Label(String(localized: "settings.environment.settings.link",
                                 defaultValue: "Environment Settings"),
                          systemImage: "leaf")
                }
            } header: {
                Text(String(localized: "settings.environment.header", defaultValue: "Environment"))
            }

            // MARK: - Posizione casa (WeatherKit)

            Section {
                homeLocationSection
            } header: {
                Text(String(localized: "settings.homeLocation.header", defaultValue: "Home Location"))
            } footer: {
                Text(String(localized: "settings.homeLocation.footer", defaultValue: "Used by WeatherKit to record outdoor temperature and humidity. Type your city or address and tap Set."))
            }

            // MARK: - Automazioni

            Section {
                NavigationLink {
                    SmartLightingSettingsView()
                } label: {
                    Label {
                        HStack {
                            Text(String(localized: "settings.smartlighting.link",
                                        defaultValue: "Smart Lighting"))
                            Spacer()
                            if smartLightingEngine.isGloballyEnabled {
                                Text(String(localized: "settings.smartlighting.on",
                                            defaultValue: "On"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "lightbulb.2.fill")
                    }
                }
            } header: {
                Text(String(localized: "settings.automations.header",
                            defaultValue: "Automations"))
            } footer: {
                Text(String(localized: "settings.automations.footer",
                            defaultValue: "Automatic scene activation based on sunrise/sunset times and ambient light."))
            }

            // MARK: - Notifiche

            Section {
                NavigationLink {
                    SecurityNotificationsSettingsView()
                } label: {
                    Label(String(localized: "settings.notifications.security.link",
                                 defaultValue: "Security Notifications"),
                          systemImage: "lock.shield.fill")
                }
            } header: {
                Text(String(localized: "settings.notifications.header", defaultValue: "Notifications"))
            }

            // MARK: - Intelligenza Artificiale

            Section {
                NavigationLink {
                    AISettingsView()
                } label: {
                    Label(String(localized: "settings.ai.link", defaultValue: "Artificial Intelligence"), systemImage: "brain")
                }
            } header: {
                Text(String(localized: "settings.ai.header", defaultValue: "AI"))
            } footer: {
                Text(String(localized: "settings.ai.footer", defaultValue: "Configure the AI provider and API keys to enable suggestions, anomalies, and predictive rules."))
            }

            Section {
                Button {
                    onboarding.resetForDebug()
                } label: {
                    Label(String(localized: "settings.developer.showOnboarding", defaultValue: "Show onboarding on next launch"), systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(.tint)
                }
#if DEBUG
                NavigationLink {
                    AITraceView()
                } label: {
                    Label("AI Pipeline Trace", systemImage: "waveform.and.magnifyingglass")
                }
                NavigationLink {
                    HabitsDiagnosticsView()
                } label: {
                    Label("Habits Diagnostics", systemImage: "brain.head.profile.fill")
                }
                #endif
            } header: {
                Text(String(localized: "settings.developer.header", defaultValue: "Developer"))
            } footer: {
                Text(String(localized: "settings.developer.footer", defaultValue: "Reset the first-run experience. Close and reopen the app to see the onboarding."))
            }
            
            // MARK: - Info
            
            Section {
                HStack {
                    Text(String(localized: "settings.info.version", defaultValue: "Version"))
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings.info.header", defaultValue: "About"))
            }
        }
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showsLocationPicker) {
            let lat = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey)
            let lon = UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey)
            let initial: CLLocationCoordinate2D? = (lat != 0 || lon != 0)
                ? CLLocationCoordinate2D(latitude: lat, longitude: lon) : nil
            HomeLocationPickerView(initialCoord: initial) { coord, cityName in
                UserDefaults.standard.set(coord.latitude,  forKey: LocationPresenceService.homeLatKey)
                UserDefaults.standard.set(coord.longitude, forKey: LocationPresenceService.homeLonKey)
                homeLocationCityName = cityName ?? ""
                Task { await weatherKit.refresh() }
            }
        }
    }

    // MARK: - Home Location

    @ViewBuilder
    private var homeLocationSection: some View {
        let lat = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey)
        let lon = UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey)
        let hasLocation = lat != 0 || lon != 0

        Button { showsLocationPicker = true } label: {
            HStack(spacing: 12) {
                Image(systemName: hasLocation ? "location.fill" : "location.slash.fill")
                    .foregroundStyle(hasLocation ? .green : .orange)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    if hasLocation {
                        let display = homeLocationCityName.isEmpty
                            ? String(format: "%.4f, %.4f", lat, lon)
                            : homeLocationCityName
                        Text(display)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(String(localized: "settings.homeLocation.configured",
                                    defaultValue: "Location set — outdoor weather active"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "settings.homeLocation.notSet",
                                    defaultValue: "Not set — outdoor weather unavailable"))
                            .font(.body)
                            .foregroundStyle(.primary)
                        Text(String(localized: "settings.homeLocation.tapToSet",
                                    defaultValue: "Tap to set your home location"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - HomeKit section
    
    @ViewBuilder
    private var homeKitSection: some View {
        let homes = homeKit.availableHomes
        
        if homes.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.homekit.noHome", defaultValue: "No home configured"))
                        .font(.body)
                    Text(String(localized: "settings.homekit.noHome.hint", defaultValue: "Set up a home in the Apple Home app to get started."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if homes.count == 1, let only = homes.first {
            HStack(spacing: 12) {
                Image(systemName: "house.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.homekit.activeHome", defaultValue: "Active home"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(only.name)
                        .font(.body)
                }
            }
        } else {
            Picker(selection: Binding(
                get: { homeKit.currentHome?.uniqueIdentifier },
                set: { newUUID in
                    if let uuid = newUUID,
                       let home = homes.first(where: { $0.uniqueIdentifier == uuid }) {
                        homeKit.setActiveHome(home)
                    } else {
                        homeKit.resetToPrimaryHome()
                    }
                }
            )) {
                ForEach(homes, id: \.uniqueIdentifier) { home in
                    HStack {
                        Text(home.name)
                        if home == homeKit.availableHomes.first(where: { _ in
                            // Indicatore visivo della primaria HomeKit
                            return false
                        }) {
                            Spacer()
                            Text(String(localized: "settings.homekit.primary", defaultValue: "Primary"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(home.uniqueIdentifier as UUID?)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.tint)
                    Text(String(localized: "settings.homekit.activeHome", defaultValue: "Active home"))
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
