import Foundation
import CoreGraphics
import simd
import Testing
@testable import HomeFloorplan

/// La velatura d'angolo ha lo stesso problema di prova delle altre due — è
/// scura, stretta e sfumata, e su uno screenshot «non la vedo» non distingue
/// «non c'è» da «è debole» — più due suoi, che sbagliano in modo *visibile* ma
/// che a occhio si leggono come sporco invece che come errore: lo spigolo
/// **sporgente**, dove la luce arriva di più e un solco scuro scava il volume
/// al contrario, e il **taglio** di un muro, dove una fascia scura sullo
/// spessore contraddice uno stipite, che di luce ne prende da due lati.
@Suite("FloorplanExtruder — velature d'angolo")
struct FloorplanCornerShadeTests {

    /// Cento punti canvas per metro, come negli altri test di geometria.
    private static func metres(_ canvas: Double) -> Double { canvas / 100 }

    private static func walls(_ corners: [CGPoint], in document: inout DrawingDocument) {
        for index in corners.indices {
            document.walls.append(WallSegment(start: corners[index],
                                              end: corners[(index + 1) % corners.count],
                                              kind: .exterior))
        }
    }

    /// Una stanza rettangolare di 5 × 4 metri: quattro spigoli, tutti concavi.
    private static func rectangularRoom() -> DrawingDocument {
        var document = DrawingDocument()
        walls([CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200),
               CGPoint(x: 700, y: 600), CGPoint(x: 200, y: 600)], in: &document)
        document.roomAreas = [RoomArea(name: "Camera",
                                       rect: CGRect(x: 200, y: 200, width: 500, height: 400))]
        return document
    }

    /// La stessa stanza con una porta in mezzo a un muro: il vano taglia il muro
    /// in due e mette in scena gli stipiti, che guardano dentro la stanza.
    private static func roomWithADoor() -> DrawingDocument {
        var document = rectangularRoom()
        guard let wall = document.walls.first else { return document }
        document.openings = [PlacedOpening(wallID: wall.id, t: 0.5, kind: .door, width: 90)]
        return document
    }

    /// Una stanza a elle: cinque spigoli concavi e **uno sporgente**, quello in
    /// cui rientra il pezzo mancante.
    private static func lShapedRoom() -> DrawingDocument {
        var document = DrawingDocument()
        let corners = [CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200),
                       CGPoint(x: 700, y: 600), CGPoint(x: 450, y: 600),
                       CGPoint(x: 450, y: 400), CGPoint(x: 200, y: 400)]
        walls(corners, in: &document)
        document.roomAreas = [RoomArea(name: "Soggiorno",
                                       rect: CGRect(x: 200, y: 200, width: 500, height: 400),
                                       points: corners)]
        return document
    }

    private static func strips(_ document: DrawingDocument) -> [FloorplanExtruder.Face] {
        FloorplanExtruder.faces(from: document).filter { $0.kind == .wallCorner }
    }

    /// Il capo pieno di una striscia: il primo vertice, quello sullo spigolo.
    private static func anchor(_ face: FloorplanExtruder.Face) -> SIMD2<Double> {
        SIMD2(face.points[0].x, face.points[0].y)
    }

    /// Quanto dista lo spigolo più vicino da un vertice della pianta. Le
    /// strisce nascono sulla facciata interna, quindi rientrate di mezzo
    /// spessore rispetto alla mediana su cui sta il vertice.
    private static func nearestAnchor(to vertex: CGPoint,
                                      in faces: [FloorplanExtruder.Face]) -> Double {
        let target = SIMD2(metres(vertex.x), metres(vertex.y))
        return faces.map { simd_distance(anchor($0), target) }.min() ?? .infinity
    }

    @Test("Quattro spigoli, due velature per spigolo")
    func rectangularRoomGetsEightStrips() {
        #expect(Self.strips(Self.rectangularRoom()).count == 8)
    }

    /// ⚠️ Gli stipiti di una porta sono facce verticali di muro come tutte le
    /// altre, e guardano dentro la stanza: senza la soglia di larghezza ognuno
    /// si porta dietro il suo angolo, e il vano si ritrova bordato di scuro
    /// sullo spessore.
    @Test("Una porta non aggiunge angoli: gli stipiti non sono pareti")
    func doorJambsDoNotBecomeCorners() {
        #expect(Self.strips(Self.roomWithADoor()).count == 8)
    }

    /// ⚠️ Il test che giustifica tutto il conto della concavità. Senza il
    /// controllo sui versi il vertice sporgente ne prende due, e li prende
    /// esattamente dove la luce dovrebbe aumentare.
    @Test("Lo spigolo sporgente di una stanza a elle non si scurisce")
    func reflexCornerIsLeftAlone() {
        let faces = Self.strips(Self.lShapedRoom())
        #expect(!faces.isEmpty)

        // Il rientro della elle: l'unico vertice con l'angolo interno maggiore
        // di un piatto.
        #expect(Self.nearestAnchor(to: CGPoint(x: 450, y: 400), in: faces) > 0.30)

        // E il test vale in tutti e due i versi: gli altri cinque, concavi,
        // la velatura ce l'hanno.
        for vertex in [CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200),
                       CGPoint(x: 700, y: 600), CGPoint(x: 450, y: 600),
                       CGPoint(x: 200, y: 400)] {
            #expect(Self.nearestAnchor(to: vertex, in: faces) < 0.30)
        }
    }

    /// La velatura di terra si ferma a trentaquattro centimetri perché più su la
    /// luce ci arriva. Uno spigolo verticale no: occlude per tutta l'altezza, e
    /// fermarlo a mezz'aria disegnerebbe un gradino.
    @Test("Sale per tutta l'altezza del muro")
    func cornerSpansTheFullWall() {
        let faces = Self.strips(Self.rectangularRoom())
        #expect(!faces.isEmpty)
        for face in faces {
            let heights = face.points.map(\.z)
            #expect((heights.min() ?? -1) >= -0.001)
            #expect((heights.max() ?? 0) > 2.0)
        }
    }

    @Test("È larga quanto la sfumatura, non quanto il muro")
    func cornerIsAsWideAsItsFalloff() {
        for face in Self.strips(Self.rectangularRoom()) {
            let width = hypot(face.points[1].x - face.points[0].x,
                              face.points[1].y - face.points[0].y)
            #expect(abs(width - FloorplanExtruder.cornerReach) < 0.001)
        }
    }

    /// ⚠️ **L'ordine dei vertici è il contratto con le UV.** Il renderer mappa
    /// per indice — primo e ultimo punto pieni, secondo e terzo trasparenti —
    /// perché solo l'estrusore sa quale dei due capi è lo spigolo. Invertirli
    /// non rompe niente in compilazione: accende il buio dalla parte sbagliata,
    /// e si vede come una riga scura a mezza parete.
    @Test("Il capo pieno è il primo vertice, e sta sullo spigolo")
    func theCornerEndComesFirst() {
        let vertices = [CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200),
                        CGPoint(x: 700, y: 600), CGPoint(x: 200, y: 600)]
        let corners = vertices.map { SIMD2(Self.metres($0.x), Self.metres($0.y)) }
        var perCorner = [Int](repeating: 0, count: corners.count)

        for face in Self.strips(Self.rectangularRoom()) {
            // Il quadrilatero è [spigolo-basso, lontano-basso, lontano-alto,
            // spigolo-alto]: i due capi dello spigolo stanno in verticale.
            #expect(abs(face.points[0].x - face.points[3].x) < 0.0001)
            #expect(abs(face.points[0].y - face.points[3].y) < 0.0001)
            #expect(abs(face.points[1].x - face.points[2].x) < 0.0001)
            #expect(abs(face.points[1].y - face.points[2].y) < 0.0001)

            let near = Self.anchor(face)
            let far = SIMD2(face.points[1].x, face.points[1].y)
            guard let nearest = corners.indices.min(by: {
                simd_distance(corners[$0], near) < simd_distance(corners[$1], near)
            }) else { continue }

            // Il primo vertice è sullo spigolo — a meno del mezzo spessore del
            // muro — e il secondo se ne allontana.
            #expect(simd_distance(corners[nearest], near) < 0.30)
            #expect(simd_distance(corners[nearest], far)
                    > simd_distance(corners[nearest], near))
            perCorner[nearest] += 1
        }

        #expect(perCorner.allSatisfy { $0 == 2 })
    }

    /// Stessa ragione della fascia a terra: emessa sulla mediana del muro
    /// finirebbe murata dentro, e non si vedrebbe mai.
    @Test("Sta davanti al muro, non dentro")
    func cornerSitsInFrontOfTheWall() {
        let all = FloorplanExtruder.faces(from: Self.rectangularRoom())
        let sides = all.filter { $0.kind == .wallSide }
        let faces = all.filter { $0.kind == .wallCorner }
        #expect(!faces.isEmpty)

        for face in faces {
            // La distanza dal piano della facciata che la ospita: quattro
            // millimetri, non zero e non mezzo spessore.
            let distances = sides.compactMap { side -> Double? in
                guard let inward = side.inward else { return nil }
                let origin = SIMD2(side.points[0].x, side.points[0].y)
                let offset = simd_dot(Self.anchor(face) - origin, inward)
                return offset > 0 ? offset : nil
            }
            #expect(distances.contains { abs($0 - 0.004) < 0.0005 })
        }
    }
}
