import HomeKit

struct FloorplanMarkerRenderItemBuilder {
    /// Mappa accessorio → adapter costruita a monte (e cache-ata dalla view):
    /// evita la scansione lineare di `homeKit.accessory(for:)` e la ricostruzione
    /// dell'adapter per ogni marker a ogni chiamata.
    let adaptersByUUID: [UUID: any AccessoryAdapter]
    let isEditing: Bool
    let allowsCameraSnapshot: Bool
    let selectedMarkerID: UUID?
    let executingMarkerID: UUID?
    let shakeMarkerID: UUID?
    let duplicatedMarkerAccessoryIDs: Set<UUID>
    let linkedRooms: [LinkedRoom]

    func makeItems(from placedAccessories: [PlacedAccessory]) -> [FloorplanMarkerRenderItem] {
        let auditService = self.auditService
        return placedAccessories.map { makeItem(for: $0, auditService: auditService) }
    }

    private func makeItem(for placed: PlacedAccessory,
                          auditService: FloorplanMarkerAuditService) -> FloorplanMarkerRenderItem {
        let adapter = adaptersByUUID[placed.homeKitAccessoryUUID]
        let accessory = adapter?.accessory

        return FloorplanMarkerRenderItem(
            id: placed.id,
            homeKitAccessoryUUID: placed.homeKitAccessoryUUID,
            position: placed.position,
            linkedRoomUUID: placed.linkedRoomUUID,
            customLabel: placed.customLabel,
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
        guard let accessory else {
            return String(localized: "marker.accessory.removed", defaultValue: "(removed)")
        }
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
