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
            /// Specchiatura in rilievo sull'anta di una porta.
        case doorPanel
        /// Rosetta e leva. È l'unico dettaglio del modello alla scala della mano,
        /// e per questo è il primo che si riconosce.
        case handle
        /// Un arredo. Porta la propria tinta, quando ne ha una.
            case furnitureSide
            case furnitureTop
        }
        var points: [SIMD3<Double>]
        var kind: Kind
        /// Indice nella palette delle stanze, solo per i pavimenti.
        var roomColorIndex: Int?
        /// Identità della stanza, per poterla selezionare toccando il pavimento.
        var roomID: UUID?
        var roomName: String?
        /// Materiale pavimento scelto nel Drawing Context, solo per le facce floor.
        var floorKind: FloorKind? = nil
        /// Tipo apertura, solo per pannelli/telai/vetri generati da opening.
        var openingKind: OpeningKind? = nil
        /// Tipo muro sorgente, utile per distinguere ingresso, interno e balcone.
        var wallKind: WallKind? = nil
        /// Lato apertura scelto nel 2D.
        var flipSide: Bool = false
        /// Tinta scelta dall'utente per questo arredo, se ne ha una.
        var tint: CGColor?

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
        // Nell'ordine di disegno del documento, così i tappeti restano sotto
        // come già fanno in pianta.
        for item in document.furnitureDrawOrder {
            result.append(contentsOf: furnitureFaces(item))
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
                     roomName: area.name,
                     floorKind: area.floorKind,
                     tint: nil)]
    }

    // MARK: - Arredi

    /// Un arredo diventa **una o due scatole**.
    ///
    /// Il modello ha ingombri, non forme: estrudere il rettangolo dà una cassa,
    /// e una casa piena di casse non si legge. Due volumi sovrapposti bastano a
    /// far riconoscere un divano da un tavolo — seduta più schienale, materasso
    /// più testiera — e sono la differenza fra «un mobile» e «quel mobile».
    /// Modellarli davvero è un altro mestiere e non serve a questa vista.
    private static func furnitureFaces(_ item: FurnitureItem) -> [Face] {
        let kind = item.kind
        let tint = item.tintIndex.flatMap { index -> CGColor? in
            let tints = FurnitureTint.allCases
            guard index >= 0, index < tints.count else { return nil }
            return tints[index].darkCGColor
        }

        // Un tappeto è a terra: un volume, per quanto basso, farebbe ombra e
        // spigoli dove nella realtà non si inciampa.
        if kind == .rug {
            return [Face(points: corners(of: item, at: 0.002), kind: .furnitureTop,
                         roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint)]
        }

        var faces = boxFaces(item, from: 0, to: height(of: kind), tint: tint)
        if let back = backrest(of: kind) {
            faces += boxFaces(item, from: back.from, to: back.to,
                              tint: tint, fraction: back.depth, atFar: back.atFar)
        }
        return faces
    }

    /// Altezze plausibili, non misurate: servono a distinguere un tavolo da un
    /// armadio a colpo d'occhio, non a fare un computo metrico.
    private static func height(of kind: FurnitureKind) -> Double {
        switch kind {
        case .sofa, .armchair:      0.42
        case .chair:                0.45
        case .diningTable:          0.75
        case .bed:                  0.50
        case .wardrobe:             2.10
        case .toilet:               0.40
        case .sink, .kitchenSink:   0.85
        case .inductionCooktop:     0.90
        case .washingMachine:       0.85
        case .bathtub:              0.55
        case .shower:               0.10
        case .kitchenCounter:       0.90
        case .tvUnit:               0.45
        case .plant:                0.70
        case .stairs:               0.60
        case .spiralStairs:         2.20
        case .tree:                 2.20
        case .hedge:                0.90
        case .rug:                  0.00
        case .generic:              0.75
        }
    }

    /// Il secondo volume: schienale, testiera, cassetta, chioma. `fraction` è
    /// quanta parte della profondità occupa, `atFar` da quale lato sta.
    private static func backrest(of kind: FurnitureKind) -> (from: Double, to: Double, depth: Double, atFar: Bool)? {
        switch kind {
        case .sofa, .armchair: (0.42, 0.82, 0.30, true)
        case .chair:           (0.45, 0.92, 0.22, true)
        case .bed:             (0.50, 1.00, 0.10, true)
        case .toilet:          (0.40, 0.78, 0.30, true)
        case .plant:           (0.70, 1.30, 0.60, false)
        case .tree:            (2.20, 3.60, 0.95, false)
        case .shower:          (0.10, 2.00, 1.00, false)
        default:               nil
        }
    }

    /// I quattro angoli del rettangolo, ruotati come nel disegno.
    private static func corners(of item: FurnitureItem, at z: Double,
                                fraction: Double = 1, atFar: Bool = false) -> [SIMD3<Double>] {
        let rect = item.rect
        let centre = SIMD2(metres(rect.midX), metres(rect.midY))
        let half = SIMD2(metres(rect.width) / 2, metres(rect.height) / 2)

        // Il volume secondario occupa una fetta lungo la profondità, non tutto
        // il rettangolo: uno schienale largo quanto il divano è un muro.
        let depth = half.y * 2 * fraction
        let y0 = atFar ? half.y - depth : -half.y
        let y1 = atFar ? half.y : -half.y + depth

        let local = [SIMD2(-half.x, y0), SIMD2(half.x, y0), SIMD2(half.x, y1), SIMD2(-half.x, y1)]
        let angle = item.rotationDegrees * .pi / 180
        return local.map { point in
            let x = point.x * cos(angle) - point.y * sin(angle)
            let y = point.x * sin(angle) + point.y * cos(angle)
            return SIMD3(centre.x + x, centre.y + y, z)
        }
    }

    private static func boxFaces(_ item: FurnitureItem, from bottom: Double, to top: Double,
                                 tint: CGColor?, fraction: Double = 1, atFar: Bool = false) -> [Face] {
        guard top > bottom else { return [] }
        let low = corners(of: item, at: bottom, fraction: fraction, atFar: atFar)
        let high = corners(of: item, at: top, fraction: fraction, atFar: atFar)
        var faces = [Face(points: high, kind: .furnitureTop,
                          roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint)]
        for index in 0..<4 {
            let next = (index + 1) % 4
            faces.append(Face(points: [low[index], low[next], high[next], high[index]],
                              kind: .furnitureSide,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: tint))
        }
        return faces
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
        /// I vani, che poi `FloorplanOpeningBuilder` riempie di infisso.
        var holes: [FloorplanOpeningBuilder.Opening] = []
        // Un tratto pieno più corto dello spessore del muro non è un muro: è una
        // pila. E se tocca un estremo si prende anche la coda di giunzione, che
        // lo spinge **fuori** dallo spigolo — in pianta è invisibile perché la
        // linea del muro resta continua, in volume diventa un pilastro isolato
        // accanto alla casa. Si preferisce allargare l'apertura di quei pochi
        // centimetri: uno stipite spostato non lo nota nessuno, un pilastro sì.
        let minSpan = thickness
        var cursor = 0.0
        for opening in openings {
            let width = metres(opening.width)
            let centre = Double(opening.t) * length
            var from = max(0, centre - width / 2)
            var to   = min(length, centre + width / 2)
            // `from` sotto il cursore vuol dire aperture sovrapposte: agganciarlo
            // al cursore impedisce anche che questo torni indietro e riempia di
            // muro i vani già scavati.
            if from - cursor < minSpan { from = cursor }
            if length - to < minSpan { to = length }
            guard to > from else { continue }

            if from > cursor {
                spans.append((cursor, from, 0, wallTop))
            }
            switch opening.kind {
            case .window:
                spans.append((from, to, 0, min(heights.windowBottom, wallTop)))
                spans.append((from, to, heights.windowTop, wallTop))
                holes.append(.init(from: from, to: to,
                                   bottom: heights.windowBottom,
                                   top: min(heights.windowTop, wallTop),
                                   kind: opening.kind, flipSide: opening.flipSide))
            case .door, .slidingDoor, .frenchDoor:
                spans.append((from, to, heights.doorTop, wallTop))
                // Una porta poggia a terra: niente traversa in basso, o
                // diventa un ostacolo che nella realtà non c'è.
                holes.append(.init(from: from, to: to,
                                   bottom: 0,
                                   top: min(heights.doorTop, wallTop),
                                   kind: opening.kind, flipSide: opening.flipSide))
            }
            cursor = max(cursor, to)
        }
        if cursor < length {
            spans.append((cursor, length, 0, wallTop))
        }

        let unitNormal = SIMD2(-axis.y, axis.x)
        let normal = unitNormal * (thickness / 2)

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

        // Gli infissi non sono più adesivi sulla mezzeria: li costruisce un
        // builder dedicato come solidi dentro lo spessore del muro. Un parapetto
        // di balcone non ne ha, quindi non lo si disturba.
        if !isParapet {
            let context = FloorplanOpeningBuilder.Wall(start: start,
                                                       axis: axis,
                                                       normal: unitNormal,
                                                       thickness: thickness,
                                                       kind: wall.kind)
            for hole in holes {
                faces += FloorplanOpeningBuilder.faces(for: hole, in: context)
            }
        }

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
            return Face(points: points, kind: kind, roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil)
        }
        var faces = [
            Face(points: corners.map { SIMD3($0.x, $0.y, top) }, kind: topKind,
                 roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil),
            face([0, 1, 1, 0], kind: sideKind, low: bottom, high: top),
            face([2, 3, 3, 2], kind: sideKind, low: bottom, high: top),
            face([1, 2, 2, 1], kind: sideKind, low: bottom, high: top),
            face([3, 0, 0, 3], kind: sideKind, low: bottom, high: top)
        ]
        // Il sotto di un muro che poggia a terra non si vede mai. Quello di un
        // architrave sopra una porta sì: è l'intradosso del vano, e senza si
        // guarda dentro un solido vuoto.
        if bottom > 0.001 {
            faces.append(Face(points: corners.map { SIMD3($0.x, $0.y, bottom) }, kind: sideKind,
                              roomColorIndex: nil, roomID: nil, roomName: nil, tint: nil))
        }
        return faces
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
