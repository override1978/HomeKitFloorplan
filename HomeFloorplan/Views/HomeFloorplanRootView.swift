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
                await runLaunchTasks()
            }
            .modifier(AppForegroundLifecycleModifier(
                scenePhase: scenePhase,
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
            ))
            .modifier(CloudKitRemoteNotificationFetchModifier(cloudKitSync: cloudKitSync))
            .modifier(AppSettingsSyncModifier(
                sharedModelContainer: sharedModelContainer,
                cloudKitSync: cloudKitSync,
                securityNotifier: securityNotifier,
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
                currentHomeDidChange(newHome)
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
                currentWeatherDidChange(newWeather)
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

    private func runLaunchTasks() async {
        await ImageMigrationService.runIfNeeded(context: sharedModelContainer.mainContext)
        await OpportunityMigrationService.runIfNeeded(context: sharedModelContainer.mainContext)
        await PatternMigrationService.runIfNeeded(context: sharedModelContainer.mainContext)
        await HabitPatternMigrationService.runIfNeeded(context: sharedModelContainer.mainContext)
        await SettingsMigrationService.runIfNeeded(
            context: sharedModelContainer.mainContext,
            aiSettings: aiSettings,
            securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw
        )
        if cloudKitSync.isMaster {
            cloudKitSync.updateSettingsFromRuntime(
                aiSettings: aiSettings,
                securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw
            )
        } else {
            cloudKitSync.applyStoredSettingsToRuntime()
        }
        cloudKitSync.onboardingAutoCompleteCallback = {
            guard onboarding.shouldShowOnboarding else { return }
            onboarding.markCompleted()
        }
        cloudKitSync.registerPendingLocalChanges()
        if !onboarding.shouldShowOnboarding {
            Task {
                await cloudKitSync.claimMasterAfterInitialSyncIfNeeded()
            }
        }
        securityNotifier.start(monitoredUUIDsRaw: securityMonitoredUUIDsRaw)
        SensorLogger.shared.effectivenessTracker = actionExecutionService.tracker
        await weatherKitService.refreshIfNeeded()
        ambientalAIService.currentWeather = weatherKitService.currentWeather
        if let snapshot = weatherKitService.currentWeather {
            await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: sharedModelContainer)
        }
    }

    private func currentHomeDidChange(_ home: HMHome?) {
        guard let home else { return }
        familyPresenceService.autoActivateForCurrentUser(home: home)
        let profileID = familyPresenceService.activeProfileID
        behavioralAnalysisService.switchProfile(to: profileID)
        occupancyPredictionService.switchProfile(to: profileID)
        Task {
            await matterEnergyLiveStore.refreshIfNeeded(home: home)
        }
    }

    private func currentWeatherDidChange(_ newWeather: WeatherSnapshot?) {
        ambientalAIService.currentWeather = newWeather
        if let snapshot = newWeather {
            let container = sharedModelContainer
            Task {
                await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
            }
        }
    }

}

