import Foundation
import simd

// MARK: - FloorplanOpeningBuilder

/// Porte e finestre costruite come **solidi**, non come adesivi.
///
/// Prima ogni infisso era un quadrilatero a spessore zero sulla mezzeria del
/// muro: telaio, vetro e battente vivevano tutti sullo stesso piano infinitamente
/// sottile. Andava bene finché i materiali erano piatti, ma con la luce vera una
/// lastra senza spessore non ha niente da ombreggiare — e appena la telecamera si
/// allinea col muro sparisce del tutto.
///
/// Qui un vano diventa quello che è nella realtà: **un buco in un muro spesso**,
/// con un telaio incassato, un battente più sottile del telaio, e una maniglia
/// che sporge. Tutta la credibilità viene da quei pochi centimetri di profondità,
/// non dai materiali.
///
/// Puro e senza asset: entrano le misure del vano, escono quadrilateri.
enum FloorplanOpeningBuilder {

    typealias Face = FloorplanExtruder.Face

    /// Il vano nel piano del muro, in metri.
    struct Opening {
        var from: Double
        var to: Double
        var bottom: Double
        var top: Double
        var kind: OpeningKind
        var flipSide: Bool
        /// Il contatto che sorveglia questo vano risulta aperto.
        var isOpen: Bool = false
    }

    /// Il muro che lo contiene.
    struct Wall {
        var start: SIMD2<Double>
        var axis: SIMD2<Double>
        /// Perpendicolare **unitaria**: lo spessore lo mette questo builder.
        var normal: SIMD2<Double>
        var thickness: Double
        var kind: WallKind
    }

    // MARK: - Misure
    //
    // Numeri da falegname, non da capriccio: un telaio da 6 cm, un battente da
    // 4, una maniglia a 1,03 m. Sono le proporzioni che l'occhio riconosce senza
    // saperle, ed è per questo che vanno prese giuste anche in un modello grezzo.

    private static let frameDepthInset = 0.012
    private static let leafHalfThickness = 0.021
    private static let exteriorLeafHalfThickness = 0.028
    private static let panelMargin = 0.085
    private static let panelRelief = 0.008
    private static let handleHeight = 1.03
    private static let glassHalfThickness = 0.004
    /// Oltre questa larghezza una finestra prende un montante centrale e una
    /// porta-finestra diventa a due ante: una lastra di vetro da un metro e mezzo
    /// senza niente in mezzo non esiste, e si vede che non esiste.
    private static let mullionThreshold = 1.30
    /// Quanto si apre un'anta. Non 90 gradi: una porta spalancata attraversa
    /// mezza stanza e copre quello che c'è dietro proprio mentre la si sta
    /// guardando. Serve che si legga «aperta», non che sia misurata.
    /// Regoli dell'anta: sottili su una finestra, robusti su una porta-finestra.
    private static let windowRail = 0.045
    private static let doorRail = 0.095
    private static let doorSwing = 38.0 * .pi / 180
    private static let sashSwing = 24.0 * .pi / 180

    // MARK: - Ingresso

    static func faces(for opening: Opening, in wall: Wall) -> [Face] {
        let width = opening.to - opening.from
        let height = opening.top - opening.bottom
        guard width > 0.15, height > 0.15 else { return [] }

        let frameWidth = min(0.06, width * 0.14, height * 0.14)

        // Il telaio è **fisso**, il resto sono ante. Separarli qui è ciò che
        // permette di aprire senza toccare la geometria.
        let fixed = frameFaces(opening, wall, frameWidth: frameWidth)
        let leaves: [Leaf]
        let swing: Double

        switch opening.kind {
        case .window:
            leaves = windowLeaves(opening, wall, frameWidth: frameWidth)
            swing = sashSwing
        case .frenchDoor, .slidingDoor:
            leaves = glazedDoorLeaves(opening, wall, frameWidth: frameWidth)
            swing = doorSwing
        case .door:
            leaves = [Leaf(faces: solidDoorFaces(opening, wall, frameWidth: frameWidth),
                           hinge: opening.flipSide ? opening.to : opening.from,
                           hingeAtStart: !opening.flipSide)]
            swing = doorSwing
        }

        guard opening.isOpen else { return fixed + leaves.flatMap(\.faces) }
        return fixed + leaves.flatMap { swung($0, in: wall, by: swing) }
    }

