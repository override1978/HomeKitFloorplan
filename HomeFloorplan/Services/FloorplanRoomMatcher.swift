import Foundation

enum FloorplanRoomMatcher {
    static func normalizedName(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(roomName: String?, linkedRoom: LinkedRoom) -> Bool {
        normalizedName(roomName) == normalizedName(linkedRoom.name)
    }

    static func matches(roomName: String?, highlightedRoomName: String?) -> Bool {
        normalizedName(roomName) == normalizedName(highlightedRoomName)
    }

    static func linkedRoomID(containing point: NormalizedPoint, in rooms: [LinkedRoom]) -> UUID? {
        rooms.first { contains(point, in: $0) }?.hmRoomUUID
    }

    static func isNearAnyRoom(_ point: NormalizedPoint,
                              in rooms: [LinkedRoom],
                              tolerance: Double) -> Bool {
        rooms.contains { isNear(point, to: $0, tolerance: tolerance) }
    }

    static func isNear(_ point: NormalizedPoint,
                       to room: LinkedRoom,
                       tolerance: Double) -> Bool {
        if contains(point, in: room) {
            return true
        }

        if let polygon = room.normalizedPoints, polygon.count >= 3 {
            return distance(from: point, to: polygon) <= tolerance
        }

        return distance(from: point, to: room.normalizedRect) <= tolerance
    }

    static func contains(_ point: NormalizedPoint, in room: LinkedRoom) -> Bool {
        if let polygon = room.normalizedPoints, polygon.count >= 3 {
            return contains(point: point, polygon: polygon)
        }

        let rect = room.normalizedRect
        return point.x >= rect.x &&
            point.x <= rect.x + rect.width &&
            point.y >= rect.y &&
            point.y <= rect.y + rect.height
    }

    private static func contains(point: NormalizedPoint, polygon: [CodablePoint]) -> Bool {
        var isInside = false
        var j = polygon.count - 1

        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            let crossesY = (pi.y > point.y) != (pj.y > point.y)
            if crossesY {
                let denominator = pj.y - pi.y
                if abs(denominator) > .ulpOfOne {
                    let xIntersection = (pj.x - pi.x) * (point.y - pi.y) / denominator + pi.x
                    if point.x < xIntersection {
                        isInside.toggle()
                    }
                }
            }
            j = i
        }

        return isInside
    }

    private static func distance(from point: NormalizedPoint, to rect: CodableRect) -> Double {
        let minX = rect.x
        let maxX = rect.x + rect.width
        let minY = rect.y
        let maxY = rect.y + rect.height
        let dx = max(max(minX - point.x, 0), point.x - maxX)
        let dy = max(max(minY - point.y, 0), point.y - maxY)
        return hypot(dx, dy)
    }

    private static func distance(from point: NormalizedPoint, to polygon: [CodablePoint]) -> Double {
        guard polygon.count >= 2 else { return .greatestFiniteMagnitude }

        var shortestDistance = Double.greatestFiniteMagnitude
        var previous = polygon[polygon.count - 1]

        for current in polygon {
            shortestDistance = min(
                shortestDistance,
                distance(from: point, toSegmentFrom: previous, to: current)
            )
            previous = current
        }

        return shortestDistance
    }

    private static func distance(from point: NormalizedPoint,
                                 toSegmentFrom start: CodablePoint,
                                 to end: CodablePoint) -> Double {
        let vx = end.x - start.x
        let vy = end.y - start.y
        let wx = point.x - start.x
        let wy = point.y - start.y
        let lengthSquared = vx * vx + vy * vy

        guard lengthSquared > .ulpOfOne else {
            return hypot(point.x - start.x, point.y - start.y)
        }

        let projection = max(0, min(1, (wx * vx + wy * vy) / lengthSquared))
        let closestX = start.x + projection * vx
        let closestY = start.y + projection * vy

        return hypot(point.x - closestX, point.y - closestY)
    }
}
