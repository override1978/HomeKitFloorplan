import Foundation
import HomeKit
import Observation
import UserNotifications

/// Service centrale per l'interazione con HomeKit.
/// - Esposto come `@Observable` (iOS 17+): le View che leggono le sue
///   proprietà si aggiornano automaticamente quando lo stato cambia.
/// - Mantiene `characteristicValues` come dizionario "stato corrente",
///   aggiornato sia in pull (readValue) che in push (didUpdateValueFor).
@Observable
final class HomeKitService: NSObject {
    
    // MARK: - Public state
    
    /// La casa primaria scelta dall'utente nell'app Casa (può essere nil al primo avvio).
    //var currentHome: HMHome?
    /// UUID della casa selezionata dall'utente (persistita in UserDefaults).
    /// Nil = usa la primary di HomeKit.
    private static let selectedHomeUUIDKey = "selectedHomeUUID"

    var selectedHomeUUID: UUID? {
        didSet {
            if let uuid = selectedHomeUUID {
                UserDefaults.standard.set(uuid.uuidString, forKey: Self.selectedHomeUUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedHomeUUIDKey)
            }
            refreshAccessoriesList()
        }
    }

    /// La casa attualmente attiva. Logica:
    /// 1. Se l'utente ne ha scelta una via selectedHomeUUID, usa quella
    /// 2. Altrimenti la prima disponibile (primaryHome è deprecated da iOS 16.1)
    var currentHome: HMHome? {
        guard let manager else { return nil }
        if let uuid = selectedHomeUUID,
           let match = manager.homes.first(where: { $0.uniqueIdentifier == uuid }) {
            return match
        }
        return manager.homes.first
    }

    /// Tutte le case configurate dall'utente in Apple Home (per il selettore).
    var availableHomes: [HMHome] {
        manager?.homes ?? []
    }
    
    /// Tutti gli accessori di tutte le case configurate.
    var allAccessories: [HMAccessory] = []
    
    /// Diventa true dopo il primo `homeManagerDidUpdateHomes` (cioè quando
    /// l'utente ha concesso il permesso e i dati sono disponibili).
    var isReady: Bool = false
    
    /// Stato attuale delle caratteristiche, indicizzato per `characteristic.uniqueIdentifier`.
    /// Le View leggono da qui per disegnare lo stato (on/off, brightness, ecc.).
    var characteristicValues: [UUID: Any] = [:]
    
    /// Errori recenti (utile per debug e UI di diagnostica)
    var lastError: String?
    
    /// Reachability di ogni accessorio, tracciata come @Observable.
    /// Il delegate `accessoryDidUpdateReachability` aggiorna qui, e le view
    /// che leggono via `isReachable(_:)` si ridisegnano correttamente.
    var reachabilityMap: [UUID: Bool] = [:]

    /// Incrementato ogni volta che la reachabilityMap cambia (anche solo in valore,
    /// non solo in conteggio). Le view osservano questo per reagire a tutti i cambi.
    var reachabilityVersion: Int = 0

    /// True quando il SecuritySystem ha currentState == triggered (valore HAP 4).
    /// Aggiornato direttamente nel delegate per una risposta UI immediata, senza
    /// passare per la catena adapter → computed property.
    var isAlarmSystemTriggered: Bool = false

    /// Diventa true dopo il secondo refresh differito (~12 s dal lancio).
    /// Finché è false, `isReachable(_:)` restituisce sempre true per evitare
    /// false-offline durante la fase di discovery iniziale di HomeKit.
    var reachabilitySettled: Bool = false

    /// Stato di autorizzazione HomeKit. `nil` finché non sappiamo (al lancio).
    var authorizationStatus: HMHomeManagerAuthorizationStatus?

