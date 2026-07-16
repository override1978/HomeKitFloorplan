import SwiftData
import SwiftUI

struct FloorplanDrawingUpdate {
    let image: UIImage
    let rooms: [LinkedRoom]
    let document: DrawingDocument
    let exteriorFillColorIndex: Int
    let visualStyle: DrawingVisualExportStyle
    let exportRotation: DrawingExportRotation
}

struct FloorplanDrawingUpdateCoordinator {
    let floorplan: Floorplan
    let modelContext: ModelContext
    let cloudKitSync: CloudKitSyncService
    let markerEditingCoordinator: FloorplanMarkerEditingCoordinator

    func apply(_ update: FloorplanDrawingUpdate) {
        let previousRooms = floorplan.linkedRooms
        let previousRotation = floorplan.drawingExportRotation

        if let newData = update.image.jpegData(compressionQuality: 0.85) {
            floorplan.imageData = newData
        }
        floorplan.drawingDocument = update.document
        floorplan.exteriorFillColorIndex = update.exteriorFillColorIndex
        floorplan.drawingVisualExportStyleRaw = update.visualStyle.rawValue
        floorplan.drawingExportRotation = update.exportRotation

        if !update.rooms.isEmpty {
            markerEditingCoordinator.preserveMarkerPositions(
                from: previousRooms,
                to: update.rooms,
                previousRotation: previousRotation,
                newRotation: update.exportRotation
            )
            floorplan.linkedRooms = update.rooms
        }

        floorplan.updatedAt = .now
        try? modelContext.save()
        cloudKitSync.markFloorplanNeedsSync(floorplan.id)
    }
}
