import Foundation

struct FloorplanAccessoryObservationCoordinator {
    let homeKit: HomeKitService

    func subscribe(to floorplan: Floorplan) {
        homeKit.startObserving(accessoryUUIDs: accessoryUUIDs(for: floorplan))
    }

    func unsubscribe(from floorplan: Floorplan) {
        homeKit.stopObserving(accessoryUUIDs: accessoryUUIDs(for: floorplan))
    }

    private func accessoryUUIDs(for floorplan: Floorplan) -> Set<UUID> {
        Set(floorplan.accessories.map(\.homeKitAccessoryUUID))
    }
}
