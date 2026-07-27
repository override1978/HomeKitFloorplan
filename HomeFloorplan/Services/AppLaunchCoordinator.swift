import SwiftData

struct AppLaunchCoordinator {
    let sharedModelContainer: ModelContainer
    let aiSettings: AISettings
    let onboarding: OnboardingService
    let actionExecutionService: ActionExecutionService
    let securityNotifier: SecurityNotificationService
    let cloudKitSync: CloudKitSyncService
    let weatherKitService: WeatherKitService
    let ambientalAIService: AmbientalAIService
    let securityMonitoredUUIDsRaw: String

    func run() async {
        await ImageMigrationService.runIfNeeded(context: sharedModelContainer.mainContext)
        await SettingsMigrationService.runIfNeeded(
            context: sharedModelContainer.mainContext,
            aiSettings: aiSettings,
            securityMonitoredUUIDsRaw: securityMonitoredUUIDsRaw
        )
        // Stato dello strato aggregati, nel log esportabile: dice se il ciclo
        // giornaliero è mai girato su QUESTO device, ambiente compreso.
        DataLifecycleService.logDataHealth(
            modelContainer: sharedModelContainer,
            isMaster: cloudKitSync.isMaster
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
}
