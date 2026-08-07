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
        if Self.watchesOpenings(accessory) {
            placed.linkedOpeningID = openingID(under: markerPosition)
        }
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
        if let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID),
           Self.watchesOpenings(accessory) {
            placed.linkedOpeningID = openingID(under: position)
        }
        saveAndMarkForSync()
    }

    /// Quota e direzione di una luce: i due fatti che la pianta non contiene.
    ///
    /// Sta qui e non in una chiusura scritta nella vista perche' e' una
    /// scrittura sul modello come le altre — e come le altre deve passare da
    /// `saveAndMarkForSync`, o la modifica resta sul device e non arriva su
    /// CloudKit.
    func setLampSettings(accessoryUUID: UUID, height: Double, direction: LampDirection) {
        guard let placed = floorplan.accessories.first(where: {
            $0.homeKitAccessoryUUID == accessoryUUID
        }) else { return }
        guard placed.mountHeight != height || placed.lightDirectionRaw != direction.rawValue else { return }

        placed.mountHeight = height
        placed.lightDirectionRaw = direction.rawValue
        saveAndMarkForSync()
    }

    /// L'esposizione della planimetria: verso dove guarda il lato alto.
    func setNorthBearing(_ degrees: Double) {
        guard floorplan.northBearingDegrees != degrees else { return }
        floorplan.northBearingDegrees = degrees
        saveAndMarkForSync()
    }

    func applyRename(to markerID: UUID, newLabel: String) {
        guard let placed = marker(withID: markerID) else { return }
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        placed.customLabel = trimmed.isEmpty ? nil : trimmed
        saveAndMarkForSync()
    }

    /// L'apertura sotto un marker, se ce n'è una.
    ///
    /// Solo per i sensori di contatto: un termometro appoggiato vicino a una
    /// porta non la sorveglia, e agganciarlo la farebbe aprire quando si alza
    /// la temperatura.
    static func watchesOpenings(_ accessory: HMAccessory) -> Bool {
        accessory.services.contains { service in
            service.characteristics.contains { $0.characteristicType == HMCharacteristicTypeContactState }
        }
    }

    private func openingID(under position: NormalizedPoint) -> UUID? {
        guard let document = floorplan.drawingDocument else { return nil }
        return FloorplanOpeningMatcher.nearestOpening(
            to: CGPoint(x: position.x, y: position.y),
            in: document,
            exportRotation: floorplan.drawingExportRotation
        )
    }

    /// Ricalcola il legame con l'apertura per **tutti** i contatti.
    ///
    /// Va chiamata quando il disegno cambia: il marker resta dov'era ma i vani
    /// si sono spostati, o sono spariti, o ne sono nati di nuovi. Senza questo
    /// il legame resta quello di prima e punta a un'apertura che magari non
    /// esiste più — e siccome non si vede da nessuna parte, il difetto sarebbe
    /// silenzioso.
    func refreshMarkerOpeningLinks() {
        guard floorplan.drawingDocument != nil else { return }

        var didUpdate = false
        for marker in floorplan.accessories {
            guard let accessory = homeKit.accessory(for: marker.homeKitAccessoryUUID),
                  Self.watchesOpenings(accessory)
            else { continue }
            let resolved = openingID(under: marker.position)
            guard marker.linkedOpeningID != resolved else { continue }
            marker.linkedOpeningID = resolved
            didUpdate = true
        }
        if didUpdate { saveAndMarkForSync() }
    }

    /// Riempie i legami mancanti sui marker già posati, così chi ha una
    /// planimetria da prima non deve rifare niente.
    func backfillMarkerOpeningLinksIfNeeded() {
        guard floorplan.drawingDocument != nil else { return }

        var didUpdate = false
        for marker in floorplan.accessories where marker.linkedOpeningID == nil {
            guard let accessory = homeKit.accessory(for: marker.homeKitAccessoryUUID),
                  Self.watchesOpenings(accessory),
                  let openingID = openingID(under: marker.position)
            else { continue }
            marker.linkedOpeningID = openingID
            didUpdate = true
        }
        if didUpdate { saveAndMarkForSync() }
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
