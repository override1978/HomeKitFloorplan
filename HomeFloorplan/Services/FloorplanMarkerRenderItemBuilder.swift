import HomeKit

struct FloorplanMarkerRenderItemBuilder {
    let homeKit: HomeKitService
    let isEditing: Bool
    let allowsCameraSnapshot: Bool
    let selectedMarkerID: UUID?
    let executingMarkerID: UUID?
    let shakeMarkerID: UUID?
    let duplicatedMarkerAccessoryIDs: Set<UUID>
    let linkedRooms: [LinkedRoom]

    func makeItems(from placedAccessories: [PlacedAccessory]) -> [FloorplanMarkerRenderItem] {
        placedAccessories.map(makeItem)
    }

    private func makeItem(for placed: PlacedAccessory) -> FloorplanMarkerRenderItem {
        let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID)
        let adapter = accessory.map { AccessoryAdapterFactory.adapter(for: $0, homeKit: homeKit) }

        return FloorplanMarkerRenderItem(
            placed: placed,
            accessory: accessory,
            adapter: adapter,
            displayLabel: displayLabel(for: placed, accessory: accessory),
            editIssue: markerEditIssue(for: placed, accessory: accessory),
            allowsCameraSnapshot: allowsCameraSnapshot,
            isSelected: selectedMarkerID == placed.id,
            isExecuting: executingMarkerID == placed.id,
            isShaking: shakeMarkerID == placed.id
        )
    }

    private func displayLabel(for placed: PlacedAccessory, accessory: HMAccessory?) -> String {
        if let custom = placed.customLabel, !custom.isEmpty { return custom }
        guard let accessory else { return "(rimosso)" }
        let fullName = accessory.name
        if let roomName = accessory.room?.name {
            let suffix = " " + roomName
            if fullName.hasSuffix(suffix) {
                return String(fullName.dropLast(suffix.count))
            }
            let prefix = roomName + " - "
            if fullName.hasPrefix(prefix) {
                return String(fullName.dropFirst(prefix.count))
            }
        }
        return fullName
    }

    private func markerEditIssue(for placed: PlacedAccessory,
                                 accessory: HMAccessory?) -> AccessoryMarkerEditIssue? {
        guard isEditing else { return nil }

        if accessory == nil {
            return .missingHomeKitAccessory
        }

        if duplicatedMarkerAccessoryIDs.contains(placed.homeKitAccessoryUUID) {
            return .duplicateMarker
        }

        guard !linkedRooms.isEmpty else { return nil }

        let containingRoomID = FloorplanRoomMatcher.linkedRoomID(
            containing: placed.position,
            in: linkedRooms
        )

        guard let containingRoomID else {
            if let accessory,
               isPerimeterMarkerAccessory(accessory),
               FloorplanRoomMatcher.isNearAnyRoom(
                placed.position,
                in: linkedRooms,
                tolerance: perimeterMarkerRoomTolerance
               ) {
                return nil
            }
            return .outsideLinkedRoom
        }

        if placed.linkedRoomUUID != containingRoomID {
            if let accessory,
               isPerimeterMarkerAccessory(accessory),
               let linkedRoomUUID = placed.linkedRoomUUID,
               let linkedRoom = linkedRooms.first(where: { $0.hmRoomUUID == linkedRoomUUID }),
               FloorplanRoomMatcher.isNear(
                placed.position,
                to: linkedRoom,
                tolerance: perimeterMarkerRoomTolerance
               ) {
                return nil
            }
            return .roomLinkMismatch
        }

        return nil
    }

    private var perimeterMarkerRoomTolerance: Double {
        0.035
    }

    private func isPerimeterMarkerAccessory(_ accessory: HMAccessory) -> Bool {
        let category = AccessoryCategorizer.categorize(accessory)
        if category == "doorLock" ||
            category == "garageDoor" ||
            category == "windowCovering" {
            return true
        }

        let serviceTypes = Set(accessory.services.map(\.serviceType))
        return serviceTypes.contains(HMServiceTypeContactSensor) ||
            serviceTypes.contains(HMServiceTypeLockMechanism) ||
            serviceTypes.contains(HMServiceTypeGarageDoorOpener) ||
            serviceTypes.contains(HMServiceTypeWindowCovering)
    }
}
