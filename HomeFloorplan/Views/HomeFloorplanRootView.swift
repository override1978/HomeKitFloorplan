import SwiftUI
import SwiftData
import HomeKit

struct HomeFloorplanRootView: View {
    let sharedModelContainer: ModelContainer
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore
    let scenesService: HomeKitScenesService
    let onboarding: OnboardingService
    let idleTimer: IdleTimerService
    let activityLogger: ActivityLoggerService
    let automationsService: HomeKitAutomationsService
    let securityNotifier: SecurityNotificationService
    let habitAnalysisService: HabitAnalysisService
    let actionExecutionService: ActionExecutionService
    let ambientalAIService: AmbientalAIService
    let behavioralAnalysisService: BehavioralAnalysisService
    let proactiveIntelligenceService: ProactiveIntelligenceService
    let occupancyPredictionService: OccupancyPredictionService
    let locationPresenceService: LocationPresenceService
    let familyPresenceService: FamilyPresenceService
    let maintenancePredictionService: MaintenancePredictionService
    let weatherKitService: WeatherKitService
    let smartLightingEngine: SmartLightingEngine
    let aiSettings: AISettings
    let cloudKitSync: CloudKitSyncService
    let matterEnergyLiveStore: MatterEnergyLiveStore

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("securityMonitoredUUIDs") private var securityMonitoredUUIDsRaw: String = ""
    @AppStorage(AppLanguage.appStorageKey) private var appLanguageRaw = AppLanguage.english.rawValue
    @AppStorage(MarkerSize.appStorageKey) private var markerSizeRaw = MarkerSize.regular.rawValue
    @AppStorage("idleTimeout") private var idleTimeoutSeconds: Double = 90
    @AppStorage(TemperatureUnit.appStorageKey) private var temperatureUnitRaw = TemperatureUnit.celsius.rawValue
    @AppStorage(DimensionUnit.appStorageKey) private var dimensionUnitRaw = DimensionUnit.metric.rawValue
    @AppStorage("alertNotificationsEnabled") private var alertNotificationsEnabled = false
    @AppStorage(SecurityNotificationService.enabledKey) private var securityNotificationsEnabled = false
    @AppStorage("proactiveIntelligenceNotificationsEnabled") private var proactiveNotificationsEnabled = false
    @AppStorage("homeLocation.cityName") private var homeLocationCityName = ""
    @AppStorage("com.homefloorplan.migrationWipedStore") private var migrationWipedStore = false