    /// Helper che restituisce la reachability di un accessorio. Le view DEVONO
    /// usare questa, non `accessory.isReachable` direttamente, per beneficiare
    /// del tracking @Observable.
    ///
    /// Durante il grace period iniziale (`!reachabilitySettled`) restituisce
    /// sempre `true`: HomeKit impiega fino a ~12s per stabilizzare la reachability
    /// al lancio, e durante questo intervallo i valori sono inaffidabili.
    func isReachable(_ accessory: HMAccessory) -> Bool {
        guard reachabilitySettled else { return true }
        return reachabilityMap[accessory.uniqueIdentifier] ?? accessory.isReachable
    }
    
    // MARK: - Private
    
    private var manager: HMHomeManager?

    /// True se HomeKit è stato attivato (HMHomeManager creato).
    var isHomeKitActivated: Bool { manager != nil }

    /// Logger attività. Iniettato dall'app dopo l'init.
    var activityLogger: ActivityLoggerService?

    /// Store eventi accessori per lo storico AI. Iniettato dall'app dopo l'init.
    var accessoryEventStore: AccessoryEventStore?

    /// Routes sensor value changes to the unified analysis pipeline. Iniettato dall'app dopo l'init.
    var sensorEventRouter: SensorEventRouter?

    /// Smart Lighting engine. Iniettato dall'app per sospendere temporaneamente
    /// una stanza quando l'utente cambia manualmente una luce.
    weak var smartLightingEngine: SmartLightingEngine?
    
    private var observedAccessoryUUIDs: Set<UUID> = []
    private var knownAccessoryUUIDsForNotifications: Set<UUID> = []
    private var accessoryNotificationBaselineHomeUUID: UUID?
    private var hasSeededAccessoryNotificationBaseline = false

    // Pending characteristic values waiting to be flushed into `characteristicValues`.
    // Only accessed on MainActor (via Task { @MainActor in } in queueCharacteristicUpdate).
    private var pendingValues: [UUID: Any] = [:]
    private var flushScheduled = false

    // MARK: - Init
    
    override init() {
        super.init()
        
        // Retrocompatibilità: se l'utente ha già completato l'onboarding in passato,
        // attiva HomeKit subito (altrimenti l'app si ritrova senza HMHomeManager).
        let lastSeenOnboarding = UserDefaults.standard.integer(forKey: "onboardingLastSeenVersion")
        if lastSeenOnboarding >= 1 {
            activateHomeKit()
        }
    }
    
    /// Attiva HomeKit creando HMHomeManager e iniziando la lettura.
    /// Chiamato dall'onboarding al tap "Concedi permessi", oppure all'init
    /// per utenti che hanno già completato l'onboarding in passato.
    func requestHomeKitAccess() {
        activateHomeKit()
    }

    private func activateHomeKit() {
        guard manager == nil else { return }
        
        let m = HMHomeManager()
        m.delegate = self
        manager = m
        
        authorizationStatus = m.authorizationStatus
        
        // Carica l'UUID casa selezionata da UserDefaults
        if let str = UserDefaults.standard.string(forKey: Self.selectedHomeUUIDKey),
           let uuid = UUID(uuidString: str) {
            selectedHomeUUID = uuid
        }
    }
    
    // MARK: - Lookup
    
    /// Risolve un HMAccessory dal suo UUID (quello salvato in PlacedAccessory).
    func accessory(for uuid: UUID) -> HMAccessory? {
        allAccessories.first { $0.uniqueIdentifier == uuid }
    }

    /// Returns the HomeKit zone that contains the given room, if the user configured one.
    func zone(for room: HMRoom) -> HMZone? {
        currentHome?.zones.first { zone in
            zone.rooms.contains { $0.uniqueIdentifier == room.uniqueIdentifier }
        }
    }

    /// Returns the HomeKit zone that contains the accessory room, if available.
    func zone(for accessory: HMAccessory) -> HMZone? {
        guard let room = accessory.room else { return nil }
        return zone(for: room)
    }

    func zoneName(for accessory: HMAccessory) -> String? {
        zone(for: accessory)?.name
    }
    
    /// Restituisce il valore corrente di una caratteristica (se osservata).
    func value(for characteristic: HMCharacteristic) -> Any? {
        characteristicValues[characteristic.uniqueIdentifier]
    }
    
