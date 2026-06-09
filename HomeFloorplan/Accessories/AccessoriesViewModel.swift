import SwiftUI
import HomeKit
import Observation

// MARK: - AccessoriesViewModel

/// ViewModel principale del modulo Accessori.
///
/// Aggrega gli HMAccessory di HomeKit per stanza, calcola il punteggio di
/// salute di ogni stanza via AccessoryHealthEngine e mantiene lo stato
/// del filtro categoria e della ricerca testuale.
///
/// Architettura identica a EnvironmentViewModel:
/// - @Observable (iOS 17+) per aggiornamenti reattivi granulari
/// - Lettura da HomeKitService senza modificarlo
/// - Nessuna dipendenza da AI o servizi asincroni complessi
@MainActor
@Observable
final class AccessoriesViewModel {

    // MARK: - Public state (letto dalle View)

    /// Stanze calcolate dall'ultimo refresh, ordinate alfabeticamente.
    var rooms: [RoomAccessoryData] = []

    /// True durante il primo calcolo (HomeKit non ancora pronto).
    var isLoading: Bool = true

    // MARK: - Filter state (mantenuto qui per persistenza tra navigazioni)

    var selectedCategory: AccessoryCategory = .all
    var selectedStateFilter: AccessoryStateFilter = .all
    var searchText: String = ""

    // MARK: - Room ordering (persiste in UserDefaults)

    /// UUID delle stanze nell'ordine scelto dall'utente (solo quelli con ordine esplicito).
    /// Stanze non presenti in questa lista vengono messe in fondo in ordine alfabetico.
    private static let orderKey = "accessoriesRoomOrder"

