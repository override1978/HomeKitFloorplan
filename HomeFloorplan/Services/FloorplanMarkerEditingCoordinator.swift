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

    private func saveAndMarkForSync() {
        floorplan.updatedAt = .now
        try? modelContext.save()
        cloudKitSync.markFloorplanNeedsSync(floorplan.id)
    }
}
