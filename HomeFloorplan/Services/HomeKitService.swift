import Foundation
import HomeKit
import Observation

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
    /// 2. Altrimenti fallback su manager.primaryHome
    /// 3. Altrimenti la prima disponibile
    var currentHome: HMHome? {
        guard let manager else { return nil }
        if let uuid = selectedHomeUUID,
           let match = manager.homes.first(where: { $0.uniqueIdentifier == uuid }) {
            return match
        }
        return manager.primaryHome ?? manager.homes.first
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
    
    /// Stato di autorizzazione HomeKit. `nil` finché non sappiamo (al lancio).
    var authorizationStatus: HMHomeManagerAuthorizationStatus?

    /// Helper che restituisce la reachability di un accessorio. Le view DEVONO
    /// usare questa, non `accessory.isReachable` direttamente, per beneficiare
    /// del tracking @Observable.
    func isReachable(_ accessory: HMAccessory) -> Bool {
        reachabilityMap[accessory.uniqueIdentifier] ?? accessory.isReachable
    }
    
    // MARK: - Private
    
    private var manager: HMHomeManager?

    /// True se HomeKit è stato attivato (HMHomeManager creato).
    var isHomeKitActivated: Bool { manager != nil }
    
    private var observedAccessoryUUIDs: Set<UUID> = []
    
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
                self.characteristicValues[characteristic.uniqueIdentifier] = value
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

    /// Soglia entro cui consideriamo un accessorio ancora "potenzialmente offline".
    /// Dopo questo tempo dall'ultimo errore, il flag si auto-cancella alla prossima lettura.
    private static let offlineWindow: TimeInterval = 300  // 5 minuti
    
    /// Scrive un valore su una caratteristica (es. accende una luce).
    /// Aggiorna anche localmente per dare risposta UI immediata (ottimistico).
    func write(_ value: Any, to characteristic: HMCharacteristic) async throws {
        do {
            try await characteristic.writeValue(value)
            characteristicValues[characteristic.uniqueIdentifier] = value
            
            // Successo: cancella eventuale errore precedente
            if let uuid = characteristic.service?.accessory?.uniqueIdentifier {
                lastWriteErrors.removeValue(forKey: uuid)
            }
        } catch {
            // Fallimento: registra errore con timestamp
            if let uuid = characteristic.service?.accessory?.uniqueIdentifier {
                lastWriteErrors[uuid] = Date()
            }
            throw error
        }
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
        print("🔄 refreshReachability su \(accessories.count) accessori")
        
        for accessory in accessories {
            accessory.delegate = self
        }
        
        await withTaskGroup(of: Void.self) { group in
            for accessory in accessories {
                group.addTask { [weak self] in
                    await self?.pokeAccessory(accessory)
                }
            }
        }
        
        // Aggiorna reachability map per propagare a SwiftUI
        await MainActor.run {
            for accessory in allAccessories {
                reachabilityMap[accessory.uniqueIdentifier] = accessory.isReachable
            }
            refreshAccessoriesList()
        }
        
        print("✅ refreshReachability completato")
    }

    /// Tenta di leggere fino a 2 caratteristiche readable del primary service.
    /// Questo "tocca" l'accessorio via HomeKit/HAP, scatena eventuali ri-connessioni
    /// e aggiorna isReachable internamente.
    private func pokeAccessory(_ accessory: HMAccessory) async {
        let primaryService = accessory.services.first(where: { $0.isPrimaryService })
                          ?? accessory.services.first
        guard let service = primaryService else { return }
        
        let readableChars = service.characteristics
            .filter { $0.properties.contains(HMCharacteristicPropertyReadable) }
            .prefix(2)
        
        for ch in readableChars {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ch.readValue { _ in
                    continuation.resume()
                }
            }
        }
    }
    
    // MARK: - Helpers per refresh
    
    private func refreshAccessoriesList() {
        allAccessories = currentHome?.accessories ?? []
    }
}

// MARK: - HMHomeManagerDelegate

// MARK: - HMHomeManagerDelegate

extension HomeKitService: HMHomeManagerDelegate {
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        //currentHome = manager.homes.first
        refreshAccessoriesList()
        
        // Seed iniziale della reachability map
        for accessory in allAccessories {
            reachabilityMap[accessory.uniqueIdentifier] = accessory.isReachable
        }
        
        authorizationStatus = manager.authorizationStatus
        isReady = true
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
            characteristicValues[characteristic.uniqueIdentifier] = value
        }
    }
    
    func accessoryDidUpdateReachability(_ accessory: HMAccessory) {
        reachabilityMap[accessory.uniqueIdentifier] = accessory.isReachable
        refreshAccessoriesList()
    }
    
    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        refreshAccessoriesList()
    }
    
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        refreshAccessoriesList()
    }
}
