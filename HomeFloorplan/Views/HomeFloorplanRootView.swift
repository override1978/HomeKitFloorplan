import SwiftUI
import SwiftData
import HomeKit

/// La pillola discreta in basso durante la sync CloudKit massiva (primo
/// travaso su un device nuovo, re-import corposi): compare solo coi lotti
/// grossi e si spegne da sola. Il sync ordinario resta invisibile.
private struct CloudKitBulkSyncPill: View {
    let cloudKitSync: CloudKitSyncService

    var body: some View {
        ZStack {
            if cloudKitSync.isBulkSyncActive {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(format: String(localized: "sync.bulk.pill",
                                               defaultValue: "iCloud sync — %d items"),
                                cloudKitSync.bulkSyncAppliedCount))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                }
                .padding(.bottom, 10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: cloudKitSync.isBulkSyncActive)
        .allowsHitTesting(false)
    }
}

struct HomeFloorplanRootView: View {
    /// Grafo dei servizi dell'app: un solo riferimento al posto dei 23
    /// parametri che venivano prop-drillati qui e nei modifier.
    let services: AppServices

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("securityMonitoredUUIDs") private var securityMonitoredUUIDsRaw: String = ""
    @AppStorage(AppLanguage.appStorageKey) private var appLanguageRaw = AppLanguage.system.rawValue
    @AppStorage(MarkerSize.appStorageKey) private var markerSizeRaw = MarkerSize.regular.rawValue
    @AppStorage("idleTimeout") private var idleTimeoutSeconds: Double = 90
    @AppStorage(TemperatureUnit.appStorageKey) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue
    @AppStorage(DimensionUnit.appStorageKey) private var dimensionUnitRaw = DimensionUnit.metric.rawValue
    @AppStorage(AppAppearanceSettings.liquidGlassEnabledKey) private var isLiquidGlassEnabled = false
    @AppStorage("alertNotificationsEnabled") private var alertNotificationsEnabled = false
    @AppStorage(SecurityNotificationService.enabledKey) private var securityNotificationsEnabled = false
    @AppStorage("proactiveIntelligenceNotificationsEnabled") private var proactiveNotificationsEnabled = false
    @AppStorage("homeLocation.cityName") private var homeLocationCityName = ""
    @AppStorage("com.homefloorplan.migrationWipedStore") private var migrationWipedStore = false

    var body: some View {
        ContentView()
            .modifier(environmentModifier)
            .overlay(alignment: .bottom) {
                CloudKitBulkSyncPill(cloudKitSync: services.cloudKitSync)
            }
            .task {
                await launchCoordinator.run()
            }
            .modifier(AppForegroundLifecycleModifier(
                scenePhase: scenePhase,
                coordinator: foregroundCoordinator
            ))
            .modifier(CloudKitRemoteNotificationFetchModifier(cloudKitSync: services.cloudKitSync))
            .modifier(AppSettingsSyncModifier(
                coordinator: settingsSyncCoordinator,
                securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw,
                markerSizeRaw: markerSizeRaw,
                idleTimeoutSeconds: idleTimeoutSeconds,
                temperatureUnitRaw: temperatureUnitRaw,
                appLanguageRaw: appLanguageRaw,
                dimensionUnitRaw: dimensionUnitRaw,
                isLiquidGlassEnabled: isLiquidGlassEnabled,
                alertNotificationsEnabled: alertNotificationsEnabled,
                securityNotificationsEnabled: securityNotificationsEnabled,
                proactiveNotificationsEnabled: proactiveNotificationsEnabled,
                homeLocationCityName: homeLocationCityName
            ))
            .onChange(of: services.homeKit.currentHome, initial: true) { _, newHome in
                homeRuntimeCoordinator.currentHomeDidChange(newHome)
            }
            .onChange(of: services.homeKit.isReady, initial: true) { _, isReady in
                guard isReady else { return }
                measureMain("isReady.remapRooms") {
                    services.cloudKitSync.remapLinkedRoomsToLocalHomeKitIDs()
                }
                measureMain("isReady.remapAccessories") {
                    services.cloudKitSync.remapPlacedAccessoriesToLocalHomeKitIDs()
                }
            }
            .onChange(of: services.locationPresenceService.presenceState) { _, newState in
                services.ambientalAIService.presenceOverride = newState
                Task { await services.weatherKitService.refreshIfNeeded() }
            }
            .onChange(of: services.weatherKitService.currentWeather) { _, newWeather in
                homeRuntimeCoordinator.currentWeatherDidChange(newWeather)
            }
            .alert(
                String(localized: "alert.migration.title", defaultValue: "Dati ripristinati"),
                isPresented: $migrationWipedStore
            ) {
                Button(String(localized: "alert.migration.ok", defaultValue: "OK")) {
                    migrationWipedStore = false
                }
            } message: {
                Text(String(localized: "alert.migration.body",
                            defaultValue: "Un aggiornamento ha reso necessario il ripristino del database locale. I dati storici dell'app sono stati cancellati. Le automazioni HomeKit non sono state modificate."))
            }
    }

