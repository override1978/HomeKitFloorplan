import SwiftUI
import SwiftData
import BackgroundTasks
import HomeKit

@main
struct HomeFloorplanApp: App {

    @UIApplicationDelegateAdaptor(HomeFloorplanAppDelegate.self) private var appDelegate

    @State private var homeKit = HomeKitService()
    @State private var iconOverrides = IconOverrideStore()
    @State private var scenesService: HomeKitScenesService
    @State private var onboarding = OnboardingService()
    private var idleTimer: IdleTimerService { IdleTimerService.shared }
    @State private var activityLogger: ActivityLoggerService
    @State private var automationsService: HomeKitAutomationsService
    @State private var securityNotifier: SecurityNotificationService
    @State private var accessoryEventStore: AccessoryEventStore
    @State private var habitAnalysisService: HabitAnalysisService
    @State private var ruleEngineService: RuleEngineService
    @State private var actionExecutionService: ActionExecutionService
    @State private var ambientalAIService: AmbientalAIService
    @State private var dataLifecycleService: DataLifecycleService
    @State private var behavioralAnalysisService: BehavioralAnalysisService
    @State private var proactiveIntelligenceService: ProactiveIntelligenceService
    @State private var occupancyPredictionService: OccupancyPredictionService
    @State private var locationPresenceService: LocationPresenceService
    @State private var familyPresenceService: FamilyPresenceService
    @State private var maintenancePredictionService: MaintenancePredictionService
    @State private var weatherKitService: WeatherKitService
    @State private var smartLightingEngine: SmartLightingEngine
    @State private var aiSettings: AISettings
    @State private var cloudKitSync: CloudKitSyncService

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
    /// Set to true when a SwiftData migration failure forces a store wipe.
    /// The WindowGroup shows a one-time alert on the next launch.
    @AppStorage("com.homefloorplan.migrationWipedStore") private var migrationWipedStore = false

