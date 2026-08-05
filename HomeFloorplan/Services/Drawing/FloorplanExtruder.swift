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
        /// Il perimetro di un balcone è un **parapetto**, non un muro: si
        /// affaccia, non chiude. Estruderlo fino al soffitto trasformava una
        /// stanza aperta in uno stanzino cieco.
        var parapet: Double = 1.05

        func top(for kind: WallKind) -> Double {
            kind == .balcony ? parapet : ceiling
        }
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
            /// Il vetro di una finestra. Senza, una finestra e una porta sono
            /// lo stesso buco e non si distinguono.
            case glass
            /// Il telaio che contorna un'apertura. Senza, un vano è un buco
            /// come un altro: è la cornice a dire che lì c'è una porta.
            case frame
            /// Il battente di una porta, pieno. Il vetro può permettersi di
            /// essere trasparente perché dà sull'esterno; una porta dà sulla
            /// stanza accanto, e trasparente ne prenderebbe il colore.
            case doorLeaf
            /// Parapetto di un balcone: basso **e** diverso, altrimenti resta
            /// un muro tagliato a metà.
            case parapetSide
            case parapetTop
        }
        var points: [SIMD3<Double>]
        var kind: Kind
        /// Indice nella palette delle stanze, solo per i pavimenti.
        var roomColorIndex: Int?
        /// Identità della stanza, per poterla selezionare toccando il pavimento.
        var roomID: UUID?
        var roomName: String?

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
        let joints = sharedEndpoints(of: document.walls)
        for wall in document.walls {
            result.append(contentsOf: wallFaces(wall, in: document, heights: heights, joints: joints))
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
                     roomColorIndex: area.colorIndex,
                     roomID: area.id,
                     roomName: area.name)]
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
                                  heights: Heights,
                                  joints: Set<GridKey>) -> [Face] {
        let start = SIMD2(metres(wall.start.x), metres(wall.start.y))
        let end   = SIMD2(metres(wall.end.x), metres(wall.end.y))
        let length = simd_distance(start, end)
        guard length > 0.01 else { return [] }

        let isParapet = wall.kind == .balcony
        // Un parapetto è più sottile di un muro portante: tenerlo allo stesso
        // spessore lo faceva sembrare un muro segato a mezz'altezza.
        let thickness = metres(DrawingDocument.wallWidth(for: wall.kind)) * (isParapet ? 0.5 : 1)
        let wallTop = heights.top(for: wall.kind)
        let axis = simd_normalize(end - start)

        // Angoli **lisci**: un muro che ne incontra un altro sborda di mezzo
        // spessore, così le due scatole si compenetrano e la tacca fra loro
        // sparisce. Senza, ai vertici restano i tappi in vista.
        //
        // ⚠️ Lo sbordo è una **coda**, non un allungamento del muro: le
        // aperture hanno `t` normalizzato sulla lunghezza vera, quindi
        // allungare il muro prima di collocarle le farebbe scivolare tutte
        // verso i bordi. Si calcolano sulla misura originale e si sborda solo
        // il primo e l'ultimo tratto pieno.
        let headOverhang = joints.contains(GridKey(start)) ? thickness / 2 : 0
        let tailOverhang = joints.contains(GridKey(end)) ? thickness / 2 : 0
        let openings = document.openings
            .filter { $0.wallID == wall.id }
            .sorted { $0.t < $1.t }

        // Tratti pieni: (da, a) lungo il muro, con la loro fascia verticale.
        var spans: [(from: Double, to: Double, bottom: Double, top: Double)] = []
        /// I vetri: stessi intervalli, ma una lastra sola invece di un solido.
        var panes: [(from: Double, to: Double, bottom: Double, top: Double)] = []
        /// I vani da contornare, col loro rettangolo nel piano del muro.
        var voids: [(from: Double, to: Double, bottom: Double, top: Double, sill: Bool)] = []
        /// I battenti delle porte.
        var leaves: [(from: Double, to: Double, bottom: Double, top: Double)] = []
        var cursor = 0.0
        for opening in openings {
            let width = metres(opening.width)
            let centre = Double(opening.t) * length
            let from = max(0, centre - width / 2)
            let to   = min(length, centre + width / 2)
            guard to > from else { continue }

            if from > cursor {
                spans.append((cursor, from, 0, wallTop))
            }
            switch opening.kind {
            case .window:
                spans.append((from, to, 0, min(heights.windowBottom, wallTop)))
                spans.append((from, to, heights.windowTop, wallTop))
                panes.append((from, to, heights.windowBottom, min(heights.windowTop, wallTop)))
                voids.append((from, to, heights.windowBottom, min(heights.windowTop, wallTop), true))
            case .door, .slidingDoor, .frenchDoor:
                spans.append((from, to, heights.doorTop, wallTop))
                // Una porta poggia a terra: niente traversa in basso, o
                // diventa un ostacolo che nella realtà non c'è.
                voids.append((from, to, 0, min(heights.doorTop, wallTop), false))
                leaves.append((from, to, 0, min(heights.doorTop, wallTop)))
            }
            cursor = to
        }
        if cursor < length {
            spans.append((cursor, length, 0, wallTop))
        }

        let normal = SIMD2(-axis.y, axis.x) * (thickness / 2)

        var faces = spans.flatMap { span -> [Face] in
            guard span.to > span.from, span.top > span.bottom else { return [] }
            // Lo sbordo tocca solo chi arriva davvero all'estremità del muro.
            let from = span.from <= 0.0001 ? -headOverhang : span.from
            let to   = span.to >= length - 0.0001 ? length + tailOverhang : span.to
            let a = start + axis * from
            let b = start + axis * to
            return box(from: a, to: b, normal: normal,
                       bottom: span.bottom, top: span.top, isParapet: isParapet)
        }

        // Telai: quattro listelli sottili nel piano del muro, a metà spessore
        // così si vedono da entrambi i lati del vano.
        let jamb = 0.06
        for hole in voids where hole.top > hole.bottom + jamb && hole.to > hole.from + jamb * 2 {
            func quad(_ x0: Double, _ x1: Double, _ z0: Double, _ z1: Double) -> Face {
                let a = start + axis * x0, b = start + axis * x1
                return Face(points: [SIMD3(a.x, a.y, z0), SIMD3(b.x, b.y, z0),
                                     SIMD3(b.x, b.y, z1), SIMD3(a.x, a.y, z1)],
                            kind: .frame, roomColorIndex: nil, roomID: nil, roomName: nil)
            }
            faces.append(quad(hole.from, hole.from + jamb, hole.bottom, hole.top))
            faces.append(quad(hole.to - jamb, hole.to, hole.bottom, hole.top))
            faces.append(quad(hole.from, hole.to, hole.top - jamb, hole.top))
            if hole.sill {
                faces.append(quad(hole.from, hole.to, hole.bottom, hole.bottom + jamb))
            }
        }

        // Lastre a metà spessore: non sono solidi, quindi niente fiancate né
        // sommità. Battenti e vetri stanno **dentro** il telaio, non a filo,
        // così la cornice resta visibile tutto intorno.
        func panel(_ span: (from: Double, to: Double, bottom: Double, top: Double),
                   _ kind: Face.Kind) -> Face? {
            let from = span.from + jamb, to = span.to - jamb
            let top = span.top - jamb
            guard to > from, top > span.bottom else { return nil }
            let a = start + axis * from, b = start + axis * to
            return Face(points: [SIMD3(a.x, a.y, span.bottom), SIMD3(b.x, b.y, span.bottom),
                                 SIMD3(b.x, b.y, top), SIMD3(a.x, a.y, top)],
                        kind: kind, roomColorIndex: nil, roomID: nil, roomName: nil)
        }
        faces += panes.compactMap { panel(($0.from, $0.to, $0.bottom + jamb, $0.top), .glass) }
        faces += leaves.compactMap { panel($0, .doorLeaf) }
        return faces
    }

    /// Le facce di un tratto di muro. Solo quelle **visibili** da un punto di
    /// vista alto: le due fiancate, la sommità e i due tappi. Il sotto non si
    /// vede mai e disegnarlo raddoppierebbe i poligoni per niente.
    private static func box(from a: SIMD2<Double>,
                            to b: SIMD2<Double>,
                            normal: SIMD2<Double>,
                            bottom: Double,
                            top: Double,
                            isParapet: Bool = false) -> [Face] {
        let sideKind: Face.Kind = isParapet ? .parapetSide : .wallSide
        let topKind: Face.Kind = isParapet ? .parapetTop : .wallTop
        let corners = [a + normal, b + normal, b - normal, a - normal]
        func face(_ indices: [Int], kind: Face.Kind, low: Double, high: Double) -> Face {
            let points = indices.enumerated().map { index, corner -> SIMD3<Double> in
                let z = index < 2 ? low : high
                return SIMD3(corners[corner].x, corners[corner].y, z)
            }
            return Face(points: points, kind: kind, roomColorIndex: nil, roomID: nil, roomName: nil)
        }
        return [
            Face(points: corners.map { SIMD3($0.x, $0.y, top) }, kind: topKind,
                 roomColorIndex: nil, roomID: nil, roomName: nil),
            face([0, 1, 1, 0], kind: sideKind, low: bottom, high: top),
            face([2, 3, 3, 2], kind: sideKind, low: bottom, high: top),
            face([1, 2, 2, 1], kind: sideKind, low: bottom, high: top),
            face([3, 0, 0, 3], kind: sideKind, low: bottom, high: top)
        ]
    }

    /// Coordinata arrotondata al millimetro: due estremi «uguali» in un disegno
    /// non lo sono mai al bit, e confrontarli per identità non troverebbe
    /// nessuna giunzione.
    struct GridKey: Hashable {
        let x: Int, y: Int
        init(_ point: SIMD2<Double>) {
            x = Int((point.x * 1000).rounded())
            y = Int((point.y * 1000).rounded())
        }
    }

    private static func sharedEndpoints(of walls: [WallSegment]) -> Set<GridKey> {
        var counts: [GridKey: Int] = [:]
        for wall in walls {
            for point in [wall.start, wall.end] {
                counts[GridKey(SIMD2(metres(point.x), metres(point.y))), default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    private static func metres(_ points: CGFloat) -> Double {
        Double(points) / Double(DrawingDocument.ptsPerMeter)
    }
}
