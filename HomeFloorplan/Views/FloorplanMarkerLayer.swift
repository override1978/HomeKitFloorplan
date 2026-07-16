import SwiftUI
import HomeKit

struct FloorplanMarkerRenderItem: Identifiable {
    let id: UUID
    let homeKitAccessoryUUID: UUID
    let position: NormalizedPoint
    let linkedRoomUUID: UUID?
    let customLabel: String?
    let accessory: HMAccessory?
    let adapter: (any AccessoryAdapter)?
    let displayLabel: String
    let hasCustomLabel: Bool
    let editIssue: AccessoryMarkerEditIssue?
    let allowsCameraSnapshot: Bool
    let isSelected: Bool
    let isExecuting: Bool
    let isShaking: Bool

    init(
        id: UUID,
        homeKitAccessoryUUID: UUID,
        position: NormalizedPoint,
        linkedRoomUUID: UUID?,
        customLabel: String?,
        accessory: HMAccessory?,
        adapter: (any AccessoryAdapter)?,
        displayLabel: String,
        editIssue: AccessoryMarkerEditIssue?,
        allowsCameraSnapshot: Bool,
        isSelected: Bool,
        isExecuting: Bool,
        isShaking: Bool
    ) {
        self.id = id
        self.homeKitAccessoryUUID = homeKitAccessoryUUID
        self.position = position
        self.linkedRoomUUID = linkedRoomUUID
        self.customLabel = customLabel
        self.accessory = accessory
        self.adapter = adapter
        self.displayLabel = displayLabel
        self.hasCustomLabel = customLabel?.isEmpty == false
        self.editIssue = editIssue
        self.allowsCameraSnapshot = allowsCameraSnapshot
        self.isSelected = isSelected
        self.isExecuting = isExecuting
        self.isShaking = isShaking
    }
}

struct FloorplanMarkerLayer<MarkerContent: View, EmptyContent: View>: View {
    let items: [FloorplanMarkerRenderItem]
    let imageRect: CGRect
    let collisionOffsets: [UUID: CGSize]
    let markerContent: (FloorplanMarkerRenderItem, CGSize) -> MarkerContent
    let emptyContent: () -> EmptyContent

    var body: some View {
        Group {
            if items.isEmpty {
                emptyContent()
                    .position(x: imageRect.midX, y: imageRect.midY)
            } else {
                ForEach(items) { item in
                    markerContent(item, collisionOffsets[item.id] ?? .zero)
                }
            }
        }
    }
}