    /// Una parte mobile con il **proprio** cardine.
    ///
    /// Serve perché un infisso non è per forza una cosa sola: una finestra larga
    /// ha due ante che si aprono a libro, ognuna incernierata sul proprio stipite.
    /// Ruotarle insieme attorno a un cardine unico le fa scorrere di lato tutte
    /// intere, montante compreso — che non è come si apre una finestra.
    private struct Leaf {
        var faces: [Face]
        /// Posizione del cardine lungo il muro.
        var hinge: Double
        /// Il cardine è all'estremo di partenza: decide il verso di rotazione,
        /// così due ante contrapposte si aprono **dallo stesso lato** del muro.
        var hingeAtStart: Bool
    }

    /// L'anta ruota attorno al proprio cardine, che è l'unica cosa che il
    /// disegno sa già: `flipSide` dice da quale estremo del vano sta.
    ///
    /// Il verso di apertura invece **non è nel modello** — nessuno ha mai detto
    /// se quella porta si apre verso la cucina o verso il corridoio. Si apre
    /// tutto dallo stesso lato del muro: sbagliato la metà delle volte, ma
    /// coerente, e nessuna delle due scelte è più informata dell'altra.
    private static func swung(_ leaf: Leaf,
                              in wall: Wall,
                              by angle: Double) -> [Face] {
        let pivot = wall.start + wall.axis * leaf.hinge
        let rotation = leaf.hingeAtStart ? angle : -angle
        let (cosine, sine) = (cos(rotation), sin(rotation))

        return leaf.faces.map { face in
            var rotated = face
            rotated.points = face.points.map { point in
                let dx = point.x - pivot.x
                let dy = point.y - pivot.y
                return SIMD3(pivot.x + dx * cosine - dy * sine,
                             pivot.y + dx * sine + dy * cosine,
                             point.z)
            }
            return rotated
        }
    }

    // MARK: - Telaio

    /// Quattro montanti incassati nel vano, che occupano quasi tutto lo spessore
    /// del muro. È il pezzo che trasforma un buco in un infisso.
    private static func frameFaces(_ opening: Opening,
                                   _ wall: Wall,
                                   frameWidth: Double) -> [Face] {
        let half = wall.thickness / 2 - frameDepthInset
        let depth = -half...half
        var faces: [Face] = []

        faces += box(wall, opening,
                     u: opening.from...(opening.from + frameWidth),
                     v: opening.bottom...opening.top,
                     w: depth, kind: .frame)
        faces += box(wall, opening,
                     u: (opening.to - frameWidth)...opening.to,
                     v: opening.bottom...opening.top,
                     w: depth, kind: .frame)
        faces += box(wall, opening,
                     u: opening.from...opening.to,
                     v: (opening.top - frameWidth)...opening.top,
                     w: depth, kind: .frame)

        // Le porte poggiano a terra: una traversa in basso sarebbe uno scalino
        // che nella realtà non c'è. Le finestre invece hanno il davanzale.
        if opening.kind == .window {
            faces += box(wall, opening,
                         u: opening.from...opening.to,
                         v: opening.bottom...(opening.bottom + frameWidth),
                         w: depth, kind: .frame)
        }

        return faces
    }

    // MARK: - Finestra

    /// Una o due ante, secondo la larghezza.
    ///
    /// Sopra la soglia la finestra si sdoppia: due ante che si incontrano al
    /// centro, ognuna incernierata sul proprio stipite. Da chiusa i due regoli
    /// centrali affiancati sono il montante — che quindi non serve più
    /// costruire a parte, e soprattutto non resta appeso a mezz'aria quando la
    /// finestra si apre.
    private static func windowLeaves(_ opening: Opening,
                                     _ wall: Wall,
                                     frameWidth: Double) -> [Leaf] {
        let u = (opening.from + frameWidth)...(opening.to - frameWidth)
        let v = (opening.bottom + frameWidth)...(opening.top - frameWidth)
        guard u.upperBound > u.lowerBound, v.upperBound > v.lowerBound else { return [] }

        guard opening.to - opening.from > mullionThreshold else {
            return [Leaf(faces: sashFaces(opening, wall, u: u, v: v, rail: windowRail),
                         hinge: opening.flipSide ? u.upperBound : u.lowerBound,
                         hingeAtStart: !opening.flipSide)]
        }

        let centre = (u.lowerBound + u.upperBound) / 2
        return [
            Leaf(faces: sashFaces(opening, wall, u: u.lowerBound...centre, v: v, rail: windowRail),
                 hinge: u.lowerBound, hingeAtStart: true),
            Leaf(faces: sashFaces(opening, wall, u: centre...u.upperBound, v: v, rail: windowRail),
                 hinge: u.upperBound, hingeAtStart: false)
        ]
    }