    private var environmentModifier: AppEnvironmentModifier {
        AppEnvironmentModifier(
            homeKit: services.homeKit,
            iconOverrides: services.iconOverrides,
            scenesService: services.scenesService,
            onboarding: services.onboarding,
            idleTimer: services.idleTimer,
            activityLogger: services.activityLogger,
            dataLifecycleService: services.dataLifecycleService,
            automationsService: services.automationsService,
            actionExecutionService: services.actionExecutionService,
            ambientalAIService: services.ambientalAIService,
            proactiveIntelligenceService: services.proactiveIntelligenceService,
            locationPresenceService: services.locationPresenceService,
            familyPresenceService: services.familyPresenceService,
            maintenancePredictionService: services.maintenancePredictionService,
            weatherKitService: services.weatherKitService,
            smartLightingEngine: services.smartLightingEngine,
            aiSettings: services.aiSettings,
            cloudKitSync: services.cloudKitSync,
            matterEnergyLiveStore: services.matterEnergyLiveStore,
            locale: AppLanguage.resolved(from: appLanguageRaw).locale
        )
    }

    private var launchCoordinator: AppLaunchCoordinator {
        AppLaunchCoordinator(
            sharedModelContainer: services.sharedModelContainer,
            aiSettings: services.aiSettings,
            onboarding: services.onboarding,
            actionExecutionService: services.actionExecutionService,
            securityNotifier: services.securityNotifier,
            cloudKitSync: services.cloudKitSync,
            homeKit: services.homeKit,
            weatherKitService: services.weatherKitService,
            ambientalAIService: services.ambientalAIService,
            securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw
        )
    }

    private var foregroundCoordinator: AppForegroundCoordinator {
        AppForegroundCoordinator(
            sharedModelContainer: services.sharedModelContainer,
            homeKit: services.homeKit,
            cloudKitSync: services.cloudKitSync,
            matterEnergyLiveStore: services.matterEnergyLiveStore,
            weatherKitService: services.weatherKitService,
            smartLightingEngine: services.smartLightingEngine,
            proactiveIntelligenceService: services.proactiveIntelligenceService,
            maintenancePredictionService: services.maintenancePredictionService,
            locationPresenceService: services.locationPresenceService,
            dataLifecycleService: services.dataLifecycleService
        )
    }

    private var settingsSyncCoordinator: AppSettingsSyncCoordinator {
        AppSettingsSyncCoordinator(
            sharedModelContainer: services.sharedModelContainer,
            cloudKitSync: services.cloudKitSync,
            securityNotifier: services.securityNotifier
        )
    }

    private var homeRuntimeCoordinator: AppHomeRuntimeCoordinator {
        AppHomeRuntimeCoordinator(
            sharedModelContainer: services.sharedModelContainer,
            familyPresenceService: services.familyPresenceService,
            matterEnergyLiveStore: services.matterEnergyLiveStore,
            ambientalAIService: services.ambientalAIService
        )
    }

}

