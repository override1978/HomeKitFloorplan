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
            editIssue: auditService.editIssue(for: placed, accessory: accessory),
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

    private var auditService: FloorplanMarkerAuditService {
        FloorplanMarkerAuditService(
            isEditing: isEditing,
            duplicatedMarkerAccessoryIDs: duplicatedMarkerAccessoryIDs,
            linkedRooms: linkedRooms
        )
    }
}
