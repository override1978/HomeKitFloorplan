import CoreGraphics

// MARK: - RoomShapeTracer

/// Dal grafo dei muri al poligono della stanza che contiene un punto.
///
/// È il motore del «tocca dentro la stanza e l'area si fa da sola»: i muri
/// conoscono già la forma, all'utente resta solo la scelta della stanza
/// HomeKit. Geometria pura, niente stato: si testa senza simulatore.
///
/// L'algoritmo è l'estrazione classica delle facce di un grafo planare:
/// i muri si spezzano a intersezioni e giunzioni a T, i vertici vicini si
/// fondono, e da ogni lato orientato si cammina prendendo sempre la svolta
/// più stretta — ogni ciclo chiuso così percorso è una faccia. La stanza è
/// la faccia più piccola che contiene il tocco.
enum RoomShapeTracer {

    /// Tolleranza di fusione dei vertici, in punti canvas. I muri nascono
    /// snappati fra loro: questa assorbe solo il rumore numerico, non
    /// ricuce disegni sconnessi.
    private static let epsilon: CGFloat = 1.0

    /// Sotto quest'area una faccia è un artefatto di spezzatura, non una
    /// stanza (20×20 pt ≈ mezzo modulo di griglia).
    private static let minimumArea: CGFloat = 400

    /// Il poligono della stanza chiusa che contiene `point`, o `nil` se il
    /// punto non è racchiuso dai muri. I vertici collineari (giunzioni a T
    /// sul perimetro) vengono rimossi, così le maniglie restano poche.
    static func roomPolygon(containing point: CGPoint,
                            walls: [WallSegment]) -> [CGPoint]? {
        let raw: [(CGPoint, CGPoint)] = walls.compactMap { wall in
            hypot(wall.end.x - wall.start.x, wall.end.y - wall.start.y) > epsilon
                ? (wall.start, wall.end) : nil
        }
        guard raw.count >= 3 else { return nil }

        // ── Spezzatura: ogni muro si divide dove ne incrocia o ne tocca un altro ──
        var pieces: [(CGPoint, CGPoint)] = []
        for (i, segment) in raw.enumerated() {
            let length = hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
            var ts: [CGFloat] = [0, 1]
            for (j, other) in raw.enumerated() where j != i {
                if let t = intersectionParameter(of: segment, with: other) {
                    ts.append(t)
                }
                for endpoint in [other.0, other.1] {
                    if let t = restingParameter(of: endpoint, on: segment) {
                        ts.append(t)
                    }
                }
            }
            ts.sort()
            var cuts: [CGFloat] = []
            let minStep = epsilon / max(length, epsilon)
            for t in ts where (cuts.last.map { t - $0 > minStep } ?? true) {
                cuts.append(t)
            }
            for index in 0..<(cuts.count - 1) {
                pieces.append((interpolate(segment, cuts[index]),
                               interpolate(segment, cuts[index + 1])))
            }
        }

        // ── Vertici fusi su griglia di tolleranza, lati dedotti ──
        struct VertexKey: Hashable { let x: Int; let y: Int }
        func key(_ p: CGPoint) -> VertexKey {
            VertexKey(x: Int((p.x / epsilon).rounded()),
                      y: Int((p.y / epsilon).rounded()))
        }
        var indexByKey: [VertexKey: Int] = [:]
        var positions: [CGPoint] = []
        func vertexIndex(_ p: CGPoint) -> Int {
            let k = key(p)
            if let existing = indexByKey[k] { return existing }
            indexByKey[k] = positions.count
            positions.append(p)
            return positions.count - 1
        }
        var edgeSet = Set<[Int]>()
        for piece in pieces {
            let a = vertexIndex(piece.0), b = vertexIndex(piece.1)
            guard a != b else { continue }
            edgeSet.insert([min(a, b), max(a, b)])
        }
        guard edgeSet.count >= 3 else { return nil }

        var neighbours: [[Int]] = Array(repeating: [], count: positions.count)
        for edge in edgeSet {
            neighbours[edge[0]].append(edge[1])
            neighbours[edge[1]].append(edge[0])
        }
        func bearing(from a: Int, to b: Int) -> CGFloat {
            atan2(positions[b].y - positions[a].y, positions[b].x - positions[a].x)
        }
        for v in positions.indices {
            neighbours[v].sort { bearing(from: v, to: $0) < bearing(from: v, to: $1) }
        }

        // ── Cammino delle facce: da (u→v) si prosegue con la svolta più
        //    stretta — il vicino di v con angolo subito precedente alla
        //    direzione di ritorno. Un vicolo cieco rimbalza su sé stesso. ──
        func next(after u: Int, at v: Int) -> Int {
            let candidates = neighbours[v]
            guard candidates.count > 1 else { return candidates[0] }
            let back = bearing(from: v, to: u)
            var best: Int?
            var bestAngle = -CGFloat.infinity
            var wrap = candidates[0]
            var wrapAngle = -CGFloat.infinity
            for w in candidates {
                let angle = bearing(from: v, to: w)
                if angle > wrapAngle { wrapAngle = angle; wrap = w }
                if angle < back - 1e-9, angle > bestAngle { bestAngle = angle; best = w }
            }
            return best ?? wrap
        }

        struct DirectedEdge: Hashable { let from: Int; let to: Int }
        var visited = Set<DirectedEdge>()
        var candidate: [CGPoint]?
        var candidateArea = CGFloat.infinity
        for edge in edgeSet {
            for start in [DirectedEdge(from: edge[0], to: edge[1]),
                          DirectedEdge(from: edge[1], to: edge[0])] {
                guard !visited.contains(start) else { continue }
                var face: [Int] = []
                var current = start
                while !visited.contains(current) {
                    visited.insert(current)
                    face.append(current.to)
                    current = DirectedEdge(from: current.to,
                                           to: next(after: current.from, at: current.to))
                }
                let polygon = simplify(face.map { positions[$0] })
                guard polygon.count >= 3 else { continue }
                let area = abs(signedArea(polygon))
                guard area >= minimumArea, area < candidateArea,
                      contains(polygon, point) else { continue }
                candidate = polygon
                candidateArea = area
            }
        }
        return candidate
    }

