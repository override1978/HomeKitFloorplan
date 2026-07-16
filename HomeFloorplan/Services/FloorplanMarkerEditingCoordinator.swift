import SwiftUI
import SwiftData
import HomeKit

struct FloorplanMarkerEditingCoordinator {
    let floorplan: Floorplan
    let modelContext: ModelContext
    let cloudKitSync: CloudKitSyncService
    let homeKit: HomeKitService
    let iconOverrides: IconOverrideStore

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

    func moveMarker(_ placed: PlacedAccessory, to position: NormalizedPoint) {
        placed.position = position
        placed.linkedRoomUUID = FloorplanRoomMatcher.linkedRoomID(
            containing: position,
            in: floorplan.linkedRooms
        )
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

    func reconcileRemoteSnapshots(_ snapshots: [PlacedAccessorySnapshot]) -> Int {
        let existingByID = Dictionary(uniqueKeysWithValues: floorplan.accessories.map { ($0.id, $0) })
        var updatedCount = 0
        var didChange = false

        for snapshot in snapshots {
            guard let placed = existingByID[snapshot.id] else { continue }
            if placed.positionX != snapshot.positionX || placed.positionY != snapshot.positionY {
                updatedCount += 1
                didChange = true
            }
            if placed.linkedRoomUUID != snapshot.linkedRoomUUID || placed.customLabel != snapshot.customLabel {
                didChange = true
            }
            if iconOverrides.icon(for: placed.homeKitAccessoryUUID) != snapshot.iconOverride {
                didChange = true
            }
            placed.positionX = snapshot.positionX
            placed.positionY = snapshot.positionY
            placed.linkedRoomUUID = snapshot.linkedRoomUUID
            placed.customLabel = snapshot.customLabel
            if let iconOverride = snapshot.iconOverride {
                iconOverrides.setIcon(iconOverride, for: placed.homeKitAccessoryUUID)
            } else {
                iconOverrides.removeIcon(for: placed.homeKitAccessoryUUID)
            }
        }

        if didChange {
            try? modelContext.save()
        }

        return updatedCount
    }

    func preserveMarkerPositions(from previousRooms: [LinkedRoom],
                                 to newRooms: [LinkedRoom],
                                 previousRotation: DrawingExportRotation,
                                 newRotation: DrawingExportRotation) {
        guard !previousRooms.isEmpty, !newRooms.isEmpty else { return }

        let previousByID = Dictionary(uniqueKeysWithValues: previousRooms.map { ($0.hmRoomUUID, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newRooms.map { ($0.hmRoomUUID, $0) })
        let rotationDelta = (newRotation.quarterTurns - previousRotation.quarterTurns + 4) % 4
        var didChange = false

        for marker in floorplan.accessories {
            let markerPoint = NormalizedPoint(x: marker.positionX, y: marker.positionY)
            guard let roomID = marker.linkedRoomUUID ?? roomID(containing: markerPoint, in: previousRooms),
                  let previousRoom = previousByID[roomID],
                  let newRoom = newByID[roomID] else { continue }

            let previousRect = previousRoom.normalizedRect
            let newRect = newRoom.normalizedRect
            guard previousRect.width > 0, previousRect.height > 0 else { continue }

            let localX = (marker.positionX - previousRect.x) / previousRect.width
            let localY = (marker.positionY - previousRect.y) / previousRect.height
            let rotatedLocal = rotatedLocalPoint(x: localX, y: localY, quarterTurns: rotationDelta)
            let newPositionX = clamped(markerPosition: newRect.x + rotatedLocal.x * newRect.width)
            let newPositionY = clamped(markerPosition: newRect.y + rotatedLocal.y * newRect.height)
            let newLinkedRoomID = FloorplanRoomMatcher.linkedRoomID(
                containing: NormalizedPoint(x: newPositionX, y: newPositionY),
                in: newRooms
            ) ?? roomID

            if marker.positionX != newPositionX ||
                marker.positionY != newPositionY ||
                marker.linkedRoomUUID != newLinkedRoomID {
                didChange = true
            }

            marker.positionX = newPositionX
            marker.positionY = newPositionY
            marker.linkedRoomUUID = newLinkedRoomID
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

    private func rotatedLocalPoint(x: Double, y: Double, quarterTurns: Int) -> (x: Double, y: Double) {
        switch quarterTurns {
        case 1:
            return (1 - y, x)
        case 2:
            return (1 - x, 1 - y)
        case 3:
            return (y, 1 - x)
        default:
            return (x, y)
        }
    }

    private func roomID(containing point: NormalizedPoint, in rooms: [LinkedRoom]) -> UUID? {
        rooms.first { room in
            let rect = room.normalizedRect
            return point.x >= rect.x &&
                point.x <= rect.x + rect.width &&
                point.y >= rect.y &&
                point.y <= rect.y + rect.height
        }?.hmRoomUUID
    }

    private func clamped(markerPosition value: Double) -> Double {
        min(1, max(0, value))
    }
}