    /// Forza una rilettura dell'authorizationStatus dal framework HomeKit.
    /// Utile quando l'utente torna dall'app Settings.
    func reloadAuthorizationStatus() {
        authorizationStatus = manager?.authorizationStatus
    }
    
    /// Cambia la casa attiva. Triggera refresh delle liste e dei marker.
    func setActiveHome(_ home: HMHome) {
        selectedHomeUUID = home.uniqueIdentifier
    }

    /// Resetta alla casa primaria di HomeKit.
    func resetToPrimaryHome() {
        selectedHomeUUID = nil
    }

    /// Returns whether a floorplan should be considered part of the active home.
    /// HomeKit UUIDs can differ across devices for the same household after CloudKit sync;
    /// with a single local home, an unknown remote UUID is treated as belonging here.
    func matchesActiveHome(_ floorplanHomeUUID: UUID?) -> Bool {
        guard let floorplanHomeUUID else { return true }
        guard let currentHomeUUID = currentHome?.uniqueIdentifier else { return true }
        if floorplanHomeUUID == currentHomeUUID { return true }

        let localHomeUUIDs = Set(availableHomes.map(\.uniqueIdentifier))
        return availableHomes.count <= 1 && !localHomeUUIDs.contains(floorplanHomeUUID)
    }
    
    // MARK: - Batched characteristic updates

