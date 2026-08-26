import SwiftUI
import HomeKit

// MARK: - FloorplanRoomCluster

/// Riassunto di una stanza per la vista a cluster del tab Controlli
/// (redesign, novità C): quanti dispositivi per categoria, quanti attivi,
/// e quali marker le appartengono.
struct FloorplanRoomCluster: Identifiable {
    let room: LinkedRoom
    /// Conteggi per categoria, ordinati per numerosità decrescente.
    let counts: [CategoryCount]
    /// ID dei `PlacedAccessory` della stanza — servono per mostrare solo i
    /// suoi marker quando la stanza è espansa.
    let markerIDs: Set<UUID>

    var id: UUID { room.hmRoomUUID }
    var totalCount: Int { counts.reduce(0) { $0 + $1.total } }
    var activeCount: Int { counts.reduce(0) { $0 + $1.active } }

    struct CategoryCount: Identifiable, Equatable {
        let category: AccessoryCategory
        var total: Int
        var active: Int
        var id: String { category.rawValue }
    }
}

// MARK: - FloorplanControlsClusterBuilder

/// Raggruppa i marker posati per stanza e per categoria. Stateless come gli
/// altri controller del floorplan.
@MainActor
enum FloorplanControlsClusterBuilder {

    /// Stanza di appartenenza di un marker. Prima la stanza HomeKit di
    /// origine dell'accessorio (decisione redesign del 26/08: ogni dispositivo
    /// ha una stanza d'origine, non esistono marker orfani), poi il link
    /// geometrico derivato dalla posizione come ripiego.
    static func roomID(for placed: PlacedAccessory,
                       rooms: [LinkedRoom],
                       adapterMap: [UUID: any AccessoryAdapter]) -> UUID? {
        roomID(adapter: adapterMap[placed.homeKitAccessoryUUID],
               linkedRoomUUID: placed.linkedRoomUUID,
               rooms: rooms)
    }

    /// Variante sugli input già risolti (usata dal filtro dei render item).
    static func roomID(adapter: (any AccessoryAdapter)?,
                       linkedRoomUUID: UUID?,
                       rooms: [LinkedRoom]) -> UUID? {
        if let homeKitRoomName = adapter?.accessory.room?.name,
           let match = rooms.first(where: {
               FloorplanRoomMatcher.matches(roomName: homeKitRoomName, linkedRoom: $0)
           }) {
            return match.hmRoomUUID
        }
        return linkedRoomUUID
    }

    /// Un cluster per ogni stanza che ha almeno un marker.
    static func clusters(floorplan: Floorplan,
                         adapterMap: [UUID: any AccessoryAdapter]) -> [FloorplanRoomCluster] {
        let rooms = floorplan.linkedRooms
        guard !rooms.isEmpty else { return [] }

        var markersByRoom: [UUID: [PlacedAccessory]] = [:]
        for placed in floorplan.accessories {
            guard let roomID = roomID(for: placed, rooms: rooms, adapterMap: adapterMap) else {
                continue
            }
            markersByRoom[roomID, default: []].append(placed)
        }

        return rooms.compactMap { room in
            guard let markers = markersByRoom[room.hmRoomUUID], !markers.isEmpty else {
                return nil
            }
            var byCategory: [AccessoryCategory: (total: Int, active: Int)] = [:]
            for placed in markers {
                let adapter = adapterMap[placed.homeKitAccessoryUUID]
                let category = AccessoryCategory.classify(adapter: adapter)
                var entry = byCategory[category] ?? (0, 0)
                entry.total += 1
                if adapter?.isOn == true { entry.active += 1 }
                byCategory[category] = entry
            }
            let ordered = byCategory
                .map { FloorplanRoomCluster.CategoryCount(category: $0.key,
                                                          total: $0.value.total,
                                                          active: $0.value.active) }
                .sorted { lhs, rhs in
                    if lhs.total != rhs.total { return lhs.total > rhs.total }
                    return lhs.category.rawValue < rhs.category.rawValue
                }
            return FloorplanRoomCluster(room: room,
                                        counts: ordered,
                                        markerIDs: Set(markers.map(\.id)))
        }
    }

    /// Conteggi per la riga chips filtro: (categoria, totale, attivi)
    /// sull'intero piano, ordinati per numerosità.
    static func floorCategoryCounts(floorplan: Floorplan,
                                    adapterMap: [UUID: any AccessoryAdapter]) -> [FloorplanRoomCluster.CategoryCount] {
        var byCategory: [AccessoryCategory: (total: Int, active: Int)] = [:]
        var seen = Set<UUID>()
        for placed in floorplan.accessories {
            // Un accessorio con più marker (multipresa duplicata) conta una volta.
            guard !seen.contains(placed.homeKitAccessoryUUID) else { continue }
            seen.insert(placed.homeKitAccessoryUUID)
            let adapter = adapterMap[placed.homeKitAccessoryUUID]
            let category = AccessoryCategory.classify(adapter: adapter)
            var entry = byCategory[category] ?? (0, 0)
            entry.total += 1
            if adapter?.isOn == true { entry.active += 1 }
            byCategory[category] = entry
        }
        return byCategory
            .map { FloorplanRoomCluster.CategoryCount(category: $0.key,
                                                      total: $0.value.total,
                                                      active: $0.value.active) }
            .sorted { lhs, rhs in
                if lhs.total != rhs.total { return lhs.total > rhs.total }
                return lhs.category.rawValue < rhs.category.rawValue
            }
    }

    /// Categoria di un marker, per il filtro.
    static func category(of placed: PlacedAccessory,
                         adapterMap: [UUID: any AccessoryAdapter]) -> AccessoryCategory {
        AccessoryCategory.classify(adapter: adapterMap[placed.homeKitAccessoryUUID])
    }
}
