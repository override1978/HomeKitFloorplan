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
    let habitAnalysisService: HabitAnalysisService
    let occupancyPredictionService: OccupancyPredictionService
    let maintenancePredictionService: MaintenancePredictionService
    let locationPresenceService: LocationPresenceService

    /// Cadenze del loop foreground, persistite fuori dal task.
    ///
    /// `.task(id: scenePhase)` ricrea il loop a OGNI transizione di scena —
    /// Control Center, banner di notifica, app switcher. Con le cadenze come
    /// variabili locali ripartivano tutte da `nil`, e ogni riapertura scatenava
    /// subito, sul main actor, il campionamento completo (sensori luce, energia
    /// Matter, SmartLighting): da qui i freeze di decine di secondi tirando giù
    /// Control Center. Persisterle risolve anche il difetto speculare: i
    /// campionamenti a intervallo lungo (15 min) venivano rimandati all'infinito
    /// se le transizioni di scena erano più frequenti dell'intervallo.
    private enum Cadence {
        static let lightSample       = "foregroundLoop.lastLightSampleAt"
        static let matterEnergy      = "foregroundLoop.lastMatterEnergyRefreshAt"
        static let fullSensorSample  = "foregroundLoop.lastFullSensorSampleAt"
        static let observationBeat   = "foregroundLoop.lastObservationHeartbeatAt"
        static let smartLighting     = "foregroundLoop.lastSmartLightingEvaluationAt"
        static let proactiveCycle    = "foregroundLoop.lastProactiveCycleAt"

        static func last(_ key: String) -> Date? {
            UserDefaults.standard.object(forKey: key) as? Date
        }

        static func stamp(_ key: String, _ date: Date = Date()) {
            UserDefaults.standard.set(date, forKey: key)
        }

        /// True se non è mai stato eseguito o se è trascorso `interval`.
        static func isDue(_ key: String, interval: TimeInterval, now: Date) -> Bool {
            guard let last = last(key) else { return true }
            return now.timeIntervalSince(last) >= interval
        }
    }

    func runForegroundSamplingLoop(isActive: Bool) async {
        guard isActive else { return }
        let container = sharedModelContainer

        // Al primo avvio in assoluto le cadenze differite non devono partire
        // subito: si marcano "adesso" così il primo giro pesante arriva dopo
        // il rispettivo intervallo, non durante il lancio dell'app.
        if Cadence.last(Cadence.observationBeat) == nil {
            Cadence.stamp(Cadence.observationBeat)
        }
        if Cadence.last(Cadence.fullSensorSample) == nil {
            Cadence.stamp(Cadence.fullSensorSample, Date().addingTimeInterval(45 - 15 * 60))
        }
        if Cadence.last(Cadence.proactiveCycle) == nil {
            Cadence.stamp(Cadence.proactiveCycle, Date().addingTimeInterval(90 - 15 * 60))
        }

        while !Task.isCancelled {
            let now = Date()
            if let home = homeKit.currentHome {
                if Cadence.isDue(Cadence.lightSample, interval: 5 * 60, now: now) {
                    await SensorLogger.shared.sampleLightSensors(home: home, modelContainer: container)
                    Cadence.stamp(Cadence.lightSample)
                }

                if Cadence.isDue(Cadence.matterEnergy, interval: 5 * 60, now: now) {
                    await matterEnergyLiveStore.refreshIfNeeded(home: home, minimumInterval: 5 * 60)
                    Cadence.stamp(Cadence.matterEnergy)
                }

                if Cadence.isDue(Cadence.fullSensorSample, interval: 15 * 60, now: now) {
                    await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: container)
                    Cadence.stamp(Cadence.fullSensorSample)
                }

                // Heartbeat osservazione marker: su installazioni always-on le
                // notifiche push possono cadere senza che l'app se ne accorga
                // (mai un ciclo background→foreground a riallineare gli stati).
                // Ri-legge i valori e ri-arma le notifiche ogni 10 minuti.
                if Cadence.isDue(Cadence.observationBeat, interval: 10 * 60, now: now) {
                    homeKit.refreshObservedAccessories()
                    Cadence.stamp(Cadence.observationBeat)
                }
            }
            await weatherKitService.refreshIfNeeded()
            if let snapshot = weatherKitService.currentWeather {
                await SensorLogger.shared.sampleOutdoor(snapshot: snapshot, modelContainer: container)
            }

            if cloudKitSync.isMaster,
               Cadence.isDue(Cadence.smartLighting, interval: 5 * 60, now: now) {
                await smartLightingEngine.evaluate()
                Cadence.stamp(Cadence.smartLighting)
            }

            if Cadence.isDue(Cadence.proactiveCycle, interval: 15 * 60, now: now) {
                await proactiveIntelligenceService.runCycleIfNeeded(
                    habitService:       habitAnalysisService,
                    occupancyService:   occupancyPredictionService,
                    maintenanceService: maintenancePredictionService,
                    presenceOverride:   locationPresenceService.presenceState,
                    weatherService:     weatherKitService,
                    homeKitService:     homeKit
                )
                Cadence.stamp(Cadence.proactiveCycle)
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
        // Motore statistico ritirato: nessuna analisi comportamentale al
        // foreground (pivot Abitudini — evidenze + interprete LLM on-demand).
    }
}
