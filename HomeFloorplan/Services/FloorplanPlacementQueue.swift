import Foundation
import HomeKit

// MARK: - FloorplanPlacementQueue

/// Coda dell'onboarding di posizionamento (fase 6): per ogni stanza disegnata,
/// i dispositivi HomeKit che le appartengono ma non hanno ancora un marker su
/// QUESTA planimetria. Non esistono marker orfani: l'origine è sempre la
/// stanza HomeKit (decisione 26/08), quindi la coda si raggruppa da sé.
struct FloorplanPlacementRoomQueue: Identifiable {
    let room: LinkedRoom
    /// Da posizionare, già filtrati (piazzabili, non posati, non saltati).
    let accessories: [HMAccessory]
    var id: UUID { room.hmRoomUUID }
    var remainingCount: Int { accessories.count }
    var isComplete: Bool { accessories.isEmpty }
}

@MainActor
enum FloorplanPlacementQueue {

    /// Le code per stanza, nell'ordine delle stanze disegnate. Le stanze già
    /// complete compaiono con coda vuota: servono al badge ✓ e al fill verde.
    static func roomQueues(
        floorplan: Floorplan,
        homeKit: HomeKitService,
        skipped: Set<UUID>
    ) -> [FloorplanPlacementRoomQueue] {
        let placedIDs = Set(floorplan.accessories.map(\.homeKitAccessoryUUID))
        return floorplan.linkedRooms.map { room in
            let queue = accessories(in: room, homeKit: homeKit)
                .filter { !placedIDs.contains($0.uniqueIdentifier) }
                .filter { !skipped.contains($0.uniqueIdentifier) }
                .filter { AccessoryAdapterFactory.adapter(for: $0, homeKit: homeKit).supportsFloorplanPlacement }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return FloorplanPlacementRoomQueue(room: room, accessories: queue)
        }
    }

    /// Quanti dispositivi mancano all'appello. Ignora i "salta" di sessione:
    /// è il numero della voce di menu, e un saltato resta comunque mancante.
    static func unplacedCount(floorplan: Floorplan, homeKit: HomeKitService) -> Int {
        roomQueues(floorplan: floorplan, homeKit: homeKit, skipped: [])
            .reduce(0) { $0 + $1.remainingCount }
    }

    /// Stesso aggancio stanza→accessori dell'overlay Sicurezza: UUID esatto,
    /// poi nome normalizzato (gli UUID delle stanze HomeKit non sono stabili
    /// tra device, il disegno può averne di vecchi).
    private static func accessories(in room: LinkedRoom, homeKit: HomeKitService) -> [HMAccessory] {
        let exact = homeKit.allAccessories.filter { $0.room?.uniqueIdentifier == room.hmRoomUUID }
        if !exact.isEmpty { return exact }
        let wanted = normalized(room.name)
        guard !wanted.isEmpty else { return [] }
        return homeKit.allAccessories.filter { normalized($0.room?.name ?? "") == wanted }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - FloorplanPlacementOnboardingModel

/// Stato di sessione del flusso di posizionamento guidato. Vive solo mentre
/// il flusso è aperto: gli "salta" NON si persistono — un dispositivo saltato
/// resta in coda e viene riproposto alla prossima apertura (da design).
@MainActor
@Observable
final class FloorplanPlacementOnboardingModel {
    enum Phase: Equatable {
        case pickRoom
        case placing(roomID: UUID)
    }

    var phase: Phase = .pickRoom
    var skipped: Set<UUID> = []
    /// UUID dell'accessorio correntemente proposto dal marker fantasma.
    var currentAccessoryUUID: UUID?
    /// Posizione del fantasma in coordinate normalizzate ORIGINALI.
    var ghostPosition: NormalizedPoint = .center
    var sessionPlaced = 0
    /// Fotografia della coda all'avvio: denominatore della barra di progresso.
    var initialTotal = 0
    /// Quanti erano in coda nella stanza corrente all'ingresso in fase 2:
    /// serve al contatore "N di M" sotto il fantasma.
    var roomInitialCount = 0
    var isCompleted = false

    var placingRoomID: UUID? {
        if case .placing(let roomID) = phase { return roomID }
        return nil
    }
}
