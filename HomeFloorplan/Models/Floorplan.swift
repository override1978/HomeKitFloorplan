import Foundation
import SwiftData

// MARK: - LinkedRoom / CodableRect / CodablePoint

/// Codable substitute for CGPoint (which is not Codable by default).
struct CodablePoint: Codable {
    var x: Double
    var y: Double
}

/// A HomeKit room linked to a normalized area on a floorplan image.
/// Stored as JSON in `Floorplan.linkedRoomsJSON`.
struct LinkedRoom: Codable {
    var hmRoomUUID: UUID
    var name: String
    /// Bounding rectangle with coordinates normalized to [0, 1] relative to the exported PNG.
    /// Always present for backward compatibility.
    var normalizedRect: CodableRect
    /// Optional polygon vertices normalized to [0, 1].
    /// Non-nil only when the originating `RoomArea` has `points` (polygon mode).
    var normalizedPoints: [CodablePoint]?
}

/// Codable substitute for CGRect (which is not Codable by default).
struct CodableRect: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

enum FloorplanTapMode: String, Codable, CaseIterable {
    case openPanel       // tap → apre il pannello di controllo
    case quickToggle     // tap → toggle immediato (se possibile), long press → pannello
    
    var localized: String {
        switch self {
        case .openPanel: return "Pannello"
        case .quickToggle: return "Toggle rapido"
        }
    }
    
    var systemImage: String {
        switch self {
        case .openPanel: return "rectangle.stack"
        case .quickToggle: return "bolt.fill"
        }
    }
}

enum DrawingExportRotation: String, Codable, CaseIterable, Identifiable {
    case asDrawn
    case clockwise
    case counterClockwise
    case upsideDown

    var id: String { rawValue }

    var quarterTurns: Int {
        switch self {
        case .asDrawn: return 0
        case .clockwise: return 1
        case .upsideDown: return 2
        case .counterClockwise: return 3
        }
    }
}

@Model
final class Floorplan {
    @Attribute(.unique) var id: UUID
    var name: String
    var imageFilename: String
    var createdAt: Date
    var updatedAt: Date
    /// Modalità di interazione sui marker. Default: aprire il pannello.
    /// rawValue salvato come String (Codable enum funziona out-of-the-box con SwiftData).
    var tapModeRaw: String = FloorplanTapMode.openPanel.rawValue
    
    @Relationship(deleteRule: .cascade, inverse: \PlacedAccessory.floorplan)
    var accessories: [PlacedAccessory] = []
    var homeUUID: UUID?
    /// JSON-encoded array of `LinkedRoom` — rooms with normalized rects on this floorplan.
    var linkedRoomsJSON: Data?
    /// JSON-encoded `DrawingDocument` — the 2D drawing associated with this floorplan, if any.
    var drawingDocumentJSON: Data?
    /// Index into ExteriorFillPalette (-1 = disabled, 0-4 = color preset).
    var exteriorFillColorIndex: Int = -1
    /// Raw value of the visual export style used for drawing-based floorplans.
    var drawingVisualExportStyleRaw: String = "standard"
    /// Raw value of the export-only rotation used for drawing-based floorplans.
    var drawingExportRotationRaw: String = DrawingExportRotation.asDrawn.rawValue

    init(name: String, imageFilename: String, homeUUID: UUID? = nil) {
        self.id = UUID()
        self.name = name
        self.imageFilename = imageFilename
        self.createdAt = .now
        self.updatedAt = .now
        self.homeUUID = homeUUID
    }

    var tapMode: FloorplanTapMode {
        get { FloorplanTapMode(rawValue: tapModeRaw) ?? .openPanel }
        set { tapModeRaw = newValue.rawValue }
    }

    var drawingExportRotation: DrawingExportRotation {
        get { DrawingExportRotation(rawValue: drawingExportRotationRaw) ?? .asDrawn }
        set { drawingExportRotationRaw = newValue.rawValue }
    }

    /// Decoded list of rooms linked to this floorplan (from `linkedRoomsJSON`).
    var linkedRooms: [LinkedRoom] {
        get {
            guard let data = linkedRoomsJSON,
                  let rooms = try? JSONDecoder().decode([LinkedRoom].self, from: data)
            else { return [] }
            return rooms
        }
        set {
            linkedRoomsJSON = try? JSONEncoder().encode(newValue)
        }
    }

    /// Decoded drawing document (from `drawingDocumentJSON`), or nil if no drawing exists.
    var drawingDocument: DrawingDocument? {
        get {
            guard let data = drawingDocumentJSON else { return nil }
            return try? JSONDecoder().decode(DrawingDocument.self, from: data)
        }
        set {
            drawingDocumentJSON = try? JSONEncoder().encode(newValue)
        }
    }
}