private struct AppForegroundLifecycleModifier: ViewModifier {
    let scenePhase: ScenePhase
    let coordinator: AppForegroundCoordinator

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                await coordinator.runForegroundSamplingLoop(isActive: scenePhase == .active)
            }
            .task(id: scenePhase) {
                await coordinator.runCloudKitActivePollLoop(isActive: scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                coordinator.foregroundDidBecomeActive()
            }
    }
}

private struct AppSettingsSyncModifier: ViewModifier {
    let coordinator: AppSettingsSyncCoordinator
    let securityMonitoredUUIDsRaw: String
    let markerSizeRaw: String
    let idleTimeoutSeconds: Double
    let temperatureUnitRaw: String
    let appLanguageRaw: String
    let dimensionUnitRaw: String
    let isLiquidGlassEnabled: Bool
    let alertNotificationsEnabled: Bool
    let securityNotificationsEnabled: Bool
    let proactiveNotificationsEnabled: Bool
    let homeLocationCityName: String

    func body(content: Content) -> some View {
        content
            .onChange(of: securityMonitoredUUIDsRaw) { _, newValue in
                coordinator.updateSecurityMonitoredUUIDs(newValue)
            }
            .onChange(of: markerSizeRaw) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: idleTimeoutSeconds) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: temperatureUnitRaw) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: appLanguageRaw) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: dimensionUnitRaw) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: isLiquidGlassEnabled) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: alertNotificationsEnabled) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: securityNotificationsEnabled) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: proactiveNotificationsEnabled) { _, _ in coordinator.markSettingsNeedsSync() }
            .onChange(of: homeLocationCityName) { _, _ in coordinator.markSettingsNeedsSync() }
    }
}

private struct AppEnvironmentModifier: ViewModifier {
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore
    let scenesService: HomeKitScenesService
    let onboarding: OnboardingService
    let idleTimer: IdleTimerService
    let activityLogger: ActivityLoggerService
    let dataLifecycleService: DataLifecycleService
    let automationsService: HomeKitAutomationsService
    let actionExecutionService: ActionExecutionService
    let ambientalAIService: AmbientalAIService
    let proactiveIntelligenceService: ProactiveIntelligenceService
    let locationPresenceService: LocationPresenceService
    let familyPresenceService: FamilyPresenceService
    let maintenancePredictionService: MaintenancePredictionService
    let weatherKitService: WeatherKitService
    let smartLightingEngine: SmartLightingEngine
    let aiSettings: AISettings
    let cloudKitSync: CloudKitSyncService
    let matterEnergyLiveStore: MatterEnergyLiveStore
    let locale: Locale

    func body(content: Content) -> some View {
        content
            .environment(homeKit)
            .environment(iconOverrides)
            .environment(scenesService)
            .environment(onboarding)
            .environment(idleTimer)
            .environment(activityLogger)
            .environment(dataLifecycleService)
            .environment(automationsService)
            .environment(actionExecutionService)
            .environment(ambientalAIService)
            .environment(proactiveIntelligenceService)
            .environment(locationPresenceService)
            .environment(familyPresenceService)
            .environment(maintenancePredictionService)
            .environment(weatherKitService)
            .environment(smartLightingEngine)
            .environment(aiSettings)
            .environment(cloudKitSync)
            .environment(matterEnergyLiveStore)
            .environment(\.locale, locale)
    }
}

private struct CloudKitRemoteNotificationFetchModifier: ViewModifier {
    let cloudKitSync: CloudKitSyncService

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .cloudKitRemoteNotificationReceived)) { _ in
                Task {
                    await cloudKitSync.fetchZoneChangesDeterministicallyIfNeeded(
                        reason: "remote-notification",
                        minimumInterval: 0
                    )
                }
            }
    }
}
