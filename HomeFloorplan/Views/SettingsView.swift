import SwiftUI
import SwiftData
import HomeKit
import CoreLocation
import UserNotifications

struct SettingsView: View {
    /// €/kWh per stimare i costi dai consumi misurati. 0 = niente costi in UI,
    /// solo energia: meglio nessun numero che un numero inventato.
    @AppStorage("energy.tariffPerKWh") private var energyTariffPerKWh = 0.0
    /// Finché è true nessuna potatura tocca letture ed eventi grezzi. Il
    /// default è `false` come in `LocalDataProtection`: i due valori devono
    /// coincidere, altrimenti l'interruttore mostra uno stato e il ciclo dati
    /// ne applica un altro.
    @Environment(HomeKitService.self)       private var homeKit
    @Environment(OnboardingService.self)    private var onboarding
    @Environment(WeatherKitService.self)    private var weatherKit
    @Environment(AISettings.self)           private var aiSettings
    @Environment(SmartLightingEngine.self)  private var smartLightingEngine
    @Environment(CloudKitSyncService.self)  private var cloudKitSync
    @Environment(DataLifecycleService.self) private var dataLifecycleService
    /// Spento di default: una casa non legge gli impegni di nessuno finché
    /// non glielo si chiede.
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Serve ancora qui: `syncAISettingsToCloud()` scrive le preferenze AI nel
    /// record condiviso. Il ruolo del dispositivo invece è migrato in
    /// `ICloudSettingsView`, che è l'unica schermata che lo mostra.
    @Query(sort: \SyncableSettings.modifiedAt) private var settingsArray: [SyncableSettings]
    private var syncableSettings: SyncableSettings? { settingsArray.first }

    @AppStorage("alertNotificationsEnabled")
    private var alertNotificationsEnabled: Bool = false

    @AppStorage(SecurityNotificationService.enabledKey)
    private var securityNotificationsEnabled: Bool = false

    // MARK: - Home Location state
    @State private var showsLocationPicker = false
    @State private var notificationAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @AppStorage("homeLocation.cityName") private var homeLocationCityName: String = ""

    var body: some View {
        Form {
            // MARK: - Casa

            Section {
                homeKitSection
                homeLocationSection
            } header: {
                Text(String(localized: "settings.section.home", defaultValue: "Home"))
            } footer: {
                if homeKit.availableHomes.count > 1 {
                    Text(String(localized: "settings.homekit.footer.multi", defaultValue: "You can have multiple homes configured in Apple Home. Choose which one to manage with HomeFloorplan."))
                }
            }

            // MARK: - Personalizza

            Section {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "paintbrush",
                        title: String(localized: "settings.appearance.title", defaultValue: "Floorplan"),
                        subtitle: String(localized: "settings.appearance.subtitle", defaultValue: "Markers, effects, day ribbon, and screen saver.")
                    )
                }

                NavigationLink {
                    LanguageAndUnitsSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "globe",
                        title: String(localized: "settings.languageUnits.title", defaultValue: "Language & Units"),
                        subtitle: String(localized: "settings.languageUnits.subtitle", defaultValue: "App language, measurements, and temperature.")
                    )
                }
            } header: {
                Text(String(localized: "settings.section.customize", defaultValue: "Customize"))
            }

            // MARK: - Intelligenza

            Section {
                NavigationLink {
                    AISettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "brain",
                        title: String(localized: "settings.ai.link", defaultValue: "Home Intelligence"),
                        subtitle: String(localized: "settings.ai.summary.v2", defaultValue: "AI insights, anomaly summaries, and assistant features."),
                        status: aiStatusText,
                        statusColor: aiStatusColor
                    )
                }


#if DEBUG
                // Visibile solo in sviluppo, come Energia: e'
                // l'unico ingresso a Smart Lighting e anche l'unico posto da
                // cui si accende, quindi fuori dal debug il motore resta spento
                // e irraggiungibile.
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
#endif

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
                Text(String(localized: "settings.section.intelligence", defaultValue: "Intelligence"))
            }

            // MARK: - Notifiche

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
            }