    /// Identifier del task di campionamento sensori in background.
    private static let sensorSampleTaskID = "com.homefloorplan.sensorSample"
    /// Identifier del task di valutazione regole in-app in background.
    private static let ruleEvaluationTaskID = "com.homefloorplan.ruleEvaluation"
    /// Identifier del task di lifecycle dati (aggregazione + pruning), giornaliero.
    private static let lifecycleTaskID = "com.homefloorplan.dataLifecycle"

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Floorplan.self,
            PlacedAccessory.self,
            ActivityEvent.self,
            SensorReading.self,
            SensorAlertEvent.self,
            SensorAlertThreshold.self,
            AccessoryEvent.self,
            Rule.self,
            ActionEffectivenessEvent.self,
            PersistedInsight.self,
            RoomAnalysisState.self,
            DailySensorSummary.self,
            AccessoryUsageSummary.self,
            EffectivenessSummary.self,
            PersistedHomeInsight.self,
            ProactiveNotification.self,
            AutomationOpportunity.self,
            PersistedBehavioralPattern.self,
            HabitPattern.self,
            SyncableSettings.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none  // CloudKit managed manually via CKSyncEngine
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            guard HomeFloorplanApp.isStoreCorruptionOrMigrationError(error) else {
                fatalError("Could not create ModelContainer (non-corruption error): \(error)")
            }
            fatalError("Could not create ModelContainer due to migration/corruption error. Local store was preserved: \(error)")
        }
    }()

    init() {
        // Consent safety guard: if AI was enabled before 26.B (upgrade edge case),
        // reset isEnabled so the user sees the consent screen before AI resumes.
        let ud = UserDefaults.standard
        if ud.bool(forKey: "ai.isEnabled") && !ud.bool(forKey: "ai.dataConsent.v1") {
            ud.set(false, forKey: "ai.isEnabled")
        }

        // Schema version check: logs version changes so crash reports can correlate
        // store wipes with model changes. Always runs before the container is created.
        SchemaVersionValidator.validateAndRecord()

        let kit = HomeKitService()
        self._homeKit = State(initialValue: kit)
        let iconStore = IconOverrideStore()
        self._iconOverrides = State(initialValue: iconStore)
        let scenes = HomeKitScenesService(homeKit: kit)
        self._scenesService = State(initialValue: scenes)
        let weather = WeatherKitService()
        self._weatherKitService = State(initialValue: weather)
        let lightingEngine = SmartLightingEngine(homeKit: kit, weatherKit: weather, scenesService: scenes)
        kit.smartLightingEngine = lightingEngine
        self._smartLightingEngine = State(initialValue: lightingEngine)

        // Costruisce il container prima di creare i servizi che ne hanno bisogno
        let schema = Schema([
            Floorplan.self,
            PlacedAccessory.self,
            ActivityEvent.self,
            SensorReading.self,
            SensorAlertEvent.self,
            SensorAlertThreshold.self,
            AccessoryEvent.self,
            Rule.self,
            ActionEffectivenessEvent.self,
            PersistedInsight.self,
            RoomAnalysisState.self,
            DailySensorSummary.self,
            AccessoryUsageSummary.self,
            EffectivenessSummary.self,
            PersistedHomeInsight.self,
            ProactiveNotification.self,
            AutomationOpportunity.self,
            PersistedBehavioralPattern.self,
            HabitPattern.self,
            SyncableSettings.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        var container: ModelContainer?
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            if HomeFloorplanApp.isStoreCorruptionOrMigrationError(error) {
                fatalError("Could not create ModelContainer due to migration/corruption error. Local store was preserved: \(error)")
            }
            // Non-corruption errors (e.g. CloudKit config): do not wipe, let guard below handle it
        }
        // Integrity probe: catches stores that open without throwing but are corrupt.
        if let c = container, !SchemaVersionValidator.probeContainerIntegrity(container: c) {
            fatalError("SwiftData integrity probe failed. Local store was preserved.")
        }
        guard let container else { fatalError("Could not create ModelContainer") }
        lightingEngine.modelContainer = container
        let logger = ActivityLoggerService(modelContainer: container)
        kit.activityLogger = logger
        scenes.activityLogger = logger
        self._activityLogger = State(initialValue: logger)
        self._automationsService = State(initialValue: HomeKitAutomationsService(homeKit: kit))
        let notifier = SecurityNotificationService(homeKit: kit)
        self._securityNotifier = State(initialValue: notifier)
        let eventStore = AccessoryEventStore(modelContainer: container)
        kit.accessoryEventStore = eventStore
        self._accessoryEventStore = State(initialValue: eventStore)
        let aiSettings = AISettings()
        self._aiSettings = State(initialValue: aiSettings)
        let cloudSync = CloudKitSyncService(modelContainer: container)
        cloudSync.accessorySnapshotProvider = { uuid in
            guard let accessory = kit.allAccessories.first(where: { $0.uniqueIdentifier == uuid }) else {
                return (nil, nil)
            }
            return (accessory.name, accessory.room?.name)
        }
        cloudSync.markerIconOverrideProvider = { uuid in
            iconStore.icon(for: uuid)
        }
        cloudSync.markerIconOverrideApplyCallback = { uuid, iconName in
            if let iconName {
                iconStore.setIcon(iconName, for: uuid)
            } else {
                iconStore.removeIcon(for: uuid)
            }
        }
        cloudSync.accessoryUUIDResolver = { remoteUUID, accessoryName, roomName in
            if kit.allAccessories.contains(where: { $0.uniqueIdentifier == remoteUUID }) {
                return remoteUUID
            }

            let normalizedName = Self.normalizedHomeKitToken(accessoryName)
            let normalizedRoom = Self.normalizedHomeKitToken(roomName)
            guard let normalizedName else { return nil }

            if let normalizedRoom,
               let roomMatch = kit.allAccessories.first(where: {
                   Self.normalizedHomeKitToken($0.name) == normalizedName &&
                   Self.normalizedHomeKitToken($0.room?.name) == normalizedRoom
               }) {
                return roomMatch.uniqueIdentifier
            }

            return kit.allAccessories.first {
                Self.normalizedHomeKitToken($0.name) == normalizedName
            }?.uniqueIdentifier
        }
        cloudSync.remoteSettingsApplyCallback = { settings in
            if let provider = AIProvider(rawValue: settings.aiProviderRaw),
               provider.isPubliclyAvailable {
                aiSettings.selectedProvider = provider
            } else {
                aiSettings.selectedProvider = .claude
            }
            aiSettings.isAIEnabled             = settings.aiIsEnabled
            aiSettings.suggestionsEnabled      = settings.aiSuggestionsEnabled
            aiSettings.anomalyDetectionEnabled = settings.aiAnomalyDetectionEnabled
            aiSettings.ruleEngineEnabled       = settings.aiRuleEngineEnabled
            aiSettings.hasAIDataConsent        = settings.aiHasDataConsent
            UserDefaults.standard.set(settings.securityMonitoredUUIDsRaw, forKey: "securityMonitoredUUIDs")
            notifier.updateMonitored(uuidsRaw: settings.securityMonitoredUUIDsRaw)

            let savedTimeout = UserDefaults.standard.double(forKey: "idleTimeout")
            if savedTimeout > 0 {
                IdleTimerService.shared.timeout = savedTimeout
            } else if savedTimeout == 0 && UserDefaults.standard.object(forKey: "idleTimeout") != nil {
                IdleTimerService.shared.timeout = .infinity
            }
        }
        self._cloudKitSync = State(initialValue: cloudSync)
        let habitSvc = HabitAnalysisService(aiSettings: aiSettings, modelContainer: container)
        self._habitAnalysisService = State(initialValue: habitSvc)
        self._ruleEngineService = State(initialValue: RuleEngineService(modelContainer: container))
        // Tracker condiviso tra AmbientalAIService (per dismiss/expiration) e ActionExecutionService
        // (per trackExecution). Una sola istanza garantisce coerenza del dataset di efficacia.
        let sharedTracker = ActionEffectivenessTracker(modelContainer: container)
        self._actionExecutionService = State(initialValue: ActionExecutionService(tracker: sharedTracker, modelContainer: container))
        let ambientalSvc = AmbientalAIService(
            aiSettings: aiSettings,
            modelContainer: container,
            homeKit: kit,
            tracker: sharedTracker
        )
        // Wire SensorEventRouter so high-priority sensor events bypass the 15-min analysis gate
        SensorEventRouter.shared.ambientalAI = ambientalSvc
        kit.sensorEventRouter = SensorEventRouter.shared
        self._ambientalAIService = State(initialValue: ambientalSvc)
        self._dataLifecycleService = State(initialValue: DataLifecycleService(modelContainer: container))
        let behavioralSvc = BehavioralAnalysisService(modelContainer: container)
        behavioralSvc.habitNamingService = habitSvc
        self._behavioralAnalysisService = State(initialValue: behavioralSvc)
        self._proactiveIntelligenceService = State(initialValue: ProactiveIntelligenceService(modelContainer: container))
        self._occupancyPredictionService = State(initialValue: OccupancyPredictionService())
        self._locationPresenceService = State(initialValue: LocationPresenceService())
        self._familyPresenceService = State(initialValue: FamilyPresenceService())
        self._maintenancePredictionService = State(initialValue: MaintenancePredictionService(modelContainer: container))

        // Apply persisted idle timeout so the screensaver respects the user's setting from launch.
        let savedTimeout = UserDefaults.standard.double(forKey: "idleTimeout")
        if savedTimeout > 0 {
            IdleTimerService.shared.timeout = savedTimeout
        } else if savedTimeout == 0 && UserDefaults.standard.object(forKey: "idleTimeout") != nil {
            // User explicitly set "Never"
            IdleTimerService.shared.timeout = .infinity
        }
        // If key doesn't exist yet, the default (90s) in IdleTimerService remains.

        // Registra il task di campionamento sensori in background
        registerBackgroundTasks()

        // Registra categorie UNUserNotificationCenter per la Proactive Intelligence
        NotificationDeliveryOrchestrator.registerCategories()
        SmartLightingIntentBridge.register(engine: lightingEngine)

    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(homeKit)
                .environment(iconOverrides)
                .environment(scenesService)
                .environment(onboarding)
                .environment(idleTimer)
                .environment(activityLogger)
                .environment(automationsService)
                .environment(habitAnalysisService)
                .environment(ruleEngineService)
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
                .environment(\.locale, AppLanguage.resolved(from: appLanguageRaw).locale)
                .task {
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
                    // When CloudKit delivers settings from another device, auto-complete onboarding.
                    cloudKitSync.onboardingAutoCompleteCallback = {
                        guard onboarding.shouldShowOnboarding else { return }
                        onboarding.markCompleted()
                    }
                    cloudKitSync.registerPendingLocalChanges()
                    // Existing installs: claim master role only after the first CloudKit fetch,
                    // so a second device can receive the current master before deciding.
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
                // Foreground loop: staggered sampling so returning to the floorplan does not
                // compete with HomeKit reads, SwiftData writes, and layout on the first frame.
                // Cancels automatically when the scene leaves .active.
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    let container = sharedModelContainer
                    var lastLightSampleAt: Date?
                    var lastSmartLightingEvaluationAt: Date?
                    var nextFullSensorSampleAt = Date().addingTimeInterval(45)
                    while !Task.isCancelled {
                        let now = Date()
                        if let home = homeKit.currentHome {
                            if lastLightSampleAt == nil ||
                                now.timeIntervalSince(lastLightSampleAt ?? .distantPast) >= 5 * 60 {
                                await SensorLogger.shared.sampleLightSensors(home: home, modelContainer: container)
                                lastLightSampleAt = Date()
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

                        do {
                            try await Task.sleep(for: .seconds(60))
                        } catch {
                            break // task cancelled — scene went inactive
                        }
                    }
                }
                .task(id: scenePhase) {
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
                .modifier(CloudKitRemoteNotificationFetchModifier(cloudKitSync: cloudKitSync))
                .onChange(of: securityMonitoredUUIDsRaw) { _, newValue in
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
                .onChange(of: markerSizeRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: idleTimeoutSeconds) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: temperatureUnitRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: appLanguageRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: dimensionUnitRaw) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: alertNotificationsEnabled) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: securityNotificationsEnabled) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: proactiveNotificationsEnabled) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: homeLocationCityName) { _, _ in cloudKitSync.markSettingsNeedsSync() }
                .onChange(of: homeKit.currentHome, initial: true) { _, newHome in
                    guard let home = newHome else { return }
                    familyPresenceService.autoActivateForCurrentUser(home: home)
                    let profileID = familyPresenceService.activeProfileID
                    behavioralAnalysisService.switchProfile(to: profileID)
                    occupancyPredictionService.switchProfile(to: profileID)
                }
                .onChange(of: homeKit.isReady, initial: true) { _, isReady in
                    guard isReady else { return }
                    cloudKitSync.remapPlacedAccessoriesToLocalHomeKitIDs()
                }
                .onChange(of: locationPresenceService.presenceState) { _, newState in
                    ambientalAIService.presenceOverride = newState
                    // Piggyback a weather refresh on presence changes (arrival/departure)
                    Task { await weatherKitService.refreshIfNeeded() }
                }
                .onChange(of: weatherKitService.currentWeather) { _, newWeather in
                    ambientalAIService.currentWeather = newWeather
                    if let snapshot = newWeather {
                        let container = sharedModelContainer
                        Task { await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container) }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task {
                        await cloudKitSync.fetchRemoteChangesIfNeeded(reason: "foreground")
                    }
                    // Only the master device runs behavioral analysis.
                    // Slave devices receive opportunities via CloudKit sync.
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
        .modelContainer(sharedModelContainer)
    }

    private static func normalizedHomeKitToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    // MARK: - Background Tasks

    /// Registra i BGTask: campionamento sensori, valutazione regole e lifecycle dati.
    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.sensorSampleTaskID,
            using: nil
        ) { [self] task in
            handleSensorSampleTask(task as! BGProcessingTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.ruleEvaluationTaskID,
            using: nil
        ) { [self] task in
            handleRuleEvaluationTask(task as! BGProcessingTask)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.lifecycleTaskID,
            using: nil
        ) { [self] task in
            handleLifecycleCycleTask(task as! BGProcessingTask)
        }
        scheduleNextSampling()
        scheduleNextRuleEvaluation()
        scheduleNextLifecycleCycle()
    }

    /// Pianifica il prossimo campionamento tra 20 minuti.
    private func scheduleNextSampling() {
        let request = BGProcessingTaskRequest(identifier: Self.sensorSampleTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            dprint("⏰ Prossimo campionamento sensori pianificato tra ~20 min")
        } catch {
            dprint("❌ BGTask schedule error: \(error)")
        }
    }

    /// Esegue il campionamento nel background task.
    private func handleSensorSampleTask(_ task: BGProcessingTask) {
        scheduleNextSampling()

        let container = sharedModelContainer
        let homeKitService = homeKit
        let weather = weatherKitService

        task.expirationHandler = {
            dprint("⚠️ BGTask scaduto prima del completamento")
        }

        Task { @MainActor in
            if let home = homeKitService.currentHome {
                await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: container)
                await SensorLogger.shared.pruneOldReadings(olderThan: 30, modelContainer: container)
            }
            if let snapshot = weather.currentWeather {
                await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
            }
            task.setTaskCompleted(success: true)
        }
    }

    /// Pianifica la prossima valutazione regole tra 15 minuti.
    private func scheduleNextRuleEvaluation() {
        let request = BGProcessingTaskRequest(identifier: Self.ruleEvaluationTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            dprint("⏰ Prossima valutazione regole pianificata tra ~15 min")
        } catch {
            dprint("❌ BGTask ruleEvaluation schedule error: \(error)")
        }
    }

    /// Valuta le regole in-app nel background task.
    private func handleRuleEvaluationTask(_ task: BGProcessingTask) {
        scheduleNextRuleEvaluation()

        let engine      = ruleEngineService
        let homeKitSvc  = homeKit
        let proactive   = proactiveIntelligenceService
        let behavioral  = behavioralAnalysisService
        let habitSvc    = habitAnalysisService
        let occupancy   = occupancyPredictionService
        let location    = locationPresenceService
        let maintenance = maintenancePredictionService
        let weather     = weatherKitService
        let lighting    = smartLightingEngine
        let cloudSync   = cloudKitSync

        task.expirationHandler = {
            dprint("⚠️ BGTask ruleEvaluation scaduto prima del completamento")
        }

        Task { @MainActor in
            if let home = homeKitSvc.currentHome {
                await engine.evaluateInAppRules(home: home)
            }
            guard cloudSync.isMaster else {
                task.setTaskCompleted(success: true)
                return
            }
            await lighting.evaluate()
            occupancy.updateNextArrival()
            await proactive.runCycleIfNeeded(
                behavioralService:  behavioral,
                habitService:       habitSvc,
                occupancyService:   occupancy,
                maintenanceService: maintenance,
                presenceOverride:   location.presenceState,
                weatherService:     weather
            )
            task.setTaskCompleted(success: true)
        }
    }

    /// Pianifica il prossimo ciclo di lifecycle dati tra 24 ore.
    private func scheduleNextLifecycleCycle() {
        let request = BGProcessingTaskRequest(identifier: Self.lifecycleTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 24 * 3600)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            dprint("⏰ Prossimo ciclo DataLifecycle pianificato tra ~24h")
        } catch {
            dprint("❌ BGTask lifecycle schedule error: \(error)")
        }
    }

    /// Returns true only for CoreData/SwiftData error codes that indicate genuine store
    /// corruption or migration incompatibility — the only cases where wiping is safe.
    /// Code 134060 (NSPersistentStoreOperationError), which covers CloudKit config failures,
    /// is intentionally excluded.
    private static func isStoreCorruptionOrMigrationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let corruptionCodes: Set<Int> = [
            134100, // NSPersistentStoreIncompatibleVersionHashError — model changed without migration
            134110, // NSMigrationError
            134111, // NSMigrationConstraintViolationError
            134130, // NSMigrationMissingSourceModelError
            134140, // NSMigrationMissingMappingModelError
            134150, // NSMigrationManagerSourceStoreError
            134160, // NSMigrationManagerDestinationStoreError
        ]
        if corruptionCodes.contains(nsError.code) { return true }
        return nsError.underlyingErrors.contains { corruptionCodes.contains(($0 as NSError).code) }
    }

    /// Esegue aggregazione e pruning dei dati nel background task giornaliero.
    private func handleLifecycleCycleTask(_ task: BGProcessingTask) {
        scheduleNextLifecycleCycle()

        let lifecycle   = dataLifecycleService
        let habits      = habitAnalysisService
        let container   = sharedModelContainer
        let occupancy   = occupancyPredictionService
        let maintenance = maintenancePredictionService
        let cloudSync   = cloudKitSync

        task.expirationHandler = {
            dprint("⚠️ BGTask lifecycle scaduto prima del completamento")
        }

        let behavioral = behavioralAnalysisService
        Task { @MainActor in
            guard cloudSync.isMaster else {
                task.setTaskCompleted(success: true)
                return
            }
            await lifecycle.runFullCycle()
            habits.cleanupStalePatterns()
            await behavioral.analyze()
            behavioral.cleanupStale()
            await occupancy.analyzeHistory(modelContainer: container)
            await EnvironmentalPatternAnalyzer.analyze(modelContainer: container)
            await maintenance.analyze()
            #if DEBUG
            let snap = StorageHealthMonitor.takeSnapshot(container: container)
            dprint(snap.summary)
            #endif
            task.setTaskCompleted(success: true)
        }
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