    /// Coalesces multiple HomeKit pushes that arrive in the same RunLoop tick into a
    /// single `characteristicValues` mutation — reducing SwiftUI re-renders from
    /// O(events/second) to O(1/tick) across all observers (AccessoryMarkerView, etc.).
    private func queueCharacteristicUpdate(_ uuid: UUID, value: Any) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingValues[uuid] = value
            guard !self.flushScheduled else { return }
            self.flushScheduled = true
            // Yield so other queued updates (same tick) accumulate in pendingValues first.
            await Task.yield()
            for (k, v) in self.pendingValues {
                self.characteristicValues[k] = v
            }
            self.pendingValues.removeAll()
            self.flushScheduled = false
        }
    }

    // MARK: - Subscription lifecycle
    
    /// Inizia a osservare un insieme di accessori. Tipicamente chiamato
    /// quando si apre un floorplan: passi gli UUID degli accessori piazzati.
    /// - Note: abilita le notifiche solo sulle caratteristiche che le supportano,
    ///   e legge il valore iniziale di tutte le altre.
    func startObserving(accessoryUUIDs: Set<UUID>) {
        for uuid in accessoryUUIDs {
            guard let accessory = accessory(for: uuid),
                  !observedAccessoryUUIDs.contains(uuid) else { continue }
            
            accessory.delegate = self
            observedAccessoryUUIDs.insert(uuid)
            
            for service in accessory.services {
                for characteristic in service.characteristics {
                    subscribe(to: characteristic)
                }
            }
        }
    }
    
    /// Smette di osservare gli accessori (utile in onDisappear della editor view).
    func stopObserving(accessoryUUIDs: Set<UUID>) {
        for uuid in accessoryUUIDs {
            guard let accessory = accessory(for: uuid) else { continue }
            for service in accessory.services {
                for characteristic in service.characteristics
                where characteristic.isNotificationEnabled {
                    characteristic.enableNotification(false) { _ in }
                }
            }
            observedAccessoryUUIDs.remove(uuid)
        }
    }
    
    private static let securityCurrentStateTypeUUID = "00000066-0000-1000-8000-0026bb765291"

    /// Aggiorna `isAlarmSystemTriggered` se la caratteristica è CurrentSecuritySystemState.
    private func updateAlarmTriggeredIfNeeded(_ characteristic: HMCharacteristic, value: Any) {
        guard characteristic.characteristicType.lowercased() == Self.securityCurrentStateTypeUUID else { return }
        let raw = (value as? Int) ?? (value as? NSNumber)?.intValue ?? -1
        isAlarmSystemTriggered = (raw == 4)
    }

    private func subscribe(to characteristic: HMCharacteristic) {
        let supportsNotifications = characteristic.properties
            .contains(HMCharacteristicPropertySupportsEventNotification)

        // 1) Lettura valore iniziale
        characteristic.readValue { [weak self] error in
            guard let self else { return }
            if let error {
                self.lastError = "readValue \(characteristic.localizedDescription): \(error.localizedDescription)"
                return
            }
            if let value = characteristic.value {
                self.queueCharacteristicUpdate(characteristic.uniqueIdentifier, value: value)
                self.updateAlarmTriggeredIfNeeded(characteristic, value: value)
            }
        }
        
        // 2) Abilita notifiche se supportate
        if supportsNotifications && !characteristic.isNotificationEnabled {
            characteristic.enableNotification(true) { [weak self] error in
                if let error {
                    self?.lastError = "enableNotification \(characteristic.localizedDescription): \(error.localizedDescription)"
                }
            }
        }
    }
    
    // MARK: - Write (comandi)
    /// UUID di accessori che hanno fallito una scrittura recente.
    /// Mappa UUID accessorio → timestamp dell'ultimo errore.
    /// Le view leggono via `isLikelyOffline(_:)` per mostrare warning.
    var lastWriteErrors: [UUID: Date] = [:]
    private var lastWriteDates: [UUID: Date] = [:]

    /// Soglia entro cui consideriamo un accessorio ancora "potenzialmente offline".
    /// Dopo questo tempo dall'ultimo errore, il flag si auto-cancella alla prossima lettura.
    private static let offlineWindow: TimeInterval = 300  // 5 minuti
    
    /// Scrive un valore su una caratteristica (es. accende una luce).
    /// Aggiorna anche localmente per dare risposta UI immediata (ottimistico).
    func write(_ value: Any, to characteristic: HMCharacteristic) async throws {
        do {
            try await characteristic.writeValue(value)
            characteristicValues[characteristic.uniqueIdentifier] = value
            lastWriteDates[characteristic.uniqueIdentifier] = .now

            // Successo: cancella eventuale errore precedente
            if let uuid = characteristic.service?.accessory?.uniqueIdentifier {
                lastWriteErrors.removeValue(forKey: uuid)
            }

            // Log attività
            if let logger = activityLogger,
               let accessory = characteristic.service?.accessory {
                let (name, valStr) = ActivityLoggerService.describe(characteristic: characteristic, value: value)
                await MainActor.run {
                    logger.logWrite(
                        characteristicUUID: characteristic.uniqueIdentifier,
                        accessoryName: accessory.name,
                        roomName: accessory.room?.name,
                        characteristicDescription: name,
                        value: valStr
                    )
                }
            }

            if let accessory = characteristic.service?.accessory {
                pauseSmartLightingAfterManualLightChange(accessory: accessory, characteristic: characteristic)
            }

            // Registra evento per lo storico AI (solo tipi rilevanti)
            if let store = accessoryEventStore,
               let accessory = characteristic.service?.accessory,
               let dto = AccessoryEventStore.makeDTO(
                   from: characteristic, value: value, accessory: accessory) {
                await MainActor.run {
                    store.saveEvent(dto)
                }
            }
        } catch {
            // Fallimento: registra errore con timestamp
            if let uuid = characteristic.service?.accessory?.uniqueIdentifier {
                lastWriteErrors[uuid] = Date()
            }
            throw error
        }
    }

    func wasRecentlyWritten(_ characteristic: HMCharacteristic, within interval: TimeInterval) -> Bool {
        guard let date = lastWriteDates[characteristic.uniqueIdentifier] else { return false }
        return Date().timeIntervalSince(date) <= interval
    }
    
    /// True se l'accessorio ha avuto un errore di scrittura recente (entro `offlineWindow`).
    /// Più affidabile di `accessory.isReachable` perché basato su azioni REALI fallite.
    func isLikelyOffline(_ accessory: HMAccessory) -> Bool {
        guard let lastError = lastWriteErrors[accessory.uniqueIdentifier] else {
            return false
        }
        return Date().timeIntervalSince(lastError) < Self.offlineWindow
    }
    
    /// "Stuzzica" tutti gli accessori HomeKit per forzare una rivalutazione della
    /// reachability. Setta il delegate su ognuno (per ricevere notifiche future),
    /// e tenta di leggere una characteristic readable di ciascuno.
    /// L'effetto è simile a un "ping" e in molti casi sveglia device dormienti.
    func refreshReachability() async {
        let accessories = allAccessories
        dprint("🔄 refreshReachability su \(accessories.count) accessori")
        
        for accessory in accessories {
            accessory.delegate = self
        }
        
        // Raccoglie i risultati della poke: UUID → true se almeno una lettura è riuscita.
        // Se la lettura riesce, l'accessorio è raggiungibile indipendentemente da isReachable.
        var confirmedReachable: Set<UUID> = []
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for accessory in accessories {
                let uuid = accessory.uniqueIdentifier
                group.addTask { [weak self] in
                    let reachable = await self?.pokeAccessory(accessory) ?? false
                    return (uuid, reachable)
                }
            }
            for await (uuid, reachable) in group {
                if reachable { confirmedReachable.insert(uuid) }
            }
        }

        // Aggiorna reachability map: usa il risultato della poke come fonte primaria.
        // refreshAccessoriesList() prima per ottenere oggetti HMAccessory freschi
        // (HomeKit può ricreare gli oggetti internamente, il delegate è weak).
        await MainActor.run {
            refreshAccessoriesList()
            for accessory in allAccessories {
                let uuid = accessory.uniqueIdentifier
                reachabilityMap[uuid] = confirmedReachable.contains(uuid) || accessory.isReachable
            }
            reachabilityVersion += 1
        }

        dprint("✅ refreshReachability completato")
    }

    /// Tenta di leggere fino a 2 caratteristiche readable del primary service.
    /// Ritorna true se almeno una lettura riesce (prova diretta di raggiungibilità),
    /// false se tutte falliscono o non ci sono caratteristiche leggibili.
    private func pokeAccessory(_ accessory: HMAccessory) async -> Bool {
        let primaryService = accessory.services.first(where: { $0.isPrimaryService })
                          ?? accessory.services.first
        guard let service = primaryService else { return false }

        let readableChars = service.characteristics
            .filter { $0.properties.contains(HMCharacteristicPropertyReadable) }
            .prefix(2)

        for ch in readableChars {
            let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                ch.readValue { error in
                    continuation.resume(returning: error == nil)
                }
            }
            if succeeded { return true }
        }
        return false
    }
    
    // MARK: - Security system persistent observation

    /// Abilita le notifiche HomeKit sulle caratteristiche di tutti i SecuritySystem
    /// presenti nella casa. Chiamato ad ogni `homeManagerDidUpdateHomes` in modo che
    /// il delegate `accessory(_:service:didUpdateValueFor:)` riceva gli aggiornamenti
    /// anche quando SecurityView non è visibile (es. allarme scatta mentre l'utente
    /// è su un'altra tab).
    private func startObservingSecuritySystems() {
        let securitySystemServiceType = "0000007E-0000-1000-8000-0026BB765291"
        for accessory in allAccessories {
            guard accessory.services.contains(where: { $0.serviceType == securitySystemServiceType })
            else { continue }

            accessory.delegate = self
            for service in accessory.services {
                for characteristic in service.characteristics {
                    subscribe(to: characteristic)
                }
            }
        }
    }

    // MARK: - Helpers per refresh

    private func refreshAccessoriesList() {
        let fresh = currentHome?.accessories ?? []
        let homeUUID = currentHome?.uniqueIdentifier
        currentHome?.delegate = self

        // Re-imposta il delegate su ogni accessorio ad ogni refresh:
        // HomeKit può ricreare internamente gli oggetti HMAccessory (il delegate
        // è weak), quindi questa è l'unica garanzia che accessoryDidUpdateReachability
        // venga sempre ricevuto per tutti gli accessori della casa.
        for accessory in fresh {
            if accessory.delegate == nil {
                accessory.delegate = self
            }
        }
        allAccessories = fresh
        notifyAddedAccessoriesIfNeeded(fresh, homeUUID: homeUUID)
    }

    private func notifyAddedAccessoriesIfNeeded(_ accessories: [HMAccessory], homeUUID: UUID?) {
        let currentUUIDs = Set(accessories.map(\.uniqueIdentifier))

        guard isReady,
              hasSeededAccessoryNotificationBaseline,
              accessoryNotificationBaselineHomeUUID == homeUUID else {
            knownAccessoryUUIDsForNotifications = currentUUIDs
            accessoryNotificationBaselineHomeUUID = homeUUID
            hasSeededAccessoryNotificationBaseline = true
            return
        }

        let addedUUIDs = currentUUIDs.subtracting(knownAccessoryUUIDsForNotifications)
        knownAccessoryUUIDsForNotifications = currentUUIDs

        guard !addedUUIDs.isEmpty else { return }
        for accessory in accessories where addedUUIDs.contains(accessory.uniqueIdentifier) {
            sendAccessoryAddedNotification(for: accessory)
        }
    }

    private func sendAccessoryAddedNotification(for accessory: HMAccessory) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                  settings.authorizationStatus == .provisional ||
                  settings.authorizationStatus == .ephemeral else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "homekit.accessory.added.notification.title",
                                   defaultValue: "New accessory added")
            if let roomName = accessory.room?.name, !roomName.isEmpty {
                content.body = String(
                    format: String(localized: "homekit.accessory.added.notification.body.room",
                                   defaultValue: "%1$@ is now available in %2$@."),
                    accessory.name,
                    roomName
                )
            } else {
                content.body = String(
                    format: String(localized: "homekit.accessory.added.notification.body",
                                   defaultValue: "%@ is now available in HomeFloorplan."),
                    accessory.name
                )
            }
            content.sound = .default
            content.categoryIdentifier = NotificationCategory.deviceHealth.unCategoryIdentifier
            content.threadIdentifier = "com.homefloorplan.accessory.lifecycle"
            content.targetContentIdentifier = accessory.uniqueIdentifier.uuidString

            let request = UNNotificationRequest(
                identifier: "accessory-added-\(accessory.uniqueIdentifier.uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request) { error in
                if let error {
                    dprint("🔔 Notifica accessorio aggiunto fallita per \(accessory.name): \(error)")
                }
            }
        }
    }
}

