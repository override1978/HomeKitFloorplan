import SwiftUI
import SwiftData
import HomeKit
import CoreLocation
import UserNotifications

struct SettingsView: View {
    @Environment(HomeKitService.self)       private var homeKit
    @Environment(OnboardingService.self)    private var onboarding
    @Environment(WeatherKitService.self)    private var weatherKit
    @Environment(SmartLightingEngine.self)  private var smartLightingEngine
    @Environment(AISettings.self)           private var aiSettings
    @Environment(RuleEngineService.self)    private var ruleEngine
    @Environment(CloudKitSyncService.self)  private var cloudKitSync

    @Query(sort: \SyncableSettings.modifiedAt) var settingsArray: [SyncableSettings]
    private var syncableSettings: SyncableSettings? { settingsArray.first }

    private var deviceRole: String {
        guard let s = syncableSettings, !s.masterDeviceID.isEmpty else {
            return String(localized: "settings.device.role.master", defaultValue: "Primary")
        }
        return s.masterDeviceID == DeviceIdentity.id
            ? String(localized: "settings.device.role.master", defaultValue: "Primary")
            : String(localized: "settings.device.role.slave",  defaultValue: "Secondary")
    }

    private var isMasterDevice: Bool {
        guard let s = syncableSettings else { return true }
        return s.masterDeviceID.isEmpty || s.masterDeviceID == DeviceIdentity.id
    }

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

    @AppStorage(AppLanguage.appStorageKey)
    private var appLanguageRaw: String = AppLanguage.english.rawValue

    @AppStorage(DimensionUnit.appStorageKey)
    private var dimensionUnitRaw: String = DimensionUnit.metric.rawValue

    @AppStorage("alertNotificationsEnabled")
    private var alertNotificationsEnabled: Bool = false

    @AppStorage(SecurityNotificationService.enabledKey)
    private var securityNotificationsEnabled: Bool = false

    // MARK: - Home Location state
    @State private var showsLocationPicker = false
    @State private var showLanguageRestartAlert = false
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

                Picker(selection: $dimensionUnitRaw) {
                    Text(String(localized: "settings.drawing.dimensionUnit.metric",   defaultValue: "m – Metric")).tag(DimensionUnit.metric.rawValue)
                    Text(String(localized: "settings.drawing.dimensionUnit.imperial", defaultValue: "ft – Imperial")).tag(DimensionUnit.imperial.rawValue)
                } label: {
                    Label(String(localized: "settings.drawing.dimensionUnit", defaultValue: "Measurements"), systemImage: "ruler")
                }
                .pickerStyle(.menu)

#if DEBUG
                NavigationLink {
                    HomeKitDebugView()
                } label: {
                    settingsLinkRow(
                        icon: "stethoscope",
                        title: String(localized: "settings.homekit.diagnostics", defaultValue: "Support Diagnostics"),
                        subtitle: String(localized: "settings.homekit.diagnostics.subtitle", defaultValue: "Export HomeKit accessory details for troubleshooting.")
                    )
                }
#endif
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

            // MARK: - iCloud

