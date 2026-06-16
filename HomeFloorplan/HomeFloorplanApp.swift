import SwiftUI
import SwiftData
import BackgroundTasks

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

    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("securityMonitoredUUIDs") private var securityMonitoredUUIDsRaw: String = ""
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
            ProactiveNotification.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        if let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
            return container
        }
        // Migration failed — wipe the store and start fresh
        HomeFloorplanApp.wipeDefaultStore()
        if let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
            return container
        }
        fatalError("Could not create ModelContainer even after store wipe")
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
        let scenes = HomeKitScenesService(homeKit: kit)
        self._scenesService = State(initialValue: scenes)
        let weather = WeatherKitService()
        self._weatherKitService = State(initialValue: weather)
        let lightingEngine = SmartLightingEngine(homeKit: kit, weatherKit: weather, scenesService: scenes)
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
            ProactiveNotification.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        var container = try? ModelContainer(for: schema, configurations: [config])
        if container == nil {
            HomeFloorplanApp.wipeDefaultStore()
            container = try? ModelContainer(for: schema, configurations: [config])
        }
        // Integrity probe: catches stores that open without throwing but are corrupt.
        if let c = container, !SchemaVersionValidator.probeContainerIntegrity(container: c) {
            HomeFloorplanApp.wipeDefaultStore()
            container = try? ModelContainer(for: schema, configurations: [config])
        }
        guard let container else { fatalError("Could not create ModelContainer after store wipe") }
        let logger = ActivityLoggerService(modelContainer: container)
        kit.activityLogger = logger
        scenes.activityLogger = logger
        self._activityLogger = State(initialValue: logger)
        self._automationsService = State(initialValue: HomeKitAutomationsService(homeKit: kit))
        self._securityNotifier = State(initialValue: SecurityNotificationService(homeKit: kit))
        let eventStore = AccessoryEventStore(modelContainer: container)
        kit.accessoryEventStore = eventStore
        self._accessoryEventStore = State(initialValue: eventStore)
        let aiSettings = AISettings()
        self._aiSettings = State(initialValue: aiSettings)
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

        dprint("🏠 RoomPlan supported: \(RoomPlanSupport.isSupported)")

        // Registra il task di campionamento sensori in background
        registerBackgroundTasks()

        // Registra categorie UNUserNotificationCenter per la Proactive Intelligence
        NotificationDeliveryOrchestrator.registerCategories()

        // Richiede permesso notifiche per gli alert ambientali
        AlertNotificationService.shared.requestAuthorization()
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
                .task {
                    securityNotifier.start(monitoredUUIDsRaw: securityMonitoredUUIDsRaw)
                    SensorLogger.shared.effectivenessTracker = actionExecutionService.tracker
                    await weatherKitService.refreshIfNeeded()
                    ambientalAIService.currentWeather = weatherKitService.currentWeather
                    if let snapshot = weatherKitService.currentWeather {
                        await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: sharedModelContainer)
                    }
                }
                // Foreground loop: lux dense sampling (~5 min) + outdoor snapshot (rate-limited to 1/hr).
                // Cancels automatically when the scene leaves .active.
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    let container = sharedModelContainer
                    while !Task.isCancelled {
                        if let home = homeKit.currentHome {
                            await SensorLogger.shared.sampleLightSensors(home: home, modelContainer: container)
                        }
                        await weatherKitService.refreshIfNeeded()
                        if let snapshot = weatherKitService.currentWeather {
                            await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
                        }
                        await smartLightingEngine.evaluate()
                        do {
                            try await Task.sleep(for: .seconds(300)) // 5 min
                        } catch {
                            break // task cancelled — scene went inactive
                        }
                    }
                }
                .onChange(of: securityMonitoredUUIDsRaw) { _, newValue in
                    securityNotifier.updateMonitored(uuidsRaw: newValue)
                }
                .onChange(of: homeKit.currentHome, initial: true) { _, newHome in
                    guard let home = newHome else { return }
                    familyPresenceService.autoActivateForCurrentUser(home: home)
                    let profileID = familyPresenceService.activeProfileID
                    behavioralAnalysisService.switchProfile(to: profileID)
                    occupancyPredictionService.switchProfile(to: profileID)
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

        task.expirationHandler = {
            dprint("⚠️ BGTask ruleEvaluation scaduto prima del completamento")
        }

        Task { @MainActor in
            if let home = homeKitSvc.currentHome {
                await engine.evaluateInAppRules(home: home)
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

    /// Deletes the default SwiftData store files so the container can be recreated from scratch.
    /// Called only when a migration failure makes the store unloadable.
    /// Sets a UserDefaults flag so the app can notify the user on next launch.
    private static func wipeDefaultStore() {
        guard let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let base = support.appendingPathComponent("default.store").path
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
        UserDefaults.standard.set(true, forKey: "com.homefloorplan.migrationWipedStore")
        dprint("⚠️ [Container] Store wiped due to migration failure — starting fresh")
    }

    /// Esegue aggregazione e pruning dei dati nel background task giornaliero.
    private func handleLifecycleCycleTask(_ task: BGProcessingTask) {
        scheduleNextLifecycleCycle()

        let lifecycle   = dataLifecycleService
        let habits      = habitAnalysisService
        let container   = sharedModelContainer
        let occupancy   = occupancyPredictionService
        let maintenance = maintenancePredictionService

        task.expirationHandler = {
            dprint("⚠️ BGTask lifecycle scaduto prima del completamento")
        }

        let behavioral = behavioralAnalysisService
        Task { @MainActor in
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