    /// Un'anta vetrata: quattro regoli e il vetro incassato dentro.
    private static func sashFaces(_ opening: Opening,
                                  _ wall: Wall,
                                  u: ClosedRange<Double>,
                                  v: ClosedRange<Double>,
                                  rail: Double,
                                  frameKind: FloorplanExtruder.Face.Kind = .frame) -> [Face] {
        let half = leafHalfThickness
        var faces: [Face] = []

        faces += box(wall, opening, u: u.lowerBound...(u.lowerBound + rail), v: v, w: -half...half, kind: frameKind)
        faces += box(wall, opening, u: (u.upperBound - rail)...u.upperBound, v: v, w: -half...half, kind: frameKind)
        faces += box(wall, opening, u: u, v: v.lowerBound...(v.lowerBound + rail), w: -half...half, kind: frameKind)
        faces += box(wall, opening, u: u, v: (v.upperBound - rail)...v.upperBound, w: -half...half, kind: frameKind)

        let glassU = (u.lowerBound + rail)...(u.upperBound - rail)
        let glassV = (v.lowerBound + rail)...(v.upperBound - rail)
        if glassU.upperBound > glassU.lowerBound, glassV.upperBound > glassV.lowerBound {
            faces += box(wall, opening, u: glassU, v: glassV,
                         w: -glassHalfThickness...glassHalfThickness, kind: .glass)
        }
        return faces
    }

    // MARK: - Porta cieca

    private static func solidDoorFaces(_ opening: Opening,
                                       _ wall: Wall,
                                       frameWidth: Double) -> [Face] {
        let thickness = wall.kind == .exterior ? exteriorLeafHalfThickness : leafHalfThickness
        let u = (opening.from + frameWidth)...(opening.to - frameWidth)
        let v = opening.bottom...(opening.top - frameWidth)
        guard u.upperBound > u.lowerBound, v.upperBound > v.lowerBound else { return [] }

        var faces = box(wall, opening, u: u, v: v, w: -thickness...thickness, kind: .doorLeaf)
        faces += panelFaces(opening, wall, u: u, v: v, leafHalf: thickness)
        faces += handleFaces(opening, wall, frameWidth: frameWidth, leafHalf: thickness)
        return faces
    }

    /// Due specchiature in rilievo per faccia.
    ///
    /// Nella realtà sono incavate, ma da un modello non si può togliere materia:
    /// un rilievo di 8 mm produce lo stesso bordo d'ombra e, sotto luce radente,
    /// si legge esattamente allo stesso modo.
    private static func panelFaces(_ opening: Opening,
                                   _ wall: Wall,
                                   u: ClosedRange<Double>,
                                   v: ClosedRange<Double>,
                                   leafHalf: Double) -> [Face] {
        let inner = (u.lowerBound + panelMargin)...(u.upperBound - panelMargin)
        guard inner.upperBound > inner.lowerBound else { return [] }

        let height = v.upperBound - v.lowerBound
        let bands = [
            (v.lowerBound + panelMargin)...(v.lowerBound + height * 0.40),
            (v.lowerBound + height * 0.48)...(v.upperBound - panelMargin)
        ]

        return bands.flatMap { band -> [Face] in
            guard band.upperBound > band.lowerBound else { return [] }
            return box(wall, opening, u: inner, v: band,
                       w: leafHalf...(leafHalf + panelRelief), kind: .doorPanel)
                + box(wall, opening, u: inner, v: band,
                      w: (-leafHalf - panelRelief)...(-leafHalf), kind: .doorPanel)
        }
    }

    // MARK: - Porta vetrata

    /// Una porta-finestra larga è a due ante come una finestra: stessa logica,
    /// regoli più robusti e la maniglia sull'anta che la porta.
    private static func glazedDoorLeaves(_ opening: Opening,
                                         _ wall: Wall,
                                         frameWidth: Double) -> [Leaf] {
        let u = (opening.from + frameWidth)...(opening.to - frameWidth)
        let v = opening.bottom...(opening.top - frameWidth)
        guard u.upperBound > u.lowerBound, v.upperBound > v.lowerBound else { return [] }

        let handle = handleFaces(opening, wall, frameWidth: frameWidth, leafHalf: leafHalfThickness)

        guard opening.to - opening.from > mullionThreshold else {
            return [Leaf(faces: sashFaces(opening, wall, u: u, v: v, rail: doorRail, frameKind: .doorLeaf) + handle,
                         hinge: opening.flipSide ? opening.to : opening.from,
                         hingeAtStart: !opening.flipSide)]
        }

        let centre = (u.lowerBound + u.upperBound) / 2
        let handleOnStartLeaf = opening.flipSide
        return [
            Leaf(faces: sashFaces(opening, wall, u: u.lowerBound...centre, v: v, rail: doorRail, frameKind: .doorLeaf)
                 + (handleOnStartLeaf ? handle : []),
                 hinge: opening.from, hingeAtStart: true),
            Leaf(faces: sashFaces(opening, wall, u: centre...u.upperBound, v: v, rail: doorRail, frameKind: .doorLeaf)
                 + (handleOnStartLeaf ? [] : handle),
                 hinge: opening.to, hingeAtStart: false)
        ]
    }

