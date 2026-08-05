import Foundation
import CoreGraphics
import simd

// MARK: - FloorplanExtruder

/// Trasforma un `DrawingDocument` in facce nello spazio.
///
/// **Puro e senza rendering**: entra il documento, escono quadrilateri con le
/// loro coordinate in metri. È la parte che serve identica sia a una proiezione
/// disegnata su `Canvas` sia a un motore 3D vero — quindi scriverla adesso non è
/// lavoro speso per una strada sola.
///
/// L'unica cosa che il piano non può contenere sono le **altezze**: un disegno
/// in pianta non sa quanto è alto un soffitto. Sono parametri, ed è lo stesso
/// motivo per cui un'app concorrente chiede l'altezza del soffitto prima di
/// generare il modello.
enum FloorplanExtruder {

    struct Heights {
        var ceiling: Double = 2.4
        /// Architrave delle porte: sopra resta muro.
        var doorTop: Double = 2.1
        /// Finestre: davanzale e architrave.
        var windowBottom: Double = 0.9
        var windowTop: Double = 2.2
    }

    /// Un quadrilatero in metri. Le facce sono piane per costruzione, quindi
    /// quattro punti bastano e non serve una mesh.
    struct Face {
        enum Kind {
            case floor
            /// Faccia verticale di un muro.
            case wallSide
            /// Faccia superiore: prende più luce, ed è ciò che dà il volume.
            case wallTop
        }
        var points: [SIMD3<Double>]
        var kind: Kind
        /// Indice nella palette delle stanze, solo per i pavimenti.
        var roomColorIndex: Int?

        var centroid: SIMD3<Double> {
            points.reduce(.zero, +) / Double(points.count)
        }
    }

    // MARK: - Ingresso

    static func faces(from document: DrawingDocument, heights: Heights = Heights()) -> [Face] {
        var result: [Face] = []
        for area in document.roomAreas {
            result.append(contentsOf: floorFaces(area))
        }
        for wall in document.walls {
            result.append(contentsOf: wallFaces(wall, in: document, heights: heights))
        }
        return result
    }

    // MARK: - Pavimenti

    private static func floorFaces(_ area: RoomArea) -> [Face] {
        let outline: [CGPoint] = {
            if let points = area.points, points.count >= 3 { return points }
            return [CGPoint(x: area.rect.minX, y: area.rect.minY),
                    CGPoint(x: area.rect.maxX, y: area.rect.minY),
                    CGPoint(x: area.rect.maxX, y: area.rect.maxY),
                    CGPoint(x: area.rect.minX, y: area.rect.maxY)]
        }()
        // Un poligono qualsiasi resta una faccia sola: il disegno lo riempie
        // come cammino chiuso, senza bisogno di triangolarlo.
        return [Face(points: outline.map { SIMD3(metres($0.x), metres($0.y), 0) },
                     kind: .floor,
                     roomColorIndex: area.colorIndex)]
    }

    // MARK: - Muri

    /// Un muro diventa una scatola per ogni tratto **pieno**.
    ///
    /// I vani non si bucano: si evitano. Si lavora in una dimensione lungo il
    /// muro, si tolgono gli intervalli occupati dalle aperture, e di ogni tratto
    /// rimasto si costruisce un solido. Sopra una porta e sotto una finestra il
    /// muro c'è, quindi quei pezzi tornano come tratti a quota diversa.
    private static func wallFaces(_ wall: WallSegment,
                                  in document: DrawingDocument,
                                  heights: Heights) -> [Face] {
        let start = SIMD2(metres(wall.start.x), metres(wall.start.y))
        let end   = SIMD2(metres(wall.end.x), metres(wall.end.y))
        let length = simd_distance(start, end)
        guard length > 0.01 else { return [] }

        let thickness = metres(DrawingDocument.wallWidth(for: wall.kind))
        let openings = document.openings
            .filter { $0.wallID == wall.id }
            .sorted { $0.t < $1.t }

        // Tratti pieni: (da, a) lungo il muro, con la loro fascia verticale.
        var spans: [(from: Double, to: Double, bottom: Double, top: Double)] = []
        var cursor = 0.0
        for opening in openings {
            let width = metres(opening.width)
            let centre = Double(opening.t) * length
            let from = max(0, centre - width / 2)
            let to   = min(length, centre + width / 2)
            guard to > from else { continue }

            if from > cursor {
                spans.append((cursor, from, 0, heights.ceiling))
            }
            switch opening.kind {
            case .window:
                spans.append((from, to, 0, heights.windowBottom))
                spans.append((from, to, heights.windowTop, heights.ceiling))
            case .door, .slidingDoor, .frenchDoor:
                spans.append((from, to, heights.doorTop, heights.ceiling))
            }
            cursor = to
        }
        if cursor < length {
            spans.append((cursor, length, 0, heights.ceiling))
        }

        let direction = simd_normalize(end - start)
        let normal = SIMD2(-direction.y, direction.x) * (thickness / 2)

        return spans.flatMap { span -> [Face] in
            guard span.to > span.from, span.top > span.bottom else { return [] }
            let a = start + direction * span.from
            let b = start + direction * span.to
            return box(from: a, to: b, normal: normal, bottom: span.bottom, top: span.top)
        }
    }

    /// Le facce di un tratto di muro. Solo quelle **visibili** da un punto di
    /// vista alto: le due fiancate, la sommità e i due tappi. Il sotto non si
    /// vede mai e disegnarlo raddoppierebbe i poligoni per niente.
    private static func box(from a: SIMD2<Double>,
                            to b: SIMD2<Double>,
                            normal: SIMD2<Double>,
                            bottom: Double,
                            top: Double) -> [Face] {
        let corners = [a + normal, b + normal, b - normal, a - normal]
        func face(_ indices: [Int], kind: Face.Kind, low: Double, high: Double) -> Face {
            let points = indices.enumerated().map { index, corner -> SIMD3<Double> in
                let z = index < 2 ? low : high
                return SIMD3(corners[corner].x, corners[corner].y, z)
            }
            return Face(points: points, kind: kind, roomColorIndex: nil)
        }
        return [
            Face(points: corners.map { SIMD3($0.x, $0.y, top) }, kind: .wallTop, roomColorIndex: nil),
            face([0, 1, 1, 0], kind: .wallSide, low: bottom, high: top),
            face([2, 3, 3, 2], kind: .wallSide, low: bottom, high: top),
            face([1, 2, 2, 1], kind: .wallSide, low: bottom, high: top),
            face([3, 0, 0, 3], kind: .wallSide, low: bottom, high: top)
        ]
    }

    private static func metres(_ points: CGFloat) -> Double {
        Double(points) / Double(DrawingDocument.ptsPerMeter)
    }
}
