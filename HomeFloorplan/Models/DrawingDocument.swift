import Foundation
import CoreGraphics

// MARK: - WallKind

enum WallKind: String, Codable, Equatable {
    case exterior   // thick perimeter wall
    case interior   // thin partition wall
    case balcony    // thin dashed wall for balconies/terraces
}

// MARK: - WallSegment

struct WallSegment: Identifiable, Equatable, Codable {
    let id: UUID
    var start: CGPoint
    var end: CGPoint
    var kind: WallKind

    init(id: UUID = UUID(), start: CGPoint, end: CGPoint, kind: WallKind = .exterior) {
        self.id = id
        self.start = start
        self.end = end
        self.kind = kind
    }

    var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }

    /// Project a canvas point onto this segment.
    /// Returns the parameter t ∈ [0,1], the closest point on the segment, and the distance.
    func project(_ point: CGPoint) -> (t: CGFloat, closest: CGPoint, distance: CGFloat) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 1e-9 else {
            let dist = hypot(point.x - start.x, point.y - start.y)
            return (t: 0, closest: start, distance: dist)
        }
        let t = ((point.x - start.x) * dx + (point.y - start.y) * dy) / lenSq
        let clamped = max(0, min(1, t))
        let closest = CGPoint(x: start.x + clamped * dx, y: start.y + clamped * dy)
        let dist = hypot(point.x - closest.x, point.y - closest.y)
        return (t: clamped, closest: closest, distance: dist)
    }
}

// MARK: - PlacedOpening

enum OpeningKind: String, Codable, Equatable { case door, window }

struct PlacedOpening: Identifiable, Equatable, Codable {
    let id: UUID
    var wallID: UUID
    var t: CGFloat        // normalized position [0,1] along the wall
    var kind: OpeningKind
    var width: CGFloat    // canvas points
    /// Doors only: when true the swing arc is drawn on the opposite wall side.
    var flipSide: Bool

    init(id: UUID = UUID(),
         wallID: UUID,
         t: CGFloat,
         kind: OpeningKind,
         width: CGFloat,
         flipSide: Bool = false) {
        self.id = id
        self.wallID = wallID
        self.t = t
        self.kind = kind
        self.width = width
        self.flipSide = flipSide
    }
}

// MARK: - RoomLabel

/// Cycling palette used for room label badges.
/// Colors are chosen to be distinct and readable on a white canvas.
enum RoomLabelPalette {
    static let colors: [CGColor] = [
        CGColor(red: 0.22, green: 0.52, blue: 0.96, alpha: 1),  // blue
        CGColor(red: 0.20, green: 0.72, blue: 0.50, alpha: 1),  // teal
        CGColor(red: 0.95, green: 0.45, blue: 0.20, alpha: 1),  // orange
        CGColor(red: 0.60, green: 0.30, blue: 0.90, alpha: 1),  // purple
        CGColor(red: 0.88, green: 0.22, blue: 0.40, alpha: 1),  // rose
        CGColor(red: 0.18, green: 0.65, blue: 0.82, alpha: 1),  // cyan
        CGColor(red: 0.85, green: 0.65, blue: 0.10, alpha: 1),  // amber
        CGColor(red: 0.35, green: 0.60, blue: 0.25, alpha: 1),  // green
    ]

    static func color(at index: Int) -> CGColor {
        colors[index % colors.count]
    }
}

struct RoomLabel: Identifiable, Equatable, Codable {
    let id: UUID
    /// UUID of the associated HMRoom (nil if not linked to HomeKit).
    var hmRoomUUID: UUID?
    /// Display name shown on the canvas (typically the HMRoom.name).
    var name: String
    /// Centre position in canvas coordinates.
    var position: CGPoint
    /// Index into `RoomLabelPalette.colors`, assigned sequentially on creation.
    var colorIndex: Int

    init(id: UUID = UUID(), hmRoomUUID: UUID? = nil, name: String, position: CGPoint, colorIndex: Int = 0) {
        self.id = id
        self.hmRoomUUID = hmRoomUUID
        self.name = name
        self.position = position
        self.colorIndex = colorIndex
    }
}

// MARK: - RoomArea

/// A colored rectangular area on the canvas linked to a HomeKit room.
/// Drawn behind walls to visually identify room zones.
struct RoomArea: Identifiable, Equatable, Codable {
    let id: UUID
    /// UUID of the associated HMRoom (nil if not linked to HomeKit).
    var hmRoomUUID: UUID?
    /// Display name shown on the canvas (typically the HMRoom.name).
    var name: String
    /// Rectangle in canvas coordinates.
    var rect: CGRect
    /// Index into `RoomLabelPalette.colors`, assigned sequentially on creation.
    var colorIndex: Int

    init(id: UUID = UUID(), hmRoomUUID: UUID? = nil, name: String,
         rect: CGRect, colorIndex: Int = 0) {
        self.id = id
        self.hmRoomUUID = hmRoomUUID
        self.name = name
        self.rect = rect
        self.colorIndex = colorIndex
    }
}

// MARK: - FurnitureItem

/// A named, resizable rectangular furniture element on the canvas.
/// Purely decorative — no HomeKit room linking.
struct FurnitureItem: Identifiable, Equatable, Codable {
    let id: UUID
    /// User-editable display name (e.g. "Divano", "Tavolo", "Letto").
    var name: String
    /// Rectangle in canvas coordinates.
    var rect: CGRect

    init(id: UUID = UUID(), name: String = "Mobile", rect: CGRect) {
        self.id = id
        self.name = name
        self.rect = rect
    }
}

// MARK: - SnapResult

/// Indicates whether a point was snapped to an existing wall vertex or to the grid.
enum SnapResult: Equatable {
    case vertex(CGPoint)
    case grid(CGPoint)