    // MARK: - Geometria di servizio

    /// Intersezione propria fra due segmenti: il parametro su `segment`,
    /// oppure `nil` se si sfiorano solo agli estremi (quelli sono già cuts).
    private static func intersectionParameter(of segment: (CGPoint, CGPoint),
                                              with other: (CGPoint, CGPoint)) -> CGFloat? {
        let d1 = CGPoint(x: segment.1.x - segment.0.x, y: segment.1.y - segment.0.y)
        let d2 = CGPoint(x: other.1.x - other.0.x, y: other.1.y - other.0.y)
        let cross = d1.x * d2.y - d1.y * d2.x
        guard abs(cross) > 1e-9 else { return nil }
        let dx = other.0.x - segment.0.x
        let dy = other.0.y - segment.0.y
        let t = (dx * d2.y - dy * d2.x) / cross
        let u = (dx * d1.y - dy * d1.x) / cross
        guard t > 1e-6, t < 1 - 1e-6, u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        return t
    }

    /// Giunzione a T: un estremo altrui appoggiato su questo segmento.
    private static func restingParameter(of p: CGPoint,
                                         on segment: (CGPoint, CGPoint)) -> CGFloat? {
        let d = CGPoint(x: segment.1.x - segment.0.x, y: segment.1.y - segment.0.y)
        let lengthSquared = d.x * d.x + d.y * d.y
        guard lengthSquared > 0 else { return nil }
        let t = ((p.x - segment.0.x) * d.x + (p.y - segment.0.y) * d.y) / lengthSquared
        guard t > 1e-6, t < 1 - 1e-6 else { return nil }
        let foot = CGPoint(x: segment.0.x + t * d.x, y: segment.0.y + t * d.y)
        guard hypot(p.x - foot.x, p.y - foot.y) <= epsilon else { return nil }
        return t
    }

    private static func interpolate(_ segment: (CGPoint, CGPoint), _ t: CGFloat) -> CGPoint {
        CGPoint(x: segment.0.x + t * (segment.1.x - segment.0.x),
                y: segment.0.y + t * (segment.1.y - segment.0.y))
    }

    private static func signedArea(_ polygon: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    private static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Toglie i doppioni consecutivi, gli speroni (andata-e-ritorno su un
    /// vicolo cieco) e i vertici collineari: le maniglie devono stare solo
    /// dove il perimetro gira davvero.
    private static func simplify(_ polygon: [CGPoint]) -> [CGPoint] {
        var result = polygon
        var changed = true
        while changed, result.count >= 3 {
            changed = false
            var kept: [CGPoint] = []
            for index in result.indices {
                let prev = result[(index + result.count - 1) % result.count]
                let here = result[index]
                let following = result[(index + 1) % result.count]
                if hypot(here.x - prev.x, here.y - prev.y) <= epsilon { changed = true; continue }
                let cross = (here.x - prev.x) * (following.y - here.y)
                          - (here.y - prev.y) * (following.x - here.x)
                let dot = (here.x - prev.x) * (following.x - here.x)
                        + (here.y - prev.y) * (following.y - here.y)
                // Collineare in avanti (angolo piatto) o sperone (ritorno secco).
                if abs(cross) < 1e-3, dot > 0 || hypot(following.x - prev.x, following.y - prev.y) <= epsilon {
                    changed = true
                    continue
                }
                kept.append(here)
            }
            result = kept
        }
        return result
    }
}