// MARK: - HMHomeManagerDelegate

// MARK: - HMHomeManagerDelegate

extension HomeKitService: HMHomeManagerDelegate {
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        // Ogni volta che HomeKit aggiorna le case, resettiamo il grace period:
        // i valori di reachability sono di nuovo potenzialmente instabili.
        reachabilitySettled = false

        //currentHome = manager.homes.first
        refreshAccessoriesList()

        // Seed iniziale della reachability map con lo stato attuale.
        // Il delegate è già impostato da refreshAccessoriesList() chiamata sopra.
        for accessory in allAccessories {
            reachabilityMap[accessory.uniqueIdentifier] = accessory.isReachable
        }
        reachabilityVersion += 1

        authorizationStatus = manager.authorizationStatus
        isReady = true

        // Abilita immediatamente le notifiche HomeKit sul sistema di allarme,
        // così gli aggiornamenti di stato arrivano anche quando SecurityView non è visibile.
        startObservingSecuritySystems()

        // HomeKit impiega alcuni secondi dopo il lancio per completare la discovery
        // e aggiornare isReachable. Eseguiamo due refresh differiti: uno precoce
        // (4s) e uno tardivo (12s) per coprire device più lenti (Matter bridge, mesh).
        // Solo dopo il secondo refresh impostiamo reachabilitySettled = true:
        // finché non è settled, isReachable() restituisce sempre true (grace period),
        // evitando i false-offline tipici dei primi secondi dopo il lancio.
        Task {
            try? await Task.sleep(for: .seconds(4))
            await refreshReachability()
            try? await Task.sleep(for: .seconds(8))
            await refreshReachability()
            await MainActor.run {
                reachabilitySettled = true
                reachabilityVersion += 1   // forza un ultimo redraw con i dati stabilizzati
            }
        }
    }
    
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        refreshAccessoriesList()
    }
    
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        refreshAccessoriesList()
    }
    
    /// True se HomeKit non ha permessi e non possiamo procedere.
    var isAuthorizationDenied: Bool {
        guard let status = authorizationStatus else { return false }
        return !status.contains(.authorized) && status.contains(.determined)
    }

    /// True se non sappiamo ancora lo status (primo lancio, HomeKit non ha ancora risposto).
    var isAuthorizationUnknown: Bool {
        authorizationStatus == nil || !(authorizationStatus?.contains(.determined) ?? false)
    }
    
    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        authorizationStatus = status
        if status.contains(.authorized) {
            refreshAccessoriesList()
        }
    }
}

