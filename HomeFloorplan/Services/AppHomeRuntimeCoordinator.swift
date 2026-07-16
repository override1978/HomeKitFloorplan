import SwiftData
import HomeKit

struct AppHomeRuntimeCoordinator {
    let sharedModelContainer: ModelContainer
    let familyPresenceService: FamilyPresenceService
    let behavioralAnalysisService: BehavioralAnalysisService
    let occupancyPredictionService: OccupancyPredictionService
    let matterEnergyLiveStore: MatterEnergyLiveStore
    let ambientalAIService: AmbientalAIService

    func currentHomeDidChange(_ home: HMHome?) {
        guard let home else { return }
        familyPresenceService.autoActivateForCurrentUser(home: home)
        let profileID = familyPresenceService.activeProfileID
        behavioralAnalysisService.switchProfile(to: profileID)
        occupancyPredictionService.switchProfile(to: profileID)
        Task {
            await matterEnergyLiveStore.refreshIfNeeded(home: home)
        }
    }

    func currentWeatherDidChange(_ newWeather: WeatherSnapshot?) {
        ambientalAIService.currentWeather = newWeather
        if let snapshot = newWeather {
            let container = sharedModelContainer
            Task {
                await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
            }
        }
    }
}
