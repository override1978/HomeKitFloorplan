import SwiftUI
import SwiftData
import HomeKit

struct FloorplanMarkerEditingCoordinator {
    let floorplan: Floorplan
    let modelContext: ModelContext
    let cloudKitSync: CloudKitSyncService
    let homeKit: HomeKitService

    func normalizedCenter(for room: LinkedRoom) -> NormalizedPoint {
        if let points = room.normalizedPoints, !points.isEmpty {
            let sum = points.reduce((x: 0.0, y: 0.0)) { partial, point in
                (partial.x + point.x, partial.y + point.y)
            }
            return NormalizedPoint(
                x: sum.x / Double(points.count),
                y: sum.y / Double(points.count)
            )
        }

        return NormalizedPoint(
            x: room.normalizedRect.x + room.normalizedRect.width / 2,
            y: room.normalizedRect.y + room.normalizedRect.height / 2
        )
    }

    func addAccessory(_ accessory: HMAccessory, at position: NormalizedPoint? = nil) {
        let markerPosition = position ?? .center
        let placed = PlacedAccessory(
            homeKitAccessoryUUID: accessory.uniqueIdentifier,
            position: markerPosition,
            linkedRoomUUID: FloorplanRoomMatcher.linkedRoomID(
                containing: markerPosition,
                in: floorplan.linkedRooms
            )
        )
        placed.floorplan = floorplan
        modelContext.insert(placed)
        floorplan.accessories.append(placed)
        saveAndMarkForSync()
    }

    func deleteMarker(_ placed: PlacedAccessory) {
        let uuid = placed.homeKitAccessoryUUID
        floorplan.accessories.removeAll { $0.id == placed.id }
        modelContext.delete(placed)
        saveAndMarkForSync()
        homeKit.stopObserving(accessoryUUIDs: [uuid])
    }

    func recenterMarker(_ placed: PlacedAccessory) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            placed.position = .center
        }
        saveAndMarkForSync()
    }

    func applyRename(to placed: PlacedAccessory, newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        placed.customLabel = trimmed.isEmpty ? nil : trimmed
        saveAndMarkForSync()
    }

    func alignMarkerRoomLink(_ placed: PlacedAccessory) {
        guard let roomID = FloorplanRoomMatcher.linkedRoomID(
            containing: placed.position,
            in: floorplan.linkedRooms
        ) else { return }

        placed.linkedRoomUUID = roomID
        floorplan.updatedAt = .now
        try? modelContext.save()
    }

    private func saveAndMarkForSync() {
        floorplan.updatedAt = .now
        try? modelContext.save()
        cloudKitSync.markFloorplanNeedsSync(floorplan.id)
    }
}
