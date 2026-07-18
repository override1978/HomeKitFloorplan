import Foundation
import HomeKit

struct FloorplanSelectedMarkerToolbarStateBuilder {
    let homeKit: HomeKitService
    let markerAuditService: FloorplanMarkerAuditService

    func state(for marker: PlacedAccessory) -> FloorplanSelectedMarkerToolbarState {
        let accessory = homeKit.accessory(for: marker.homeKitAccessoryUUID)
        let removedFallback = String(localized: "marker.accessory.removed", defaultValue: "(removed)")
        let displayName = marker.customLabel?.isEmpty == false
            ? marker.customLabel!
            : (accessory?.name ?? removedFallback)

        return FloorplanSelectedMarkerToolbarState(
            markerName: displayName,
            initialRenameText: marker.customLabel ?? "",
            auditNotice: markerAuditService.auditNotice(for: marker, accessory: accessory)
        )
    }
}