    var point: CGPoint {
        switch self {
        case .vertex(let p): return p
        case .grid(let p):   return p
        }
    }

    var isVertex: Bool {
        if case .vertex = self { return true }
        return false
    }
}

// MARK: - Selection / Mode

enum DrawingSelection: Equatable {
    case wall(UUID)
    case opening(UUID)
    case roomLabel(UUID)
    case roomArea(UUID)
    case furniture(UUID)
    case none
}

enum DrawingMode: Equatable {
    case draw
    case select
    /// Waiting for the user to tap a wall to place an opening of the given kind.
    case placeOpening(OpeningKind)
    /// Waiting for the user to tap the canvas to place a room label.
    case placeRoomLabel
    /// Waiting for the user to drag on the canvas to draw a room area rectangle.
    case drawRoomArea
    /// Waiting for the user to tap the canvas to place a furniture item.
    case placeFurniture
}

// MARK: - DrawingDocument

struct DrawingDocument: Equatable, Codable {
    var walls: [WallSegment]          = []
    var openings: [PlacedOpening]     = []
    var roomLabels: [RoomLabel]       = []
    var roomAreas: [RoomArea]         = []
    var furnitureItems: [FurnitureItem] = []

    static let canvasSize: CGFloat  = 2000
    static let gridSpacing: CGFloat = 20

    /// Stroke width in canvas points for each wall kind.
    static func wallWidth(for kind: WallKind) -> CGFloat {
        switch kind {
        case .exterior: return 16
        case .interior: return 8
        case .balcony:  return 16   // same outer width as exterior; inner white stroke creates double-line look
        }
    }

    func wall(for id: UUID) -> WallSegment?           { walls.first         { $0.id == id } }
    func opening(for id: UUID) -> PlacedOpening?      { openings.first      { $0.id == id } }
    func roomLabel(for id: UUID) -> RoomLabel?        { roomLabels.first    { $0.id == id } }
    func roomArea(for id: UUID) -> RoomArea?          { roomAreas.first     { $0.id == id } }
    func furnitureItem(for id: UUID) -> FurnitureItem? { furnitureItems.first { $0.id == id } }

    // MARK: Grid snapping

    static func snap(_ point: CGPoint) -> CGPoint {
        let g = gridSpacing
        return CGPoint(
            x: round(point.x / g) * g,
            y: round(point.y / g) * g
        )
    }

    /// Fine-grained snap for resize operations: 5pt grid for more precise control.
    static func fineSnap(_ point: CGPoint) -> CGPoint {
        let g: CGFloat = 5
        return CGPoint(
            x: round(point.x / g) * g,
            y: round(point.y / g) * g
        )
    }

    // MARK: Vertex snapping

    /// Returns the closest existing wall endpoint within `maxDistance` canvas points, or nil.
    func nearestEndpoint(to point: CGPoint, maxDistance: CGFloat = 30) -> CGPoint? {
        var bestPoint: CGPoint?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for wall in walls {
            for ep in [wall.start, wall.end] {
                let d = hypot(ep.x - point.x, ep.y - point.y)
                if d < bestDist {
                    bestDist = d
                    bestPoint = ep
                }
            }
        }
        guard bestDist <= maxDistance, let pt = bestPoint else { return nil }
        return pt
    }

    /// Smart snap: vertex snapping (30pt radius) takes priority over grid snap.
    func smartSnap(_ point: CGPoint) -> SnapResult {
        if let vertex = nearestEndpoint(to: point, maxDistance: 30) {
            return .vertex(vertex)
        }
        return .grid(Self.snap(point))
    }

    // MARK: Nearest wall for opening drop

    func nearestWall(to point: CGPoint, maxDistance: CGFloat = 40) -> (wallID: UUID, t: CGFloat)? {
        var best: (wallID: UUID, t: CGFloat, dist: CGFloat)?
        for wall in walls {
            let proj = wall.project(point)
            guard proj.t > 0, proj.t < 1 else { continue }
            if best == nil || proj.distance < best!.dist {
                best = (wall.id, proj.t, proj.distance)
            }
        }
        guard let b = best, b.dist <= maxDistance else { return nil }
        return (b.wallID, b.t)
    }

    // MARK: Delete

    mutating func delete(_ selection: DrawingSelection) {
        switch selection {
        case .wall(let id):
            walls.removeAll { $0.id == id }
            openings.removeAll { $0.wallID == id }
        case .opening(let id):
            openings.removeAll { $0.id == id }
        case .roomLabel(let id):
            roomLabels.removeAll { $0.id == id }
        case .roomArea(let id):
            roomAreas.removeAll { $0.id == id }
        case .furniture(let id):
            furnitureItems.removeAll { $0.id == id }
        case .none: break
        }
    }

    // MARK: Opening geometry helpers

    /// Returns the (start, end) endpoints of a placed opening in canvas coordinates.
    func openingEndpoints(_ opening: PlacedOpening) -> (start: CGPoint, end: CGPoint)? {
        guard let wall = wall(for: opening.wallID) else { return nil }
        let dx = wall.end.x - wall.start.x
        let dy = wall.end.y - wall.start.y
        let len = hypot(dx, dy)
        guard len > 0 else { return nil }
        let ux = dx / len, uy = dy / len
        let mid = CGPoint(x: wall.start.x + opening.t * dx,
                          y: wall.start.y + opening.t * dy)
        let half = opening.width / 2
        return (
            start: CGPoint(x: mid.x - ux * half, y: mid.y - uy * half),
            end:   CGPoint(x: mid.x + ux * half, y: mid.y + uy * half)
        )
    }
}