#if DEBUG
            // La tariffa serve solo alle viste Energia, che nelle
            // build distribuite non esistono: senza schermate che la
            // leggano sarebbe un campo che non fa niente.
            // MARK: - Energia

            Section {
                HStack(spacing: 12) {
                    Label {
                        Text(String(localized: "settings.energy.tariff.title",
                                    defaultValue: "Energy price"))
                    } icon: {
                        Image(systemName: "bolt.circle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Spacer()
                    TextField("0",
                              value: $energyTariffPerKWh,
                              format: .number.precision(.fractionLength(0...4)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90)
                    Text(verbatim: "\(Locale.current.currencySymbol ?? "€")/kWh")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "settings.energy.header", defaultValue: "Energy"))
            } footer: {
                Text(String(localized: "settings.energy.tariff.footer",
                            defaultValue: "Used to estimate costs from measured consumption. Leave 0 to show energy only, without costs."))
            }
#endif

            // MARK: - Archivio e sincronizzazione

            Section {
                NavigationLink {
                    DataSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "internaldrive",
                        title: String(localized: "settings.section.data", defaultValue: "Data"),
                        subtitle: String(localized: "settings.data.summary",
                                         defaultValue: "Maintenance, stored readings, and raw data retention."),
                        status: DataSettingsView.lastCycleText(dataLifecycleService.lastCycleDate)
                    )
                }

                NavigationLink {
                    ICloudSettingsView()
                } label: {
                    settingsLinkRow(
                        icon: "icloud",
                        title: String(localized: "settings.icloud.header", defaultValue: "iCloud"),
                        subtitle: String(localized: "settings.icloud.summary",
                                         defaultValue: "Sync status, device role, and diagnostics."),
                        status: syncStatus.shortLabel,
                        statusColor: syncStatus.color
                    )
                }
            } header: {
                Text(String(localized: "settings.section.storage", defaultValue: "Storage & Sync"))
            }

            // MARK: - Info

            Section {
                HStack {
                    Text(String(localized: "settings.info.version", defaultValue: "Version"))
                    Spacer()
                    Text(Bundle.main.appVersion)
                        .foregroundStyle(.secondary)
                }
            }

#if DEBUG
            // MARK: - Avanzate

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
                    HomeKitDebugView()
                } label: {
                    settingsLinkRow(
                        icon: "stethoscope",
                        title: String(localized: "settings.homekit.diagnostics", defaultValue: "Support Diagnostics"),
                        subtitle: String(localized: "settings.homekit.diagnostics.subtitle", defaultValue: "Export HomeKit accessory details for troubleshooting.")
                    )
                }
                NavigationLink {
                    AITraceView()
                } label: {
                    Label("AI Pipeline Trace", systemImage: "waveform.and.magnifyingglass")
                }
            } header: {
                Text(String(localized: "settings.developer.header", defaultValue: "Developer"))
            }
#endif
        }
        .tint(BrandColor.primary)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            refreshNotificationAuthorizationStatus()
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
                cloudKitSync.markSettingsNeedsSync()
                Task { await weatherKit.refresh() }
            }
        }
        .onChange(of: aiSettings.selectedProvider) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.isAIEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.anomalyDetectionEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.ruleEngineEnabled) { _, _ in syncAISettingsToCloud() }
        .onChange(of: aiSettings.hasAIDataConsent) { _, _ in syncAISettingsToCloud() }
    }

    private func syncAISettingsToCloud() {
        guard !cloudKitSync.isApplyingRemoteSettings else { return }
        guard let syncableSettings else { return }
        syncableSettings.aiProviderRaw             = aiSettings.selectedProvider.rawValue
        syncableSettings.aiIsEnabled               = aiSettings.isAIEnabled
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

    /// Conteggi dello store, letti una volta alla comparsa: un fetchCount nel
    /// body verrebbe rieseguito a ogni render.
    private func refreshNotificationAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                notificationAuthorizationStatus = settings.authorizationStatus
            }
        }
    }

    private var isCompact: Bool { horizontalSizeClass == .compact }

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
                    if let badge, !isCompact {
                        statusPill(badge, color: .orange)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                // Su iPhone i due pill scendono sotto. Accanto al titolo gli
                // sottraevano larghezza per tutta l'altezza della riga, ed è
                // così che "Illuminazione smart" si spezzava a metà parola.
                if isCompact, badge != nil || status != nil {
                    HStack(spacing: 6) {
                        if let badge {
                            statusPill(badge, color: .orange)
                        }
                        if let status {
                            statusPill(status, color: statusColor)
                        }
                    }
                    .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isCompact, let status {
                statusPill(status, color: statusColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        SettingsStatusPill(text: text, color: color)
    }

    /// Lo stato di iCloud per la riga di riepilogo. Lo stesso valore che la
    /// schermata di dettaglio mostra per esteso.
    private var syncStatus: SettingsSyncStatus { SettingsSyncStatus(service: cloudKitSync) }

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
