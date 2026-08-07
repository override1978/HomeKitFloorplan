import Foundation
import CoreGraphics
import simd

// MARK: - FloorplanRoomEnvironment

/// **Dove** piantare la bandierina di una stanza. Solo geometria.
///
/// Il *cosa* mostrarci — punteggio, giudizio, urgenza, elenco dei filtri
/// disponibili — viene da `EnvironmentViewModel`, che è già l'autorità per la
/// vista 2D. Qui non si ricalcola niente di tutto quello: una seconda
/// implementazione delle soglie sarebbe destinata a divergere dalla prima, e a
/// far dire due cose diverse alla stessa casa.
enum FloorplanRoomEnvironment {

    struct Anchor {
        var roomID: UUID
        var roomName: String
        /// Punto in cui piantare lo stelo, in metri.
        var point: SIMD2<Double>
    }

    static func anchors(in document: DrawingDocument) -> [Anchor] {
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        return document.roomAreas.compactMap { area in
            let polygon = area.effectivePoints.map {
                SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
            }
            guard let point = anchor(in: polygon) else { return nil }
            return Anchor(roomID: area.id, roomName: area.name, point: point)
        }
    }

    /// Il punto **più interno** del poligono, non il baricentro.
    ///
    /// Il baricentro di una stanza a L cade fuori dalla stanza, e lì la
    /// bandierina spunterebbe da un muro. Si campiona una griglia e si tiene il
    /// punto più lontano da ogni bordo: è il posto dove una persona direbbe
    /// «in mezzo».
    static func anchor(in polygon: [SIMD2<Double>]) -> SIMD2<Double>? {
        guard polygon.count >= 3 else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        guard maxX > minX, maxY > minY else { return nil }

        let steps = 24
        var best: (point: SIMD2<Double>, clearance: Double)?

        for column in 0...steps {
            for row in 0...steps {
                let point = SIMD2(minX + (maxX - minX) * Double(column) / Double(steps),
                                  minY + (maxY - minY) * Double(row) / Double(steps))
                guard contains(point, polygon) else { continue }
                let clearance = distanceToBoundary(point, polygon)
                if clearance > (best?.clearance ?? -1) { best = (point, clearance) }
            }
        }
        return best?.point
    }

    private static func distanceToBoundary(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Double {
        var nearest = Double.greatestFiniteMagnitude
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let edge = b - a
            let lengthSquared = simd_length_squared(edge)
            let projection = lengthSquared > 0
                ? max(0, min(1, simd_dot(point - a, edge) / lengthSquared))
                : 0
            nearest = min(nearest, simd_distance(point, a + edge * projection))
        }
        return nearest
    }

    static func contains(_ point: SIMD2<Double>, _ polygon: [SIMD2<Double>]) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }
}
