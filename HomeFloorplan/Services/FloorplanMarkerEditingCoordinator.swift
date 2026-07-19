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

    func deleteMarker(id markerID: UUID) {
        guard let placed = marker(withID: markerID) else { return }
        let uuid = placed.homeKitAccessoryUUID
        floorplan.accessories.removeAll { $0.id == markerID }
        modelContext.delete(placed)
        saveAndMarkForSync()
        homeKit.stopObserving(accessoryUUIDs: [uuid])
    }

    func recenterMarker(id markerID: UUID) {
        guard let placed = marker(withID: markerID) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            placed.position = .center
        }
        saveAndMarkForSync()
    }

    func moveMarker(id markerID: UUID, to position: NormalizedPoint) {
        guard let placed = marker(withID: markerID) else { return }
        placed.position = position
        placed.linkedRoomUUID = FloorplanRoomMatcher.linkedRoomID(
            containing: position,
            in: floorplan.linkedRooms
        )
        saveAndMarkForSync()
    }

    func applyRename(to markerID: UUID, newLabel: String) {
        guard let placed = marker(withID: markerID) else { return }
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        placed.customLabel = trimmed.isEmpty ? nil : trimmed
        saveAndMarkForSync()
    }

    func alignMarkerRoomLink(id markerID: UUID) {
        guard let placed = marker(withID: markerID) else { return }
        guard let roomID = FloorplanRoomMatcher.linkedRoomID(
            containing: placed.position,
            in: floorplan.linkedRooms
        ) else { return }

        placed.linkedRoomUUID = roomID
        saveAndMarkForSync()
    }

    func backfillMarkerRoomLinksIfNeeded() {
        guard !floorplan.linkedRooms.isEmpty else { return }

        var didUpdate = false
        for marker in floorplan.accessories where marker.linkedRoomUUID == nil {
            guard let roomID = FloorplanRoomMatcher.linkedRoomID(
                containing: marker.position,
                in: floorplan.linkedRooms
            ) else { continue }

            marker.linkedRoomUUID = roomID
            didUpdate = true
        }

        if didUpdate {
            saveAndMarkForSync()
        }
    }

    func preserveMarkerPositions(from previousRooms: [LinkedRoom],
                                 to newRooms: [LinkedRoom],
                                 previousRotation: DrawingExportRotation,
                                 newRotation: DrawingExportRotation) {
        let remapped = FloorplanMarkerRemapper.remap(
            placements: floorplan.accessories.map {
                FloorplanMarkerRemapper.Placement(
                    positionX: $0.positionX,
                    positionY: $0.positionY,
                    linkedRoomUUID: $0.linkedRoomUUID
                )
            },
            previousRooms: previousRooms,
            newRooms: newRooms,
            previousRotation: previousRotation,
            newRotation: newRotation
        )

        var didChange = false
        for (marker, new) in zip(floorplan.accessories, remapped) {
            guard marker.positionX != new.positionX ||
                    marker.positionY != new.positionY ||
                    marker.linkedRoomUUID != new.linkedRoomUUID else { continue }
            didChange = true
            marker.positionX = new.positionX
            marker.positionY = new.positionY
            marker.linkedRoomUUID = new.linkedRoomUUID
        }

        if didChange {
            saveAndMarkForSync()
        }
    }

    private func saveAndMarkForSync() {
        floorplan.updatedAt = .now
        try? modelContext.save()
        cloudKitSync.markFloorplanNeedsSync(floorplan.id)
    }

    private func marker(withID markerID: UUID) -> PlacedAccessory? {
        floorplan.accessories.first { $0.id == markerID }
    }
}
