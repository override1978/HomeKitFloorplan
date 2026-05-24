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
    var currentHome: HMHome?
    
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
    
    // MARK: - Private
    
    private let manager = HMHomeManager()
    private var observedAccessoryUUIDs: Set<UUID> = []
    
    // MARK: - Init
    
    override init() {
        super.init()
        manager.delegate = self
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
    
    /// Scrive un valore su una caratteristica (es. accende una luce).
    /// Aggiorna anche localmente per dare risposta UI immediata (ottimistico).
    func write(_ value: Any, to characteristic: HMCharacteristic) async throws {
        try await characteristic.writeValue(value)
        characteristicValues[characteristic.uniqueIdentifier] = value
    }
    
    // MARK: - Helpers per refresh
    
    private func refreshAccessoriesList() {
        allAccessories = manager.homes.flatMap { $0.accessories }
    }
}

// MARK: - HMHomeManagerDelegate

extension HomeKitService: HMHomeManagerDelegate {
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        currentHome = manager.homes.first
        refreshAccessoriesList()
        isReady = true
    }
    
    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        refreshAccessoriesList()
    }
    
    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        refreshAccessoriesList()
    }
    
    func homeManagerDidUpdatePrimaryHome(_ manager: HMHomeManager) {
        currentHome = manager.homes.first
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
        // Forza un refresh della lista così le View possono mostrare lo stato offline
        refreshAccessoriesList()
    }
    
    func accessoryDidUpdateName(_ accessory: HMAccessory) {
        refreshAccessoriesList()
    }
    
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        refreshAccessoriesList()
    }
}
