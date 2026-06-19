import SwiftUI
import HomeKit
import CoreLocation
import UserNotifications

struct SettingsView: View {
    @Environment(HomeKitService.self)       private var homeKit
    @Environment(OnboardingService.self)    private var onboarding
    @Environment(WeatherKitService.self)    private var weatherKit
    @Environment(SmartLightingEngine.self)  private var smartLightingEngine
    @Environment(AISettings.self)           private var aiSettings

    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue

    @AppStorage(AppLanguage.appStorageKey)
    private var appLanguageRaw: String = AppLanguage.system.rawValue

    private var currentMarkerSize: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }

    /// Timeout salvo in secondi. Default 90s (= 1m 30s).
    @AppStorage("idleTimeout")
    private var idleTimeoutSeconds: Double = 90

    /// Unità di misura temperatura (celsius / fahrenheit).
    @AppStorage(TemperatureUnit.appStorageKey)
    private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    @AppStorage("alertNotificationsEnabled")
    private var alertNotificationsEnabled: Bool = false

    @AppStorage(SecurityNotificationService.enabledKey)
    private var securityNotificationsEnabled: Bool = false

    // MARK: - Home Location state
    @State private var showsLocationPicker = false
    @State private var showsLanguageRestartAlert = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("homeLocation.cityName") private var homeLocationCityName: String = ""

    var body: some View {
        Form {
            // MARK: - Home & Floorplan

            Section {
                homeKitSection

                MarkerPreviewView(size: currentMarkerSize)
                    .animation(.spring(response: 0.35, dampingFraction: 0.85),
                               value: markerSizeRaw)

                Picker(String(localized: "settings.marker.size.picker", defaultValue: "Size"), selection: $markerSizeRaw) {
                    ForEach(MarkerSize.allCases) { size in
                        Text(size.localizationKey).tag(size.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                NavigationLink {
                    HomeKitDebugView()
                } label: {
                    settingsLinkRow(
                        icon: "stethoscope",
                        title: String(localized: "settings.homekit.diagnostics", defaultValue: "Support Diagnostics"),
                        subtitle: String(localized: "settings.homekit.diagnostics.subtitle", defaultValue: "Export HomeKit accessory details for troubleshooting.")
                    )
                }
            } header: {
                Text(String(localized: "settings.section.homeFloorplan", defaultValue: "Home & Floorplan"))
            } footer: {
                if homeKit.availableHomes.count > 1 {
                    Text(String(localized: "settings.homekit.footer.multi", defaultValue: "You can have multiple homes configured in Apple Home. Choose which one to manage with HomeFloorplan."))
                } else {
                    Text(String(localized: "settings.homekit.footer.single", defaultValue: "The active home determines which accessories and floorplans are visible."))
                }
            }

            // MARK: - Notifications

            Section {
                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "bell.badge",
                        title: String(localized: "settings.notifications.center.link", defaultValue: "Notifications"),
                        subtitle: String(localized: "settings.notifications.center.subtitle", defaultValue: "Manage security, environment, and intelligence notifications."),
                        status: notificationsSummaryText,
                        statusColor: notificationsSummaryColor
                    )
                }
            } header: {
                Text(String(localized: "settings.notifications.center.header", defaultValue: "Notifications"))
            } footer: {
                Text(String(localized: "settings.notifications.center.footer", defaultValue: "Choose which events can interrupt you and which should stay in the app."))
            }

            // MARK: - Environment

            Section {
                Picker(selection: $temperatureUnitRaw) {
                    Text("°C – Celsius").tag(TemperatureUnit.celsius.rawValue)
                    Text("°F – Fahrenheit").tag(TemperatureUnit.fahrenheit.rawValue)
                } label: {
                    Label(String(localized: "settings.environment.temperature", defaultValue: "Temperature"), systemImage: "thermometer.medium")
                }
                .pickerStyle(.menu)

                homeLocationSection

                NavigationLink {
                    EnvironmentSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "leaf",
                        title: String(localized: "settings.environment.settings.link", defaultValue: "Environment Settings"),
                        subtitle: String(localized: "settings.environment.settings.subtitle", defaultValue: "Outdoor sensors, environmental alerts, and thresholds.")
                    )
                }
            } header: {
                Text(String(localized: "settings.environment.header", defaultValue: "Environment"))
            } footer: {
                Text(String(localized: "settings.homeLocation.footer", defaultValue: "Used by WeatherKit to record outdoor temperature and humidity. Type your city or address and tap Set."))
            }

            // MARK: - Automations

            Section {
                NavigationLink {
                    SmartLightingSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "lightbulb.2.fill",
                        title: String(localized: "settings.smartlighting.link", defaultValue: "Smart Lighting"),
                        subtitle: String(localized: "settings.smartlighting.subtitle", defaultValue: "Advanced ambient lighting based on daylight and room profiles."),
                        status: smartLightingStatusText,
                        statusColor: smartLightingEngine.isGloballyEnabled ? .green : .secondary,
                        badge: String(localized: "settings.badge.advanced", defaultValue: "Advanced")
                    )
                }
            } header: {
                Text(String(localized: "settings.automations.header", defaultValue: "Automations"))
            } footer: {
                Text(String(localized: "settings.automations.footer", defaultValue: "Automatic scene activation based on sunrise/sunset times and ambient light."))
            }

            // MARK: - Home Intelligence

            Section {
                NavigationLink {
                    AISettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "brain",
                        title: String(localized: "settings.ai.link", defaultValue: "Home Intelligence"),
                        subtitle: String(localized: "settings.ai.summary", defaultValue: "AI insights, habit suggestions, anomaly summaries, and assistant features."),
                        status: aiStatusText,
                        statusColor: aiStatusColor
                    )
                }
            } header: {
                Text(String(localized: "settings.ai.header", defaultValue: "Home Intelligence"))
            } footer: {
                Text(String(localized: "settings.ai.footer", defaultValue: "Configure the AI provider and API keys to enable suggestions, anomalies, and predictive rules."))
            }

            // MARK: - App

            Section {
                Picker(String(localized: "settings.language.picker", defaultValue: "App Language"), selection: $appLanguageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                }
                .pickerStyle(.menu)

                if AppLanguage.resolved(from: appLanguageRaw) != .system {
                    Text(String(localized: "settings.language.restartHint", defaultValue: "Restart the app to apply the selected language everywhere."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

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

                HStack {
                    Text(String(localized: "settings.info.version", defaultValue: "Version"))
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings.section.app", defaultValue: "App"))
            } footer: {
                Text(String(localized: "settings.app.footer", defaultValue: "Language changes require an app restart."))
            }
            .onChange(of: appLanguageRaw) { _, newValue in
                AppLanguage.apply(rawValue: newValue)
                showsLanguageRestartAlert = true
            }
            .onChange(of: idleTimeoutSeconds) { _, newValue in
                if newValue == 0 {
                    IdleTimerService.shared.timeout = .infinity
                } else {
                    IdleTimerService.shared.timeout = newValue
                }
                IdleTimerService.shared.resetTimer()
            }

            // MARK: - Developer

            Section {
                Button {
                    onboarding.resetForDebug()
                } label: {
                    Label(String(localized: "settings.developer.showOnboarding", defaultValue: "Show onboarding on next launch"), systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(BrandColor.primary)
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
        }
        .tint(BrandColor.primary)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refreshNotificationAuthorizationStatus() }
        .alert(
            String(localized: "settings.language.restart.title", defaultValue: "Restart required"),
            isPresented: $showsLanguageRestartAlert
        ) {
            Button(String(localized: "common.ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.language.restart.message", defaultValue: "Close and reopen the app to apply the selected language to every screen."))
        }
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

    // MARK: - Status helpers

    private var aiStatusText: String {
        if aiSettings.isOperational {
            return String(localized: "settings.status.ready", defaultValue: "Ready")
        }
        if !aiSettings.isAIEnabled {
            return String(localized: "settings.status.off", defaultValue: "Off")
        }
        if !aiSettings.hasAIDataConsent {
            return String(localized: "settings.ai.status.consent", defaultValue: "Consent needed")
        }
        if !aiSettings.hasAPIKey {
            return String(localized: "settings.ai.status.missingKey", defaultValue: "Missing key")
        }
        if aiSettings.lastConnectionSuccess == false {
            return String(localized: "settings.ai.status.testFailed", defaultValue: "Test failed")
        }
        return String(localized: "settings.status.needsSetup", defaultValue: "Needs setup")
    }

    private var aiStatusColor: Color {
        if aiSettings.isOperational { return .green }
        if aiSettings.isAIEnabled && aiSettings.lastConnectionSuccess == false { return .red }
        if aiSettings.isAIEnabled { return .orange }
        return .secondary
    }

    private var smartLightingStatusText: String {
        smartLightingEngine.isGloballyEnabled
        ? String(localized: "settings.status.on", defaultValue: "On")
        : String(localized: "settings.status.off", defaultValue: "Off")
    }

    private var notificationsSummaryText: String {
        if notificationAuthorizationStatus == .denied {
            return String(localized: "settings.notifications.status.denied", defaultValue: "Denied")
        }
        if alertNotificationsEnabled || securityNotificationsEnabled {
            return notificationPermissionStatusText
        }
        return String(localized: "settings.status.off", defaultValue: "Off")
    }

    private var notificationsSummaryColor: Color {
        if notificationAuthorizationStatus == .denied { return .red }
        if alertNotificationsEnabled || securityNotificationsEnabled {
            return notificationPermissionStatusColor
        }
        return .secondary
    }

    private var notificationPermissionStatusText: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return String(localized: "settings.notifications.status.allowed", defaultValue: "Allowed")
        case .denied:
            return String(localized: "settings.notifications.status.denied", defaultValue: "Denied")
        case .notDetermined:
            return String(localized: "settings.notifications.status.notAsked", defaultValue: "Not asked")
        @unknown default:
            return String(localized: "settings.notifications.status.unknown", defaultValue: "Unknown")
        }
    }

    private var notificationPermissionStatusColor: Color {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .orange
        @unknown default:
            return .secondary
        }
    }

    private func refreshNotificationAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notificationAuthorizationStatus = settings.authorizationStatus
            }
        }
    }

    private func settingsLinkRow(
        icon: String,
        title: String,
        subtitle: String,
        status: String? = nil,
        statusColor: Color = .secondary,
        badge: String? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let badge {
                        statusPill(badge, color: .orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let status {
                statusPill(status, color: statusColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
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
                    .foregroundStyle(BrandColor.primary)
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
                    Text(home.name)
                        .tag(home.uniqueIdentifier as UUID?)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(BrandColor.primary)
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
