import HomeKit

struct FloorplanMarkerAuditService {
    let isEditing: Bool
    let duplicatedMarkerAccessoryIDs: Set<UUID>
    let linkedRooms: [LinkedRoom]

    func editIssue(for placed: PlacedAccessory, accessory: HMAccessory?) -> AccessoryMarkerEditIssue? {
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

    func auditNotice(for placed: PlacedAccessory, accessory: HMAccessory?) -> MarkerAuditNotice? {
        guard let issue = editIssue(for: placed, accessory: accessory) else { return nil }

        switch issue {
        case .missingHomeKitAccessory:
            return MarkerAuditNotice(
                systemImage: issue.systemImage,
                title: String(localized: "marker.audit.missing.title", defaultValue: "Accessory not found"),
                message: String(localized: "marker.audit.missing.message", defaultValue: "This marker points to a HomeKit accessory that is no longer available. You can delete it from the floorplan."),
                tint: issue.color,
                actionTitle: String(localized: "marker.audit.deleteMarker", defaultValue: "Delete marker")
            )
        case .duplicateMarker:
            return MarkerAuditNotice(
                systemImage: issue.systemImage,
                title: String(localized: "marker.audit.duplicate.title", defaultValue: "Duplicate marker"),
                message: String(localized: "marker.audit.duplicate.message", defaultValue: "The same accessory appears more than once on the floorplan. If this is unintended, delete the selected duplicate."),
                tint: issue.color,
                actionTitle: String(localized: "marker.audit.deleteDuplicate", defaultValue: "Delete duplicate")
            )
        case .outsideLinkedRoom:
            return MarkerAuditNotice(
                systemImage: issue.systemImage,
                title: String(localized: "marker.audit.outsideRoom.title", defaultValue: "Outside linked rooms"),
                message: String(localized: "marker.audit.outsideRoom.message", defaultValue: "The marker is not inside a linked room. You can move it manually or recenter it on the floorplan."),
                tint: issue.color,
                actionTitle: String(localized: "marker.audit.recenter", defaultValue: "Recenter")
            )
        case .roomLinkMismatch:
            return MarkerAuditNotice(
                systemImage: issue.systemImage,
                title: String(localized: "marker.audit.roomMismatch.title", defaultValue: "Room needs realignment"),
                message: String(localized: "marker.audit.roomMismatch.message", defaultValue: "The marker is inside a different room than the saved one. You can realign it to the current room."),
                tint: issue.color,
                actionTitle: String(localized: "marker.audit.realignRoom", defaultValue: "Realign room")
            )
        }
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