// MARK: - HMHomeDelegate

extension HomeKitService: HMHomeDelegate {
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        refreshAccessoriesList()
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) {
        refreshAccessoriesList()
    }
}

// MARK: - HMAccessoryDelegate

extension HomeKitService: HMAccessoryDelegate {
    
    /// Questo è IL metodo magico: viene chiamato quando un valore cambia
    /// "spontaneamente" (es. l'utente accende la luce dall'app Casa, o un
    /// sensore di movimento triggera). Aggiornando characteristicValues qui,
    /// tutte le View che osservano @Observable si ridisegnano.
    func accessory(_ accessory: HMAccessory,
                   service: HMService,
                   didUpdateValueFor characteristic: HMCharacteristic) {
        if let value = characteristic.value {
            queueCharacteristicUpdate(characteristic.uniqueIdentifier, value: value)
            updateAlarmTriggeredIfNeeded(characteristic, value: value)

            // Se HomeKit ci sta consegnando aggiornamenti, l'accessorio è raggiungibile
            // per definizione — indipendentemente da ciò che isReachable riporta.
            // Questo corregge il falso-offline su device che HomeKit API segna come
            // irraggiungibili ma che in realtà comunicano correttamente (Matter bridge, ecc.)
            if reachabilitySettled && reachabilityMap[accessory.uniqueIdentifier] == false {
                reachabilityMap[accessory.uniqueIdentifier] = true
                reachabilityVersion += 1
            }

            // Log cambiamento esterno (con echo-dedup e debounce interni al service)
            if let logger = activityLogger {
                let (name, valStr) = ActivityLoggerService.describe(characteristic: characteristic, value: value)
                logger.logExternalChange(
                    characteristicUUID: characteristic.uniqueIdentifier,
                    accessoryName: accessory.name,
                    roomName: accessory.room?.name,
                    characteristicDescription: name,
                    value: valStr
                )
            }

            pauseSmartLightingAfterManualLightChange(accessory: accessory, characteristic: characteristic)

            // Registra evento per lo storico AI (solo tipi rilevanti)
            if let store = accessoryEventStore,
               let dto = AccessoryEventStore.makeDTO(
                   from: characteristic, value: value, accessory: accessory) {
                store.saveEvent(dto)
            }

            // Instrada letture sensore verso la pipeline unificata di analisi.
            sensorEventRouter?.route(characteristic: characteristic, value: value, accessory: accessory)
        }
    }
    
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        let newValue = accessory.isReachable
        guard reachabilityMap[accessory.uniqueIdentifier] != newValue else { return }
        reachabilityMap[accessory.uniqueIdentifier] = newValue
        reachabilityVersion += 1
    }
    
    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        refreshAccessoriesList()
    }
    
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        refreshAccessoriesList()
    }
}

private extension HomeKitService {
    func pauseSmartLightingAfterManualLightChange(accessory: HMAccessory, characteristic: HMCharacteristic) {
        // Smart Lighting is paused/resumed explicitly from the floorplan.
        // Characteristic updates are not reliable enough to infer manual intent.
    }
}