            Section {
                iCloudSyncRow
                ShareLink(item: SyncDiagnosticsLogger.fileURL) {
                    Label(
                        String(localized: "settings.icloud.diagnostics.export", defaultValue: "Export Sync Diagnostics"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                Button(role: .destructive) {
                    SyncDiagnosticsLogger.clear()
                } label: {
                    Label(
                        String(localized: "settings.icloud.diagnostics.clear", defaultValue: "Clear Sync Diagnostics"),
                        systemImage: "trash"
                    )
                }
            } header: {
                Text(String(localized: "settings.icloud.header", defaultValue: "iCloud"))
            } footer: {
                Text(String(localized: "settings.icloud.footer", defaultValue: "Floorplans, settings, and automation opportunities sync automatically via iCloud."))
            }

            // MARK: - Device Role

            Section {
                HStack {
                    Label(String(localized: "settings.device.role.label", defaultValue: "Device Role"), systemImage: isMasterDevice ? "iphone.badge.play" : "iphone")
                    Spacer()
                    Text(deviceRole)
                        .foregroundStyle(.secondary)
                }
                if !isMasterDevice {
                    Button {
                        cloudKitSync.becomeMaster()
                    } label: {
                        Label(String(localized: "settings.device.becomeMaster", defaultValue: "Become Primary Device"), systemImage: "crown")
                            .foregroundStyle(.tint)
                    }
                }
            } header: {
                Text(String(localized: "settings.device.header", defaultValue: "This Device"))
            } footer: {
                if isMasterDevice {
                    Text(String(localized: "settings.device.master.footer", defaultValue: "This device runs behavioral analysis and generates automation suggestions."))
                } else {
                    Text(String(localized: "settings.device.slave.footer", defaultValue: "This device receives data from iCloud. Tap \"Become Primary\" to run analysis here instead."))
                }
            }

            // MARK: - App

            Section {
                Picker(selection: $appLanguageRaw) {
                    ForEach(AppLanguage.selectableLanguages) { language in
                        Text(language.displayName).tag(language.rawValue)
                    }
                } label: {
                    Label(String(localized: "settings.language.picker", defaultValue: "App Language"), systemImage: "globe")
                }
                .pickerStyle(.menu)

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
                Text(String(localized: "settings.language.restartHint", defaultValue: "Language changes are applied after closing and reopening the app on iPad."))
            }
            .onChange(of: idleTimeoutSeconds) { _, newValue in
                if newValue == 0 {
                    IdleTimerService.shared.timeout = .infinity
                } else {
                    IdleTimerService.shared.timeout = newValue
                }
                IdleTimerService.shared.resetTimer()
            }
            .onChange(of: appLanguageRaw) { _, newValue in
                AppLanguage.apply(rawValue: newValue)
                showLanguageRestartAlert = true
            }
            .alert(String(localized: "settings.language.restartAlert.title", defaultValue: "Restart required"),
                   isPresented: $showLanguageRestartAlert) {
                Button(String(localized: "button.ok", defaultValue: "OK")) {}
            } message: {
                Text(String(localized: "settings.language.restartAlert.message", defaultValue: "Close and reopen Home Floorplan on this iPad to apply the selected language everywhere."))
            }

#if DEBUG
            // MARK: - Developer

            Section {
                Button {
                    onboarding.resetForDebug()
                } label: {
                    Label(String(localized: "settings.developer.showOnboarding", defaultValue: "Show onboarding on next launch"), systemImage: "arrow.clockwise.circle")
                        .foregroundStyle(BrandColor.primary)
                }
                NavigationLink {
                    ActivityLogView()
                } label: {
                    settingsLinkRow(
                        icon: "clock.arrow.circlepath",
                        title: String(localized: "settings.diagnostics.activityLog", defaultValue: "Activity Log"),
                        subtitle: String(localized: "settings.diagnostics.activityLog.subtitle", defaultValue: "Review recent app actions for troubleshooting.")
                    )
                }
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
                NavigationLink {
                    LegacyAutomationCleanupView()
                } label: {
                    settingsLinkRow(
                        icon: "trash.circle",
                        title: "Legacy Rule Cleanup",
                        subtitle: "\(ruleEngine.rules.count) local legacy rules"
                    )
                }
            } header: {
                Text(String(localized: "settings.developer.header", defaultValue: "Developer"))
            } footer: {
                Text(String(localized: "settings.developer.footer", defaultValue: "Reset the first-run experience. Close and reopen the app to see the onboarding."))
            }
#endif
        }
        .tint(BrandColor.primary)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear { refreshNotificationAuthorizationStatus() }
        .sheet(isPresented: $showsLocationPicker) {
            let lat = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey)
            let lon = UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey)
            let initial: CLLocationCoordinate2D? = (lat != 0 || lon != 0)
                ? CLLocationCoordinate2D(latitude: lat, longitude: lon) : nil
            HomeLocationPickerView(initialCoord: initial) { coord, cityName in
                UserDefaults.standard.set(coord.latitude,  forKey: LocationPresenceService.homeLatKey)
                UserDefaults.standard.set(coord.longitude, forKey: LocationPresenceService.homeLonKey)
                homeLocationCityName = cityName ?? ""
                cloudKitSync.markSettingsNeedsSync()
                Task { await weatherKit.refresh() }
            }
        }
        .onChange(of: aiSettings.selectedProvider) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.isAIEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.suggestionsEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.anomalyDetectionEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.ruleEngineEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.hasAIDataConsent) { _, _ in syncAISettingsToCloud() }
    }

    private func syncAISettingsToCloud() {
        guard !cloudKitSync.isApplyingRemoteSettings else { return }
        guard let syncableSettings else { return }
        syncableSettings.aiProviderRaw             = aiSettings.selectedProvider.rawValue
        syncableSettings.aiIsEnabled               = aiSettings.isAIEnabled
        syncableSettings.aiSuggestionsEnabled      = aiSettings.suggestionsEnabled
        syncableSettings.aiAnomalyDetectionEnabled = aiSettings.anomalyDetectionEnabled
        syncableSettings.aiRuleEngineEnabled       = aiSettings.ruleEngineEnabled
        syncableSettings.aiHasDataConsent          = aiSettings.hasAIDataConsent
        syncableSettings.modifiedAt                = .now
        cloudKitSync.syncAfterSave()
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

    // MARK: - iCloud Sync Row

    @ViewBuilder
    private var iCloudSyncRow: some View {
        HStack(spacing: 12) {
            if cloudKitSync.isSyncing {
                ProgressView()
                    .frame(width: 28)
            } else if cloudKitSync.lastError != nil {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 28)
            } else {
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(cloudKitSync.lastSyncedAt != nil ? .green : .secondary)
                    .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "settings.icloud.sync.title", defaultValue: "Sync status"))
                    .foregroundStyle(.primary)

                if cloudKitSync.isSyncing {
                    Text(String(localized: "settings.icloud.status.syncing", defaultValue: "Syncing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let error = cloudKitSync.lastError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let date = cloudKitSync.lastSyncedAt {
                    Text(String(
                        format: String(localized: "settings.icloud.status.lastSync",
                                       defaultValue: "Last synced %@"),
                        date.formatted(.relative(presentation: .named))
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "settings.icloud.status.notYet", defaultValue: "Not yet synced"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let settings = syncableSettings {
                    Text("Settings: \(settings.masterDeviceID == DeviceIdentity.id ? "Primary" : "Secondary") · AI \(settings.aiIsEnabled ? "On" : "Off")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if cloudKitSync.lastError != nil {
                statusPill(
                    String(localized: "settings.icloud.status.error", defaultValue: "Error"),
                    color: .red
                )
            } else if cloudKitSync.isSyncing {
                statusPill(
                    String(localized: "settings.icloud.status.active", defaultValue: "Active"),
                    color: BrandColor.primary
                )
            } else if cloudKitSync.lastSyncedAt != nil {
                statusPill(
                    String(localized: "settings.icloud.status.ok", defaultValue: "In sync"),
                    color: .green
                )
            }
        }
        .padding(.vertical, 2)
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

#if DEBUG
private struct LegacyAutomationCleanupView: View {
    @Environment(RuleEngineService.self) private var ruleEngine
    @Environment(HomeKitService.self) private var homeKit

    @State private var showDeleteAllConfirmation = false
    @State private var isDeleting = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(localized: "settings.legacyCleanup.summary.title", defaultValue: "Legacy local rules"))
                            .font(.headline)
                        Text(String(localized: "settings.legacyCleanup.summary.description", defaultValue: "These records belong to the old Rule system. Deleting them does not remove habits, events, insights, proposals, or HomeKit automations created with the new builder."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if ruleEngine.rules.isEmpty {
                    ContentUnavailableView(
                        String(localized: "settings.legacyCleanup.empty.title", defaultValue: "No legacy rules"),
                        systemImage: "checkmark.circle",
                        description: Text(String(localized: "settings.legacyCleanup.empty.description", defaultValue: "The local legacy Rule store is already clean."))
                    )
                } else {
                    ForEach(ruleEngine.rules) { rule in
                        LegacyRuleCleanupRow(rule: rule)
                    }
                    .onDelete { offsets in
                        deleteRules(at: offsets)
                    }
                }
            } header: {
                Text(String(localized: "settings.legacyCleanup.storedRules", defaultValue: "Stored Rules"))
            }

            if !ruleEngine.rules.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showDeleteAllConfirmation = true
                    } label: {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Label(String(localized: "settings.legacyCleanup.deleteAll", defaultValue: "Delete all legacy rules"), systemImage: "trash")
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text(String(localized: "settings.legacyCleanup.footer", defaultValue: "Only SwiftData Rule records are deleted. If a legacy rule has a linked HomeKit trigger ID, the cleanup also asks HomeKit to remove that old trigger."))
                }
            }
        }
        .navigationTitle(String(localized: "settings.legacyCleanup.title", defaultValue: "Legacy Cleanup"))
        .alert(String(localized: "settings.legacyCleanup.confirm.title", defaultValue: "Delete all legacy rules?"), isPresented: $showDeleteAllConfirmation) {
            Button(String(localized: "button.delete", defaultValue: "Delete"), role: .destructive) {
                deleteAllRules()
            }
            Button(String(localized: "button.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "settings.legacyCleanup.confirm.message", defaultValue: "This removes only old local Rule records and their linked legacy HomeKit triggers when available."))
        }
    }

    private func deleteRules(at offsets: IndexSet) {
        let rules = offsets.map { ruleEngine.rules[$0] }
        delete(rules)
    }

    private func deleteAllRules() {
        delete(ruleEngine.rules)
    }

    private func delete(_ rules: [Rule]) {
        guard !rules.isEmpty else { return }
        isDeleting = true
        Task {
            for rule in rules {
                try? await ruleEngine.deleteRule(rule, home: homeKit.currentHome)
            }
            isDeleting = false
        }
    }
}

private struct LegacyRuleCleanupRow: View {
    let rule: Rule

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(rule.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(rule.isEnabled ? "Enabled" : "Paused")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(rule.isEnabled ? .green : .secondary)
            }

            Text(rule.ruleDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label(rule.triggerType, systemImage: "bolt.horizontal")
                Label(rule.actionType, systemImage: "slider.horizontal.3")
                if rule.homeKitTriggerID != nil {
                    Label("HomeKit", systemImage: "house.fill")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
#endif

private extension Bundle {
    var appVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
