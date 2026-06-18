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
}
