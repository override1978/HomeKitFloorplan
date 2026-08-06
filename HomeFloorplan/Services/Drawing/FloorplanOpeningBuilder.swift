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

    // MARK: - Ingresso

    static func faces(for opening: Opening, in wall: Wall) -> [Face] {
        let width = opening.to - opening.from
        let height = opening.top - opening.bottom
        guard width > 0.15, height > 0.15 else { return [] }

        let frameWidth = min(0.06, width * 0.14, height * 0.14)
        var faces = frameFaces(opening, wall, frameWidth: frameWidth)

        switch opening.kind {
        case .window:
            faces += windowFaces(opening, wall, frameWidth: frameWidth)
        case .frenchDoor, .slidingDoor:
            faces += glazedDoorFaces(opening, wall, frameWidth: frameWidth)
        case .door:
            faces += solidDoorFaces(opening, wall, frameWidth: frameWidth)
        }

        return faces
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

    private static func windowFaces(_ opening: Opening,
                                    _ wall: Wall,
                                    frameWidth: Double) -> [Face] {
        let u = (opening.from + frameWidth)...(opening.to - frameWidth)
        let v = (opening.bottom + frameWidth)...(opening.top - frameWidth)
        guard u.upperBound > u.lowerBound, v.upperBound > v.lowerBound else { return [] }

        var faces = box(wall, opening, u: u, v: v,
                        w: -glassHalfThickness...glassHalfThickness, kind: .glass)

        if opening.to - opening.from > mullionThreshold {
            let centre = (opening.from + opening.to) / 2
            let half = wall.thickness / 2 - frameDepthInset
            faces += box(wall, opening,
                         u: (centre - 0.028)...(centre + 0.028),
                         v: v, w: -half...half, kind: .frame)
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

    private static func glazedDoorFaces(_ opening: Opening,
                                        _ wall: Wall,
                                        frameWidth: Double) -> [Face] {
        let u = (opening.from + frameWidth)...(opening.to - frameWidth)
        let v = opening.bottom...(opening.top - frameWidth)
        guard u.upperBound > u.lowerBound, v.upperBound > v.lowerBound else { return [] }

        let rail = 0.095
        let half = leafHalfThickness
        var faces: [Face] = []

        // I regoli dell'anta: il vetro sta dentro, non a filo.
        faces += box(wall, opening, u: u.lowerBound...(u.lowerBound + rail), v: v, w: -half...half, kind: .doorLeaf)
        faces += box(wall, opening, u: (u.upperBound - rail)...u.upperBound, v: v, w: -half...half, kind: .doorLeaf)
        faces += box(wall, opening, u: u, v: v.lowerBound...(v.lowerBound + rail), w: -half...half, kind: .doorLeaf)
        faces += box(wall, opening, u: u, v: (v.upperBound - rail)...v.upperBound, w: -half...half, kind: .doorLeaf)

        let glassU = (u.lowerBound + rail)...(u.upperBound - rail)
        let glassV = (v.lowerBound + rail)...(v.upperBound - rail)
        if glassU.upperBound > glassU.lowerBound, glassV.upperBound > glassV.lowerBound {
            faces += box(wall, opening, u: glassU, v: glassV,
                         w: -glassHalfThickness...glassHalfThickness, kind: .glass)

            if opening.to - opening.from > mullionThreshold {
                let centre = (opening.from + opening.to) / 2
                faces += box(wall, opening,
                             u: (centre - 0.032)...(centre + 0.032),
                             v: glassV, w: -half...half, kind: .doorLeaf)
            }
        }

        faces += handleFaces(opening, wall, frameWidth: frameWidth, leafHalf: half)
        return faces
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
