import SwiftUI
import SwiftData
import HomeKit

/// Composition root dell'app: costruisce e collega l'intero grafo dei servizi.
///
/// Estratto dall'`init` di `HomeFloorplanApp` (che era ~165 righe di wiring
/// inline): un punto unico dove i servizi nascono e si agganciano tra loro.
/// L'App tiene un solo riferimento a questo oggetto e la root view lo riceve
/// intero invece di 23 parametri separati.
@MainActor
@Observable
final class AppServices {

    let sharedModelContainer: ModelContainer
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore
    let scenesService: HomeKitScenesService
    let onboarding = OnboardingService()
    let activityLogger: ActivityLoggerService
    let automationsService: HomeKitAutomationsService
    let securityNotifier: SecurityNotificationService
    let accessoryEventStore: AccessoryEventStore
    let habitAnalysisService: HabitAnalysisService
    let actionExecutionService: ActionExecutionService
    let ambientalAIService: AmbientalAIService
    let dataLifecycleService: DataLifecycleService
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
    let matterEnergyLiveStore = MatterEnergyLiveStore()

    var idleTimer: IdleTimerService { IdleTimerService.shared }

    init(container: ModelContainer) {
        self.sharedModelContainer = container

        let kit = HomeKitService()
        self.homeKit = kit
        // Le azioni AI/CTA scrivono via HomeKitService (cache + eventi + log),
        // non direttamente sulla caratteristica: vedi NextActionExecutor.write.
        NextActionExecutor.homeKit = kit
        let iconStore = IconOverrideStore()
        self.iconOverrides = iconStore
        let scenes = HomeKitScenesService(homeKit: kit)
        self.scenesService = scenes
        let weather = WeatherKitService()
        self.weatherKitService = weather
        let lightingEngine = SmartLightingEngine(homeKit: kit, weatherKit: weather, scenesService: scenes)
        kit.smartLightingEngine = lightingEngine
        self.smartLightingEngine = lightingEngine

        #if DEBUG
        DebugSupport.modelContainer = container
        #endif
        lightingEngine.modelContainer = container
        let logger = ActivityLoggerService(modelContainer: container)
        kit.activityLogger = logger
        scenes.activityLogger = logger
        self.activityLogger = logger
        self.automationsService = HomeKitAutomationsService(homeKit: kit)
        let notifier = SecurityNotificationService(homeKit: kit)
        self.securityNotifier = notifier
        let eventStore = AccessoryEventStore(modelContainer: container)
        kit.accessoryEventStore = eventStore
        self.accessoryEventStore = eventStore
        let aiSettings = AISettings()
        self.aiSettings = aiSettings
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
            HomeKitEntityResolver.resolveAccessory(
                remoteUUID: remoteUUID,
                accessoryName: accessoryName,
                roomName: roomName,
                in: kit.allAccessories.map {
                    HomeKitEntityResolver.AccessoryRef(
                        uuid: $0.uniqueIdentifier,
                        name: $0.name,
                        roomName: $0.room?.name
                    )
                }
            )
        }
        cloudSync.roomUUIDResolver = { remoteUUID, roomName in
            guard let home = kit.currentHome else { return nil }
            return HomeKitEntityResolver.resolveRoom(
                remoteUUID: remoteUUID,
                roomName: roomName,
                in: home.rooms.map {
                    HomeKitEntityResolver.RoomRef(uuid: $0.uniqueIdentifier, name: $0.name)
                }
            )
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
        self.cloudKitSync = cloudSync
        let habitSvc = HabitAnalysisService(aiSettings: aiSettings, modelContainer: container)
        self.habitAnalysisService = habitSvc
        // Tracker condiviso tra AmbientalAIService (per dismiss/expiration) e ActionExecutionService
        // (per trackExecution). Una sola istanza garantisce coerenza del dataset di efficacia.
        let sharedTracker = ActionEffectivenessTracker(modelContainer: container)
        self.actionExecutionService = ActionExecutionService(tracker: sharedTracker, modelContainer: container)
        let ambientalSvc = AmbientalAIService(
            aiSettings: aiSettings,
            modelContainer: container,
            homeKit: kit,
            tracker: sharedTracker
        )
        // Wire SensorEventRouter so high-priority sensor events bypass the 15-min analysis gate
        SensorEventRouter.shared.ambientalAI = ambientalSvc
        kit.sensorEventRouter = SensorEventRouter.shared
        self.ambientalAIService = ambientalSvc
        self.dataLifecycleService = DataLifecycleService(modelContainer: container)
        let behavioralSvc = BehavioralAnalysisService(modelContainer: container)
        // Anti-duplicazione abitudini: il motore confronta le opportunità con le
        // automazioni HomeKit esistenti prima di proporle (fotografie fresche a ogni analisi).
        behavioralSvc.existingAutomationsProvider = { [weak kit] in
            ExistingAutomationSnapshot.snapshots(from: kit?.currentHome)
        }
        behavioralSvc.habitNamingService = habitSvc
        self.behavioralAnalysisService = behavioralSvc
        self.proactiveIntelligenceService = ProactiveIntelligenceService(modelContainer: container)
        self.occupancyPredictionService = OccupancyPredictionService()
        self.locationPresenceService = LocationPresenceService()
        self.familyPresenceService = FamilyPresenceService()
        self.maintenancePredictionService = MaintenancePredictionService(modelContainer: container)

        SmartLightingIntentBridge.register(engine: lightingEngine)
    }
}