private struct AppForegroundLifecycleModifier: ViewModifier {
    let scenePhase: ScenePhase
    let sharedModelContainer: ModelContainer
    let homeKit: HomeKitService
    let cloudKitSync: CloudKitSyncService
    let matterEnergyLiveStore: MatterEnergyLiveStore
    let weatherKitService: WeatherKitService
    let smartLightingEngine: SmartLightingEngine
    let proactiveIntelligenceService: ProactiveIntelligenceService
    let behavioralAnalysisService: BehavioralAnalysisService
    let habitAnalysisService: HabitAnalysisService
    let occupancyPredictionService: OccupancyPredictionService
    let maintenancePredictionService: MaintenancePredictionService
    let locationPresenceService: LocationPresenceService

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                await runForegroundSamplingLoop()
            }
            .task(id: scenePhase) {
                await runCloudKitActivePollLoop()
            }
            .onChange(of: scenePhase) { _, newPhase in
                scenePhaseDidChange(newPhase)
            }
    }

    private func runForegroundSamplingLoop() async {
        guard scenePhase == .active else { return }
        let container = sharedModelContainer
        var lastLightSampleAt: Date?
        var lastMatterEnergyRefreshAt: Date?
        var lastSmartLightingEvaluationAt: Date?
        var nextFullSensorSampleAt = Date().addingTimeInterval(45)
        var nextProactiveCycleAllowedAt = Date().addingTimeInterval(90)

        while !Task.isCancelled {
            let now = Date()
            if let home = homeKit.currentHome {
                if lastLightSampleAt == nil ||
                    now.timeIntervalSince(lastLightSampleAt ?? .distantPast) >= 5 * 60 {
                    await SensorLogger.shared.sampleLightSensors(home: home, modelContainer: container)
                    lastLightSampleAt = Date()
                }

                if lastMatterEnergyRefreshAt == nil ||
                    now.timeIntervalSince(lastMatterEnergyRefreshAt ?? .distantPast) >= 5 * 60 {
                    await matterEnergyLiveStore.refreshIfNeeded(home: home, minimumInterval: 5 * 60)
                    lastMatterEnergyRefreshAt = Date()
                }

                if now >= nextFullSensorSampleAt {
                    await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: container)
                    nextFullSensorSampleAt = Date().addingTimeInterval(15 * 60)
                }
            }
            await weatherKitService.refreshIfNeeded()
            if let snapshot = weatherKitService.currentWeather {
                await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
            }

            if cloudKitSync.isMaster,
               lastSmartLightingEvaluationAt == nil ||
                now.timeIntervalSince(lastSmartLightingEvaluationAt ?? .distantPast) >= 5 * 60 {
                await smartLightingEngine.evaluate()
                lastSmartLightingEvaluationAt = Date()
            }

            if now >= nextProactiveCycleAllowedAt {
                await proactiveIntelligenceService.runCycleIfNeeded(
                    behavioralService:  behavioralAnalysisService,
                    habitService:       habitAnalysisService,
                    occupancyService:   occupancyPredictionService,
                    maintenanceService: maintenancePredictionService,
                    presenceOverride:   locationPresenceService.presenceState,
                    weatherService:     weatherKitService,
                    homeKitService:     homeKit
                )
                nextProactiveCycleAllowedAt = .distantPast
            }

            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                break
            }
        }
    }

    private func runCloudKitActivePollLoop() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            await cloudKitSync.fetchRemoteChangesIfNeeded(
                reason: "active-poll",
                minimumInterval: 20
            )
            await cloudKitSync.fetchZoneChangesDeterministicallyIfNeeded(
                reason: "active-poll",
                minimumInterval: 20
            )
            do {
                try await Task.sleep(for: .seconds(20))
            } catch {
                break
            }
        }
    }

    private func scenePhaseDidChange(_ newPhase: ScenePhase) {
        guard newPhase == .active else { return }
        Task {
            await cloudKitSync.fetchRemoteChangesIfNeeded(reason: "foreground")
        }
        if let home = homeKit.currentHome {
            Task {
                await matterEnergyLiveStore.refreshIfNeeded(home: home)
            }
        }
        guard cloudKitSync.isMaster else { return }
        let key = "behavioral.foregroundAnalysis.lastTriggered"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 12 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        let behavioral = behavioralAnalysisService
        Task {
            await behavioral.analyze()
        }
    }
}

private struct AppSettingsSyncModifier: ViewModifier {
    let sharedModelContainer: ModelContainer
    let cloudKitSync: CloudKitSyncService
    let securityNotifier: SecurityNotificationService
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
                updateSecurityMonitoredUUIDs(newValue)
            }
            .onChange(of: markerSizeRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: idleTimeoutSeconds) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: temperatureUnitRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: appLanguageRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: dimensionUnitRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: alertNotificationsEnabled) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: securityNotificationsEnabled) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: proactiveNotificationsEnabled) { _, _ in cloudKitSync.markSettingsNeedsSync() }
            .onChange(of: homeLocationCityName) { _, _ in cloudKitSync.markSettingsNeedsSync() }
    }

    private func updateSecurityMonitoredUUIDs(_ newValue: String) {
        securityNotifier.updateMonitored(uuidsRaw: newValue)
        guard !cloudKitSync.isApplyingRemoteSettings else { return }
        let context = ModelContext(sharedModelContainer)
        guard let settings = (try? context.fetch(FetchDescriptor<SyncableSettings>()))?.first else {
            return
        }
        settings.securityMonitoredUUIDsRaw = newValue
        settings.modifiedAt = .now
        try? context.save()
        cloudKitSync.syncAfterSave()
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