    var body: some View {
        ContentView()
            .modifier(AppEnvironmentModifier(
                homeKit: homeKit,
                iconOverrides: iconOverrides,
                scenesService: scenesService,
                onboarding: onboarding,
                idleTimer: idleTimer,
                activityLogger: activityLogger,
                automationsService: automationsService,
                habitAnalysisService: habitAnalysisService,
                actionExecutionService: actionExecutionService,
                ambientalAIService: ambientalAIService,
                behavioralAnalysisService: behavioralAnalysisService,
                proactiveIntelligenceService: proactiveIntelligenceService,
                occupancyPredictionService: occupancyPredictionService,
                locationPresenceService: locationPresenceService,
                familyPresenceService: familyPresenceService,
                maintenancePredictionService: maintenancePredictionService,
                weatherKitService: weatherKitService,
                smartLightingEngine: smartLightingEngine,
                aiSettings: aiSettings,
                cloudKitSync: cloudKitSync,
                matterEnergyLiveStore: matterEnergyLiveStore,
                locale: AppLanguage.resolved(from: appLanguageRaw).locale
            ))
            .task {
                await AppLaunchCoordinator(
                    sharedModelContainer: sharedModelContainer,
                    aiSettings: aiSettings,
                    onboarding: onboarding,
                    actionExecutionService: actionExecutionService,
                    securityNotifier: securityNotifier,
                    cloudKitSync: cloudKitSync,
                    weatherKitService: weatherKitService,
                    ambientalAIService: ambientalAIService,
                    securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw
                ).run()
            }
            .modifier(AppForegroundLifecycleModifier(
                scenePhase: scenePhase,
                coordinator: AppForegroundCoordinator(
                    sharedModelContainer: sharedModelContainer,
                    homeKit: homeKit,
                    cloudKitSync: cloudKitSync,
                    matterEnergyLiveStore: matterEnergyLiveStore,
                    weatherKitService: weatherKitService,
                    smartLightingEngine: smartLightingEngine,
                    proactiveIntelligenceService: proactiveIntelligenceService,
                    behavioralAnalysisService: behavioralAnalysisService,
                    habitAnalysisService: habitAnalysisService,
                    occupancyPredictionService: occupancyPredictionService,
                    maintenancePredictionService: maintenancePredictionService,
                    locationPresenceService: locationPresenceService
                )
            ))
            .modifier(CloudKitRemoteNotificationFetchModifier(cloudKitSync: cloudKitSync))
            .modifier(AppSettingsSyncModifier(
                coordinator: AppSettingsSyncCoordinator(
                    sharedModelContainer: sharedModelContainer,
                    cloudKitSync: cloudKitSync,
                    securityNotifier: securityNotifier
                ),
                securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw,
                markerSizeRaw: markerSizeRaw,
                idleTimeoutSeconds: idleTimeoutSeconds,
                temperatureUnitRaw: temperatureUnitRaw,
                appLanguageRaw: appLanguageRaw,
                dimensionUnitRaw: dimensionUnitRaw,
                alertNotificationsEnabled: alertNotificationsEnabled,
                securityNotificationsEnabled: securityNotificationsEnabled,
                proactiveNotificationsEnabled: proactiveNotificationsEnabled,
                homeLocationCityName: homeLocationCityName
            ))
            .onChange(of: homeKit.currentHome, initial: true) { _, newHome in
                AppHomeRuntimeCoordinator(
                    sharedModelContainer: sharedModelContainer,
                    familyPresenceService: familyPresenceService,
                    behavioralAnalysisService: behavioralAnalysisService,
                    occupancyPredictionService: occupancyPredictionService,
                    matterEnergyLiveStore: matterEnergyLiveStore,
                    ambientalAIService: ambientalAIService
                ).currentHomeDidChange(newHome)
            }
            .onChange(of: homeKit.isReady, initial: true) { _, isReady in
                guard isReady else { return }
                cloudKitSync.remapLinkedRoomsToLocalHomeKitIDs()
                cloudKitSync.remapPlacedAccessoriesToLocalHomeKitIDs()
            }
            .onChange(of: locationPresenceService.presenceState) { _, newState in
                ambientalAIService.presenceOverride = newState
                Task { await weatherKitService.refreshIfNeeded() }
            }
            .onChange(of: weatherKitService.currentWeather) { _, newWeather in
                AppHomeRuntimeCoordinator(
                    sharedModelContainer: sharedModelContainer,
                    familyPresenceService: familyPresenceService,
                    behavioralAnalysisService: behavioralAnalysisService,
                    occupancyPredictionService: occupancyPredictionService,
                    matterEnergyLiveStore: matterEnergyLiveStore,
                    ambientalAIService: ambientalAIService
                ).currentWeatherDidChange(newWeather)
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
    let automationsService: HomeKitAutomationsService
    let habitAnalysisService: HabitAnalysisService
    let actionExecutionService: ActionExecutionService
    let ambientalAIService: AmbientalAIService
    let behavioralAnalysisService: BehavioralAnalysisService
    let proactiveIntelligenceService: ProactiveIntelligenceService
    let occupancyPredictionService: OccupancyPredictionService
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
            .environment(automationsService)
            .environment(habitAnalysisService)
            .environment(actionExecutionService)
            .environment(ambientalAIService)
            .environment(behavioralAnalysisService)
            .environment(proactiveIntelligenceService)
            .environment(occupancyPredictionService)
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