    // MARK: - Maniglia

    /// Rosetta più leva, sui due lati.
    ///
    /// Sporge di tre centimetri e mezzo: è il dettaglio più piccolo del modello e
    /// quello che si riconosce per primo, perché è l'unica cosa alla scala della
    /// mano in una scena fatta di stanze.
    private static func handleFaces(_ opening: Opening,
                                    _ wall: Wall,
                                    frameWidth: Double,
                                    leafHalf: Double) -> [Face] {
        let height = opening.bottom + handleHeight
        guard height < opening.top - frameWidth - 0.06 else { return [] }

        // Il cardine sta dal lato indicato da `flipSide`: la maniglia va
        // dall'altro, o si aprirebbe dal lato sbagliato.
        let hingeAtStart = !opening.flipSide
        let free = hingeAtStart ? opening.to - frameWidth - 0.075 : opening.from + frameWidth + 0.075
        let leverEnd = hingeAtStart ? free - 0.10 : free + 0.10

        let rose = min(free, free)...max(free, free)
        _ = rose

        let roseU = (free - 0.036)...(free + 0.036)
        let leverU = min(free, leverEnd)...max(free, leverEnd)
        let roseV = (height - 0.036)...(height + 0.036)
        let leverV = (height - 0.013)...(height + 0.013)

        var faces: [Face] = []
        for side in [1.0, -1.0] {
            let base = leafHalf * side
            let roseOuter = base + 0.010 * side
            let leverOuter = base + 0.038 * side

            faces += box(wall, opening, u: roseU, v: roseV,
                         w: range(base, roseOuter), kind: .handle)
            faces += box(wall, opening, u: leverU, v: leverV,
                         w: range(roseOuter, leverOuter), kind: .handle)
        }
        return faces
    }

    // MARK: - Geometria

    private static func range(_ a: Double, _ b: Double) -> ClosedRange<Double> {
        min(a, b)...max(a, b)
    }

    /// Un parallelepipedo espresso nel sistema del muro: `u` lungo il muro, `v`
    /// in altezza, `w` attraverso lo spessore.
    private static func box(_ wall: Wall,
                            _ opening: Opening,
                            u: ClosedRange<Double>,
                            v: ClosedRange<Double>,
                            w: ClosedRange<Double>,
                            kind: FloorplanExtruder.Face.Kind) -> [Face] {
        guard u.upperBound > u.lowerBound,
              v.upperBound > v.lowerBound,
              w.upperBound > w.lowerBound
        else { return [] }

        func point(_ uu: Double, _ vv: Double, _ ww: Double) -> SIMD3<Double> {
            let planar = wall.start + wall.axis * uu + wall.normal * ww
            return SIMD3(planar.x, planar.y, vv)
        }

        func face(_ corners: [SIMD3<Double>]) -> Face {
            Face(points: corners,
                 kind: kind,
                 roomColorIndex: nil,
                 roomID: nil,
                 roomName: nil,
                 openingKind: opening.kind,
                 wallKind: wall.kind,
                 flipSide: opening.flipSide,
                 tint: nil)
        }

        let (u0, u1) = (u.lowerBound, u.upperBound)
        let (v0, v1) = (v.lowerBound, v.upperBound)
        let (w0, w1) = (w.lowerBound, w.upperBound)

        return [
            face([point(u0, v0, w0), point(u1, v0, w0), point(u1, v1, w0), point(u0, v1, w0)]),
            face([point(u0, v0, w1), point(u1, v0, w1), point(u1, v1, w1), point(u0, v1, w1)]),
            face([point(u0, v0, w0), point(u0, v0, w1), point(u0, v1, w1), point(u0, v1, w0)]),
            face([point(u1, v0, w0), point(u1, v0, w1), point(u1, v1, w1), point(u1, v1, w0)]),
            face([point(u0, v0, w0), point(u1, v0, w0), point(u1, v0, w1), point(u0, v0, w1)]),
            face([point(u0, v1, w0), point(u1, v1, w0), point(u1, v1, w1), point(u0, v1, w1)])
        ]
    }
}