    private var customOrderIDs: [UUID] {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []
            return raw.compactMap { UUID(uuidString: $0) }
        }
        set {
            UserDefaults.standard.set(newValue.map { $0.uuidString }, forKey: Self.orderKey)
        }
    }

    /// Salva l'ordine delle stanze. Passare un array vuoto azzera l'ordine (torna ad alfabetico).
    func saveOrder(_ orderedRooms: [RoomAccessoryData]) {
        customOrderIDs = orderedRooms.map { $0.id }
    }

    // MARK: - Dependencies

    private let homeKit: HomeKitService

    // MARK: - Init

    init(homeKit: HomeKitService) {
        self.homeKit = homeKit
    }

    // MARK: - Refresh

    /// Ricalcola rooms leggendo lo stato corrente di HomeKitService.
    /// Chiamato in onAppear e ogni volta che HomeKit notifica un aggiornamento.
    func refresh() {
        guard homeKit.isReady else {
            isLoading = true
            return
        }

        isLoading = false

        guard let home = homeKit.currentHome else {
            rooms = []
            return
        }

        // Raggruppa gli accessori per stanza HomeKit
        let grouped = Dictionary(grouping: home.accessories) { (accessory: HMAccessory) -> UUID in
            accessory.room?.uniqueIdentifier ?? UUID.zero
        }

        // Costruisce un RoomAccessoryData per ogni stanza
        let newRooms: [RoomAccessoryData] = grouped.compactMap { (roomID, accessories) -> RoomAccessoryData? in
            // Stanza senza UUID reale: la includiamo con nome placeholder
            let roomName: String = {
                if roomID == UUID.zero {
                    return String(localized: "accessories.noRoomGroup", defaultValue: "No Room")
                }
                return accessories.first?.room?.name ?? "—"
            }()

            let score = AccessoryHealthEngine.score(for: accessories, homeKit: homeKit)
            let offline = AccessoryHealthEngine.offlineCount(for: accessories, homeKit: homeKit)
            let lowBatt = AccessoryHealthEngine.lowBatteryCount(for: accessories, homeKit: homeKit)
            let badges = AccessoryHealthEngine.categoryBadges(for: accessories, homeKit: homeKit)

            return RoomAccessoryData(
                id: roomID,
                roomName: roomName,
                accessories: accessories.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                },
                totalCount: accessories.count,
                offlineCount: offline,
                lowBatteryCount: lowBatt,
                healthScore: score,
                categoryBadges: badges,
                lastActivityDate: nil   // Sprint 6: integrazione con AccessoryEventStore
            )
        }

        // Applica ordine custom se salvato, altrimenti ordine alfabetico
        let orderIDs = customOrderIDs
        if orderIDs.isEmpty {
            rooms = newRooms.sorted {
                $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
            }
        } else {
            // Stanze con ordine esplicito prima, poi quelle nuove in fondo alfabeticamente
            var ordered: [RoomAccessoryData] = []
            for id in orderIDs {
                if let room = newRooms.first(where: { $0.id == id }) {
                    ordered.append(room)
                }
            }
            let orderedIDs = Set(ordered.map { $0.id })
            let remaining = newRooms
                .filter { !orderedIDs.contains($0.id) }
                .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }
            rooms = ordered + remaining
        }
    }

    // MARK: - Filtered rooms (applicati search + categoria + stato)

    /// Stanze visibili dopo aver applicato tutti i filtri correnti.
    var filteredRooms: [RoomAccessoryData] {
        rooms.compactMap { room -> RoomAccessoryData? in
            // 1. Filtra accessori per search text
            var accessories = room.accessories
            if !searchText.isEmpty {
                let needle = searchText.lowercased()
                accessories = accessories.filter {
                    $0.name.lowercased().contains(needle) ||
                    room.roomName.lowercased().contains(needle)
                }
                if accessories.isEmpty { return nil }
            }

            // 2. Filtra accessori per categoria
            if selectedCategory != .all {
                accessories = accessories.filter { accessory in
                    let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                    return AccessoryCategory.classify(adapter: adapter) == selectedCategory
                }
                if accessories.isEmpty { return nil }
            }

            // 3. Filtra accessori per stato
            // Usa !isReachable per coerenza con badge offline nelle card.
            if selectedStateFilter != .all {
                accessories = accessories.filter { accessory in
                    let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                    let isOffline = !homeKit.isReachable(accessory)
                    return selectedStateFilter.matches(adapter: adapter, isOffline: isOffline)
                }
                if accessories.isEmpty { return nil }
            }

            // Se il filtro ha modificato gli accessori, ricalcola i badge live
            // (lo score globale della stanza rimane quello originale per coerenza)
            if accessories.count == room.accessories.count {
                return room
            }
            let filteredBadges = AccessoryHealthEngine.categoryBadges(for: accessories, homeKit: homeKit)
            return RoomAccessoryData(
                id: room.id,
                roomName: room.roomName,
                accessories: accessories,
                totalCount: accessories.count,
                offlineCount: room.offlineCount,
                lowBatteryCount: room.lowBatteryCount,
                healthScore: room.healthScore,
                categoryBadges: filteredBadges,
                lastActivityDate: room.lastActivityDate
            )
        }
    }

    // MARK: - Global stats

    /// Totale accessori in tutte le stanze.
    var totalAccessoryCount: Int {
        rooms.reduce(0) { $0 + $1.totalCount }
    }

    /// Numero di stanze.
    var totalRoomCount: Int { rooms.count }

    /// Score globale: media pesata per numero di accessori per stanza.
    var globalHealthScore: Int {
        guard totalAccessoryCount > 0 else { return 100 }
        let weightedSum = rooms.reduce(0.0) {
            $0 + Double($1.healthScore) * Double($1.totalCount)
        }
        return Int(weightedSum / Double(totalAccessoryCount))
    }

    var globalHealthLevel: AccessoryHealthLevel { .from(score: globalHealthScore) }

    /// Numero totale di dispositivi offline in tutte le stanze.
    var totalOfflineCount: Int {
        rooms.reduce(0) { $0 + $1.offlineCount }
    }

    /// Numero totale di dispositivi con batteria scarica.
    var totalLowBatteryCount: Int {
        rooms.reduce(0) { $0 + $1.lowBatteryCount }
    }

    // MARK: - Filter state helpers

    /// True quando almeno un filtro è attivo (categoria, stato o testo di ricerca).
    var hasActiveFilters: Bool {
        selectedCategory != .all || selectedStateFilter != .all || !searchText.isEmpty
    }

    /// Lista piatta di accessori che matchano i filtri correnti,
    /// ognuno annotato con il nome della stanza di appartenenza.
    /// Usato quando `hasActiveFilters` è true.
    var filteredAccessories: [FlatAccessoryItem] {
        filteredRooms.flatMap { room in
            room.accessories.map { accessory in
                FlatAccessoryItem(
                    id: accessory.uniqueIdentifier,
                    roomName: room.roomName,
                    accessory: accessory
                )
            }
        }
    }

    // MARK: - Filter reset

    func resetFilters() {
        selectedCategory = .all
        selectedStateFilter = .all
        searchText = ""
    }
}

// MARK: - FlatAccessoryItem

/// Coppia leggera accessorio + nome stanza per la lista flat filtrata.
struct FlatAccessoryItem: Identifiable {
    let id: UUID
    let roomName: String
    let accessory: HMAccessory
}
