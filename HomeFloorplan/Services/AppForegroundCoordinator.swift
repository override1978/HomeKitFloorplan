import Foundation
import SwiftData
import HomeKit

struct AppForegroundCoordinator {
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

    func runForegroundSamplingLoop(isActive: Bool) async {
        guard isActive else { return }
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

    func runCloudKitActivePollLoop(isActive: Bool) async {
        guard isActive else { return }
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

    func foregroundDidBecomeActive() {
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
