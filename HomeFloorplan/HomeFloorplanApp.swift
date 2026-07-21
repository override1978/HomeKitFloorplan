import SwiftUI
import SwiftData
import BackgroundTasks
import HomeKit

@main
struct HomeFloorplanApp: App {

    @UIApplicationDelegateAdaptor(HomeFloorplanAppDelegate.self) private var appDelegate

    /// Grafo dei servizi (composition root). Nessun default value: verrebbe
    /// valutato comunque prima del corpo dell'init (doppia costruzione).
    @State private var services: AppServices

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

        self._services = State(initialValue: AppServices(container: container))

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
    }

    var body: some Scene {
        WindowGroup {
            if TestEnvironment.isRunningUnitTests {
                // Host inerte durante gli unit test: la root view avvia task e
                // servizi che scrivono sul ModelContainer condiviso con i test
                // E2E, rendendoli non deterministici al primo lancio.
                Color.clear
            } else {
                rootView
            }
        }
        .modelContainer(sharedModelContainer)
    }

    private var rootView: some View {
        HomeFloorplanRootView(services: services)
    }

    // MARK: - Background Tasks

    /// Registra i BGTask: campionamento sensori, intelligence e lifecycle dati.
    private func registerBackgroundTasks() {
        // Nel test host i BGTask non servono e la pianificazione è solo rumore.
        guard !TestEnvironment.isRunningUnitTests else { return }
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
        let homeKitService = services.homeKit
        let weather = services.weatherKitService

        let work = Task { @MainActor in
            if let home = homeKitService.currentHome {
                await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: container)
                await SensorLogger.shared.pruneOldReadings(olderThan: 30, modelContainer: container)
            }
            if let snapshot = weather.currentWeather {
                await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
            }
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
        }

        // Alla scadenza va SEMPRE chiamato setTaskCompleted, altrimenti iOS
        // penalizza gli slot futuri dell'app per questo task.
        task.expirationHandler = {
            dprint("⚠️ BGTask scaduto prima del completamento")
            work.cancel()
            task.setTaskCompleted(success: false)
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

        let homeKitSvc  = services.homeKit
        let proactive   = services.proactiveIntelligenceService
        let behavioral  = services.behavioralAnalysisService
        let habitSvc    = services.habitAnalysisService
        let occupancy   = services.occupancyPredictionService
        let location    = services.locationPresenceService
        let maintenance = services.maintenancePredictionService
        let weather     = services.weatherKitService
        let lighting    = services.smartLightingEngine
        let cloudSync   = services.cloudKitSync

        let work = Task { @MainActor in
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
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            dprint("⚠️ BGTask ruleEvaluation scaduto prima del completamento")
            work.cancel()
            task.setTaskCompleted(success: false)
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

        let lifecycle   = services.dataLifecycleService
        let habits      = services.habitAnalysisService
        let container   = sharedModelContainer
        let occupancy   = services.occupancyPredictionService
        let maintenance = services.maintenancePredictionService
        let cloudSync   = services.cloudKitSync

        let work = Task { @MainActor in
            guard cloudSync.isMaster else {
                task.setTaskCompleted(success: true)
                return
            }
            await lifecycle.runFullCycle()
            habits.cleanupStalePatterns()
            // Motore statistico ritirato: niente analyze()/cleanupStale nel
            // ciclo giornaliero (pivot Abitudini).
            await occupancy.analyzeHistory(modelContainer: container)
            await EnvironmentalPatternAnalyzer.analyze(modelContainer: container)
            await maintenance.analyze()
            #if DEBUG
            let snap = StorageHealthMonitor.takeSnapshot(container: container)
            dprint(snap.summary)
            #endif
            guard !Task.isCancelled else { return }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            dprint("⚠️ BGTask lifecycle scaduto prima del completamento")
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
