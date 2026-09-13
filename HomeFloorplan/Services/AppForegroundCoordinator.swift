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
    let maintenancePredictionService: MaintenancePredictionService
    let locationPresenceService: LocationPresenceService
    let dataLifecycleService: DataLifecycleService
    let automationsService: HomeKitAutomationsService
    let automationSkips: AutomationSkipStore

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

    /// Riaccende le automazioni il cui salto è scaduto.
    ///
    /// Se la riaccensione fallisce il salto **non** si cancella: resterà lì e
    /// si riproverà al giro dopo. Dimenticarlo lascerebbe un'automazione spenta
    /// per sempre senza che niente lo dica, che è il modo peggiore in cui
    /// questa funzione può rompersi.
    private func restoreExpiredSkips() async {
        let expired = await automationSkips.expiredTriggerIDs()
        guard !expired.isEmpty else { return }
        if await automationsService.automations.isEmpty {
            await automationsService.refresh()
        }
        for triggerID in expired {
            guard let item = await automationsService.automations.first(where: { $0.id == triggerID })
            else {
                // Il trigger non esiste più: il salto non ha più un oggetto e
                // tenerlo significherebbe riprovare all'infinito.
                await automationSkips.clearSkip(triggerID)
                continue
            }
            do {
                try await automationsService.setEnabled(true, for: item)
                await automationSkips.clearSkip(triggerID)
                dprint("⏭ Salto scaduto: \(item.name) torna attiva")
            } catch {
                dprint("⚠️ Ripristino fallito per \(item.name): si riprova al prossimo giro")
            }
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

        // Lo stato ambientale in memoria nasce vuoto: le notifiche HomeKit lo
        // riempiono man mano, ma finché non ne arriva una la casa non ha un
        // presente da mostrare. La prima semina lo popola dai valori già in
        // cache nel framework, senza un solo round-trip.
        var didSeedHomeState = false

        while !Task.isCancelled {
            let now = Date()
            // Le automazioni saltate tornano in funzione da sole.
            //
            // È la parte che rende onesta la promessa di «stavolta no»:
            // HomeKit non ha un salto, solo uno spegnimento, quindi qualcuno
            // deve ricordarsi di riaccendere. Sta qui e non su un timer perché
            // un timer non scatta se l'app è chiusa, mentre questo giro passa a
            // ogni ritorno in primo piano — e la scadenza è persistita, quindi
            // sopravvive a riavvii e chiusure.
            await restoreExpiredSkips()

            if let home = homeKit.currentHome {
                if !didSeedHomeState {
                    // Prima le sottoscrizioni, poi la semina. L'ordine conta:
                    // `subscribe` fa partire le letture che popolano la cache
                    // del framework, e la semina raccoglie ciò che è già lì.
                    // I valori che arrivano dopo entrano da soli, perché la
                    // lettura iniziale alimenta HomeState anche lei.
                    homeKit.observeHistorySources()
                    homeKit.seedHomeState()
                    didSeedHomeState = true
                }

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
                    // Subito dopo la rilettura vera: la cache del framework è
                    // appena stata rinfrescata, quindi ri-confermare le letture
                    // qui è onesto. Il filtro di raggiungibilità dentro
                    // `seedHomeState` esclude chi non ha risposto.
                    homeKit.seedHomeState()
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

            // Ciclo dati: il BGProcessingTask che lo ospitava non è MAI stato
            // concesso da iOS su questo tipo di device — un pannello sempre
            // acceso e in primo piano non entra mai nello stato di inattività
            // che quel task richiede. Misurato: lastCycleCycle=NEVER con 166.555
            // letture grezze mai aggregate né potate. Qui è una rete di
            // sicurezza, non il canale primario: il BG task resta per i device
            // che davvero si mettono in idle.
            //
            // NON gated su isMaster: aggregare e potare le PROPRIE letture
            // locali non ha effetti duplicabili tra device. La guardia serve a
            // ciò che duplicherebbe effetti esterni — notifiche, scritture
            // CloudKit — e resta sul ciclo intelligence qui sotto.
            let lastLifecycle = dataLifecycleService.lastCycleDate
            if lastLifecycle == nil || now.timeIntervalSince(lastLifecycle!) >= 24 * 3600 {
                await dataLifecycleService.runFullCycle()
            }

            if Cadence.isDue(Cadence.proactiveCycle, interval: 15 * 60, now: now) {
                await proactiveIntelligenceService.runCycleIfNeeded(
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

    /// Rete di sicurezza del sync, non il canale principale.
    ///
    /// La propagazione live è affidata alle push della CKRecordZoneSubscription
    /// (misurata: ~0,5 s dalla notifica all'aggiornamento della vista). Questo
    /// loop copre solo i casi in cui una push si perde o l'app riparte con lo
    /// stato di sync disallineato, quindi può permettersi un intervallo lungo.
    ///
    /// Era a 20 s quando le push non arrivavano affatto — mancava la
    /// subscription — e produceva ~4.300 fetch al giorno su un pannello sempre
    /// in foreground, con blocchi del main thread sparsi tutta la notte.
    func runCloudKitActivePollLoop(isActive: Bool) async {
        guard isActive else { return }
        let interval: TimeInterval = 5 * 60
        while !Task.isCancelled {
            await cloudKitSync.fetchRemoteChangesIfNeeded(
                reason: "active-poll",
                minimumInterval: interval
            )
            await cloudKitSync.fetchZoneChangesDeterministicallyIfNeeded(
                reason: "active-poll",
                minimumInterval: interval
            )
            do {
                try await Task.sleep(for: .seconds(interval))
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
