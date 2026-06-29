import Foundation
import CoreGraphics

struct FloorplanAIDraft: Codable, Equatable {
    var walls: [FloorplanAIDraftWall]
    var rooms: [FloorplanAIDraftRoom]
    var labels: [FloorplanAIDraftLabel]

    init(walls: [FloorplanAIDraftWall] = [],
         rooms: [FloorplanAIDraftRoom] = [],
         labels: [FloorplanAIDraftLabel] = []) {
        self.walls = walls
        self.rooms = rooms
        self.labels = labels
    }
}

struct FloorplanAIDraftWall: Codable, Equatable {
    var x1: CGFloat
    var y1: CGFloat
    var x2: CGFloat
    var y2: CGFloat
    var kind: String?
    var confidence: CGFloat?
}

struct FloorplanAIDraftRoom: Codable, Equatable {
    var name: String?
    var points: [FloorplanAIDraftPoint]
}

struct FloorplanAIDraftLabel: Codable, Equatable {
    var name: String
    var x: CGFloat
    var y: CGFloat
}

struct FloorplanAIDraftPoint: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
}

enum FloorplanAIDraftMapper {
    static func makeDocument(from draft: FloorplanAIDraft) -> DrawingDocument {
        var document = DrawingDocument()

        var walls: [WallSegment] = []
        for wall in draft.walls.prefix(160) {
            if let mappedWall = makeWall(wall) {
                walls.append(mappedWall)
            }
        }
        document.walls = walls

        // MVP policy: keep the AI draft wall-only. Room areas and labels are intentionally
        // left for the user after correcting the imported geometry.
        document.roomAreas = []
        document.roomLabels = []
        return document
    }

    private static func makeWall(_ wall: FloorplanAIDraftWall) -> WallSegment? {
        guard (wall.confidence ?? 0) >= 0.78 else { return nil }

        let start = DrawingDocument.snap(clamp(CGPoint(x: wall.x1, y: wall.y1)))
        let end = DrawingDocument.snap(clamp(CGPoint(x: wall.x2, y: wall.y2)))
        guard hypot(end.x - start.x, end.y - start.y) >= 35 else { return nil }

        let kind: WallKind
        switch wall.kind?.lowercased() {
        case "interior":
            kind = .interior
        case "balcony":
            kind = .balcony
        default:
            kind = .exterior
        }

        return WallSegment(start: start, end: end, kind: kind)
    }

    private static func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), DrawingDocument.canvasSize),
            y: min(max(point.y, 0), DrawingDocument.canvasSize)
        )
    }

}
