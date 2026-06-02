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

    @AppStorage("securityMonitoredUUIDs") private var securityMonitoredUUIDsRaw: String = ""

    /// Identifier del task di campionamento sensori in background.
    private static let sensorSampleTaskID = "com.homefloorplan.sensorSample"
    /// Identifier del task di valutazione regole in-app in background.
    private static let ruleEvaluationTaskID = "com.homefloorplan.ruleEvaluation"

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
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        let kit = HomeKitService()
        self._homeKit = State(initialValue: kit)
        let scenes = HomeKitScenesService(homeKit: kit)
        self._scenesService = State(initialValue: scenes)

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
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let container = (try? ModelContainer(for: schema, configurations: [config]))
            ?? (try! ModelContainer(for: schema))
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
        self._habitAnalysisService = State(initialValue: HabitAnalysisService(aiSettings: aiSettings, modelContainer: container))
        self._ruleEngineService = State(initialValue: RuleEngineService(modelContainer: container))

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
                .task {
                    securityNotifier.start(monitoredUUIDsRaw: securityMonitoredUUIDsRaw)
                }
                .onChange(of: securityMonitoredUUIDsRaw) { _, newValue in
                    securityNotifier.updateMonitored(uuidsRaw: newValue)
                }
        }
        .modelContainer(sharedModelContainer)
    }

    // MARK: - Background Tasks

    /// Registra i BGTask: campionamento sensori e valutazione regole in-app.
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
            handleRuleEvaluationTask(task as! BGAppRefreshTask)
        }
        scheduleNextSampling()
        scheduleNextRuleEvaluation()
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

        task.expirationHandler = {
            dprint("⚠️ BGTask scaduto prima del completamento")
        }

        Task { @MainActor in
            if let home = homeKitService.currentHome {
                await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: container)
                await SensorLogger.shared.pruneOldReadings(olderThan: 30, modelContainer: container)
            }
            task.setTaskCompleted(success: true)
        }
    }

    /// Pianifica la prossima valutazione regole tra 15 minuti.
    private func scheduleNextRuleEvaluation() {
        let request = BGAppRefreshTaskRequest(identifier: Self.ruleEvaluationTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            dprint("⏰ Prossima valutazione regole pianificata tra ~15 min")
        } catch {
            dprint("❌ BGTask ruleEvaluation schedule error: \(error)")
        }
    }

    /// Valuta le regole in-app nel background task.
    private func handleRuleEvaluationTask(_ task: BGAppRefreshTask) {
        scheduleNextRuleEvaluation()

        let engine = ruleEngineService
        let homeKitService = homeKit

        task.expirationHandler = {
            dprint("⚠️ BGTask ruleEvaluation scaduto prima del completamento")
        }

        Task { @MainActor in
            if let home = homeKitService.currentHome {
                await engine.evaluateInAppRules(home: home)
            }
            task.setTaskCompleted(success: true)
        }
    }
}
