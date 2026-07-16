import SwiftUI
import SwiftData
import HomeKit

struct FloorplanEditorPresentationModifier: ViewModifier {
    let floorplan: Floorplan
    let homeKit: HomeKitService
    let modelContext: ModelContext
    let cloudKitSync: CloudKitSyncService
    let accessoryPickerTitle: String

    @Binding var showingPicker: Bool
    @Binding var pickerRoomFilter: UUID?
    @Binding var pendingMarkerPosition: NormalizedPoint?
    @Binding var editHighlightedRoomID: UUID?
    @Binding var controllingAccessory: HMAccessory?
    @Binding var iconPickerTargetID: UUID?
    @Binding var showFloorplanDiagnostics: Bool
    @Binding var showFloorplanHelp: Bool
    @Binding var drawingEditFloorplan: Floorplan?
    @Binding var pendingDeleteMarkerID: UUID?

    let onAddAccessory: (HMAccessory, NormalizedPoint?) -> Void
    let onStartAssistedPlacement: (UUID) -> Void
    let onHelpDismiss: () -> Void
    let onHelpClose: () -> Void
    let onDrawingDismiss: () -> Void
    let drawingEditor: (Floorplan) -> AnyView
    let onDeleteMarker: (UUID) -> Void

    private var pendingDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeleteMarkerID != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeleteMarkerID = nil
                }
            }
        )
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingPicker, onDismiss: resetAccessoryPicker) {
                accessoryPickerSheet
            }
            .sheet(item: $controllingAccessory) { accessory in
                AccessoryDetailView(accessory: accessory)
            }
            .sheet(isPresented: iconPickerIsPresented) {
                iconPickerSheet
            }
            .sheet(isPresented: $showFloorplanDiagnostics) {
                FloorplanDiagnosticsView(
                    report: FloorplanHealthAnalyzer.analyze(floorplan: floorplan, homeKit: homeKit),
                    onAddAccessories: onStartAssistedPlacement
                )
            }
            .sheet(isPresented: $showFloorplanHelp, onDismiss: onHelpDismiss) {
                FloorplanHelpSheet(onDone: onHelpClose)
            }
            .fullScreenCover(item: $drawingEditFloorplan, onDismiss: onDrawingDismiss) { editingFloorplan in
                drawingEditor(editingFloorplan)
                    .environment(homeKit)
                    .ignoresSafeArea()
            }
            .alert(
                String(localized: "floorplan.marker.delete.title", defaultValue: "Remove accessory from floorplan?"),
                isPresented: pendingDeleteIsPresented
            ) {
                Button(String(localized: "common.delete", defaultValue: "Delete"), role: .destructive) {
                    if let markerID = pendingDeleteMarkerID {
                        onDeleteMarker(markerID)
                    }
                }
                Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "floorplan.marker.delete.message", defaultValue: "The accessory will be removed from the floorplan but will remain active in HomeKit."))
            }
    }

    private var iconPickerIsPresented: Binding<Bool> {
        Binding(
            get: { iconPickerTargetID != nil },
            set: { isPresented in
                if !isPresented {
                    iconPickerTargetID = nil
                }
            }
        )
    }

    private var accessoryPickerSheet: some View {
        let pickerContext = accessoryPickerContext
        return AccessoryPickerSheet(
            alreadyPlaced: pickerContext.alreadyPlaced,
            preferredRoomUUIDs: pickerContext.preferredRoomUUIDs,
            preferredRoomNames: pickerContext.preferredRoomNames,
            title: accessoryPickerTitle,
            onPick: { accessories in
                for accessory in accessories {
                    onAddAccessory(accessory, pendingMarkerPosition)
                }
            }
        )
    }

    @ViewBuilder
    private var iconPickerSheet: some View {
        if let markerID = iconPickerTargetID,
           let placed = floorplan.accessories.first(where: { $0.id == markerID }),
           let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID) {
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            IconPickerSheet(
                accessory: accessory,
                defaultIconName: adapter.iconName,
                onIconChanged: {
                    floorplan.updatedAt = .now
                    try? modelContext.save()
                    cloudKitSync.markFloorplanNeedsSync(floorplan.id)
                }
            )
            .presentationDetents([.large])
        }
    }

    private var accessoryPickerContext: AccessoryPickerContext {
        let preferredRoomUUIDs: Set<UUID>
        let preferredRoomNames: Set<String>

        if let pickerRoomFilter,
           let room = floorplan.linkedRooms.first(where: { $0.hmRoomUUID == pickerRoomFilter }) {
            preferredRoomUUIDs = Set([pickerRoomFilter])
            preferredRoomNames = Set([normalizedRoomName(room.name)])
        } else {
            preferredRoomUUIDs = []
            preferredRoomNames = []
        }

        let alreadyPlaced = Set(floorplan.accessories.map(\.homeKitAccessoryUUID))

        return AccessoryPickerContext(
            alreadyPlaced: alreadyPlaced,
            preferredRoomUUIDs: preferredRoomUUIDs,
            preferredRoomNames: preferredRoomNames
        )
    }

    private func resetAccessoryPicker() {
        pickerRoomFilter = nil
        pendingMarkerPosition = nil
        editHighlightedRoomID = nil
    }

    private func normalizedRoomName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct AccessoryPickerContext {
    let alreadyPlaced: Set<UUID>
    let preferredRoomUUIDs: Set<UUID>
    let preferredRoomNames: Set<String>
}
