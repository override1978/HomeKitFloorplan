import Foundation

/// Risoluzione di UUID HomeKit remoti (da CloudKit) verso le entità locali.
///
/// Gli UUID HomeKit sono per-device: lo stesso accessorio ha identifier diversi
/// su iPhone e iPad. Il sync quindi porta con sé nome (e stanza) normalizzati e
/// questo resolver prova prima il match diretto per UUID, poi nome+stanza, poi
/// solo nome. Estratto dalle closure inline di `HomeFloorplanApp.init` per
/// renderlo unit-testabile su dati puri (niente HMAccessory/HMRoom).
enum HomeKitEntityResolver {

    struct AccessoryRef {
        let uuid: UUID
        let name: String
        let roomName: String?

        init(uuid: UUID, name: String, roomName: String?) {
            self.uuid = uuid
            self.name = name
            self.roomName = roomName
        }
    }

    struct RoomRef {
        let uuid: UUID
        let name: String

        init(uuid: UUID, name: String) {
            self.uuid = uuid
            self.name = name
        }
    }

    /// Normalizza un token HomeKit (nome accessorio/stanza) per il confronto:
    /// trim + lowercased; nil se vuoto.
    static func normalizedToken(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Risolve l'UUID locale di un accessorio remoto:
    /// 1. match diretto per UUID; 2. nome+stanza; 3. solo nome; 4. nil.
    static func resolveAccessory(remoteUUID: UUID,
                                 accessoryName: String?,
                                 roomName: String?,
                                 in accessories: [AccessoryRef]) -> UUID? {
        if accessories.contains(where: { $0.uuid == remoteUUID }) {
            return remoteUUID
        }

        guard let normalizedName = normalizedToken(accessoryName) else { return nil }
        let normalizedRoom = normalizedToken(roomName)

        if let normalizedRoom,
           let roomMatch = accessories.first(where: {
               normalizedToken($0.name) == normalizedName &&
               normalizedToken($0.roomName) == normalizedRoom
           }) {
            return roomMatch.uuid
        }

        return accessories.first {
            normalizedToken($0.name) == normalizedName
        }?.uuid
    }

    /// Risolve l'UUID locale di una stanza remota:
    /// 1. match diretto per UUID; 2. nome normalizzato; 3. nil.
    static func resolveRoom(remoteUUID: UUID,
                            roomName: String?,
                            in rooms: [RoomRef]) -> UUID? {
        if rooms.contains(where: { $0.uuid == remoteUUID }) {
            return remoteUUID
        }

        guard let normalizedName = normalizedToken(roomName) else { return nil }
        return rooms.first {
            normalizedToken($0.name) == normalizedName
        }?.uuid
    }
}
