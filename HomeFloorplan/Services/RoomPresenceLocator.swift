import Foundation
import HomeKit

// MARK: - RoomPresenceLocator

/// «In che stanza sei?» — risposta dei sensori di casa, non della camera.
///
/// Nato dal verdetto sull'esperimento AR: la mappa della casa esiste già
/// (disegnata a mano), e chiedere all'utente di ri-scansionarla con ARKit per
/// localizzarsi era un controsenso. I sensori di presenza e movimento sono
/// già nei muri: l'ultimo che scatta dice la stanza. Zero calibrazione,
/// funziona col telefono in tasca.
///
/// Limite onesto, da dire in UI: rileva *qualcuno*, non necessariamente chi
/// tiene il telefono — in una casa con più persone la stanza è «dove c'è
/// vita», non «dove sei tu».
enum RoomPresenceLocator {

    struct Detection: Equatable {
        var roomName: String
        var accessoryName: String
        /// Occupancy pesa più di motion: un sensore di presenza dichiara
        /// «c'è qualcuno», il movimento può essere il gatto.
        var isOccupancy: Bool
    }

    /// Le stanze con presenza o movimento attivo **adesso**, il segnale più
    /// forte per primo. Lettura pura da `characteristicValues`: perché arrivi
    /// da sola serve `startObserving` sugli UUID di `presenceAccessoryUUIDs`.
    @MainActor
    static func activeDetections(homeKit: HomeKitService) -> [Detection] {
        var result: [Detection] = []
        for accessory in homeKit.allAccessories {
            guard let roomName = accessory.room?.name else { continue }
            for service in accessory.services {
                for characteristic in service.characteristics {
                    let type = characteristic.characteristicType
                    let isMotion = type == HMCharacteristicTypeMotionDetected
                    let isOccupancy = type == HMCharacteristicTypeOccupancyDetected
                    guard isMotion || isOccupancy else { continue }
                    let raw = homeKit.value(for: characteristic) ?? characteristic.value
                    let isActive = (raw as? Bool)
                        ?? (raw as? NSNumber)?.boolValue
                        ?? false
                    if isActive {
                        result.append(Detection(roomName: roomName,
                                                accessoryName: accessory.name,
                                                isOccupancy: isOccupancy))
                    }
                }
            }
        }
        return result.sorted { $0.isOccupancy && !$1.isOccupancy }
    }

    /// Le stanze che hanno ALMENO un sensore di presenza/movimento: le
    /// stanze fuori da questo insieme sono «cieche» — lì la presenza non
    /// scatterà mai, e chi le monitora deve avvisare a prescindere (il
    /// balcone è il caso che ha fatto nascere la regola).
    @MainActor
    static func roomNamesWithPresenceSensors(homeKit: HomeKitService) -> Set<String> {
        var result: Set<String> = []
        for accessory in homeKit.allAccessories {
            guard let roomName = accessory.room?.name else { continue }
            let hasPresence = accessory.services.contains { service in
                service.characteristics.contains {
                    $0.characteristicType == HMCharacteristicTypeMotionDetected
                        || $0.characteristicType == HMCharacteristicTypeOccupancyDetected
                }
            }
            if hasPresence { result.insert(roomName) }
        }
        return result
    }

    /// Gli accessori con sensori di presenza/movimento: sono quelli da
    /// osservare perché le letture si aggiornino senza polling di HomeKit.
    @MainActor
    static func presenceAccessoryUUIDs(homeKit: HomeKitService) -> Set<UUID> {
        var result: Set<UUID> = []
        for accessory in homeKit.allAccessories {
            let hasPresence = accessory.services.contains { service in
                service.characteristics.contains {
                    $0.characteristicType == HMCharacteristicTypeMotionDetected
                        || $0.characteristicType == HMCharacteristicTypeOccupancyDetected
                }
            }
            if hasPresence {
                result.insert(accessory.uniqueIdentifier)
            }
        }
        return result
    }
}
