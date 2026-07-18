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

        // PNG lossless: l'export del disegno è a tinte piatte, quindi comprime
        // bene e — a differenza del JPEG — preserva esattamente i colori baked,
        // che devono coincidere con lo sfondo live dell'editor (niente cucitura).
        if let newData = update.image.pngData() {
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
