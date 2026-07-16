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
    @State private var matterEnergyLiveStore = MatterEnergyLiveStore()

    /// Identifier del task di campionamento sensori in background.
    private static let sensorSampleTaskID = "com.homefloorplan.sensorSample"
    /// Identifier del task di valutazione intelligence in background.
    private static let ruleEvaluationTaskID = "com.homefloorplan.ruleEvaluation"
    /// Identifier del task di lifecycle dati (aggregazione + pruning), giornaliero.
    private static let lifecycleTaskID = "com.homefloorplan.dataLifecycle"

    let sharedModelContainer: ModelContainer

    private static func makeModelContainer() -> ModelContainer {
        let schema = AppSchema.schema
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none  // CloudKit managed manually via CKSyncEngine
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            guard SchemaVersionValidator.probeContainerIntegrity(container: container) else {
                fatalError("SwiftData integrity probe failed. Local store was preserved.")
            }
            return container
        } catch {
            guard HomeFloorplanApp.isStoreCorruptionOrMigrationError(error) else {
                fatalError("Could not create ModelContainer (non-corruption error): \(error)")
            }
            fatalError("Could not create ModelContainer due to migration/corruption error. Local store was preserved: \(error)")
        }
    }

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
        let container = Self.makeModelContainer()
        self.sharedModelContainer = container

        let kit = HomeKitService()
        self._homeKit = State(initialValue: kit)
        // Le azioni AI/CTA scrivono via HomeKitService (cache + eventi + log),
        // non direttamente sulla caratteristica: vedi NextActionExecutor.write.
        NextActionExecutor.homeKit = kit
        let iconStore = IconOverrideStore()
        self._iconOverrides = State(initialValue: iconStore)
        let scenes = HomeKitScenesService(homeKit: kit)
        self._scenesService = State(initialValue: scenes)
        let weather = WeatherKitService()
        self._weatherKitService = State(initialValue: weather)
        let lightingEngine = SmartLightingEngine(homeKit: kit, weatherKit: weather, scenesService: scenes)
        kit.smartLightingEngine = lightingEngine
        self._smartLightingEngine = State(initialValue: lightingEngine)

        #if DEBUG
        DebugSupport.modelContainer = container
        #endif
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
        cloudSync.roomUUIDResolver = { remoteUUID, roomName in
            guard let home = kit.currentHome else { return nil }
            if home.rooms.contains(where: { $0.uniqueIdentifier == remoteUUID }) {
                return remoteUUID
            }

            let normalizedRoomName = Self.normalizedHomeKitToken(roomName)
            guard let normalizedRoomName else { return nil }

            return home.rooms.first {
                Self.normalizedHomeKitToken($0.name) == normalizedRoomName
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
        // Anti-duplicazione abitudini: il motore confronta le opportunità con le
        // automazioni HomeKit esistenti prima di proporle (fotografie fresche a ogni analisi).
        behavioralSvc.existingAutomationsProvider = { [weak kit] in
            ExistingAutomationSnapshot.snapshots(from: kit?.currentHome)
        }
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
            HomeFloorplanRootView(
                sharedModelContainer: sharedModelContainer,
                homeKit: homeKit,
                iconOverrides: iconOverrides,
                scenesService: scenesService,
                onboarding: onboarding,
                idleTimer: idleTimer,
                activityLogger: activityLogger,
                automationsService: automationsService,
                securityNotifier: securityNotifier,
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
                matterEnergyLiveStore: matterEnergyLiveStore
            )
        }
        .modelContainer(sharedModelContainer)
    }

    private static func normalizedHomeKitToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    // MARK: - Background Tasks

    /// Registra i BGTask: campionamento sensori, intelligence e lifecycle dati.
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

    /// Pianifica la prossima valutazione intelligence tra 15 minuti.
    private func scheduleNextRuleEvaluation() {
        let request = BGProcessingTaskRequest(identifier: Self.ruleEvaluationTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            dprint("⏰ Prossima valutazione intelligence pianificata tra ~15 min")
        } catch {
            dprint("❌ BGTask ruleEvaluation schedule error: \(error)")
        }
    }

    /// Valuta i cicli intelligence nel background task.
    private func handleRuleEvaluationTask(_ task: BGProcessingTask) {
        scheduleNextRuleEvaluation()

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
                weatherService:     weather,
                homeKitService:     homeKitSvc
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
