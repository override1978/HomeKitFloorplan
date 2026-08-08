import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Il «tocca dentro la stanza e l'area si fa da sola» vive o muore qui: se il
/// tracciatore sbaglia faccia, l'utente collega la stanza HomeKit al corridoio.
@Suite("RoomShapeTracer — dal tocco al poligono")
struct RoomShapeTracerTests {

    private func wall(_ a: CGPoint, _ b: CGPoint) -> WallSegment {
        WallSegment(start: a, end: b, kind: .exterior)
    }

    /// Quattro muri, una stanza: il poligono deve essere il rettangolo, con
    /// quattro vertici e nessuna maniglia in più.
    @Test("Stanza rettangolare: quattro vertici esatti")
    func simpleRectangle() {
        let walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
            wall(CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 400)),
            wall(CGPoint(x: 500, y: 400), CGPoint(x: 100, y: 400)),
            wall(CGPoint(x: 100, y: 400), CGPoint(x: 100, y: 100))
        ]
        guard let polygon = RoomShapeTracer.roomPolygon(containing: CGPoint(x: 300, y: 250),
                                                        walls: walls)
        else { Issue.record("nessun poligono"); return }
        #expect(polygon.count == 4)
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        #expect(abs((xs.min() ?? 0) - 100) < 1 && abs((xs.max() ?? 0) - 500) < 1)
        #expect(abs((ys.min() ?? 0) - 100) < 1 && abs((ys.max() ?? 0) - 400) < 1)
    }

    @Test("Fuori da ogni stanza: niente poligono")
    func outsideGivesNil() {
        let walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
            wall(CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 400)),
            wall(CGPoint(x: 500, y: 400), CGPoint(x: 100, y: 400)),
            wall(CGPoint(x: 100, y: 400), CGPoint(x: 100, y: 100))
        ]
        #expect(RoomShapeTracer.roomPolygon(containing: CGPoint(x: 700, y: 250),
                                            walls: walls) == nil)
    }

    @Test("Stanza aperta (manca un muro): niente poligono")
    func openRoomGivesNil() {
        let walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
            wall(CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 400)),
            wall(CGPoint(x: 500, y: 400), CGPoint(x: 100, y: 400))
        ]
        #expect(RoomShapeTracer.roomPolygon(containing: CGPoint(x: 300, y: 250),
                                            walls: walls) == nil)
    }

    /// Il caso vero: un tramezzo a T divide la casa in due stanze. Il tocco in
    /// una metà deve dare quella metà, non la casa intera — e il vertice a T
    /// sul perimetro non deve lasciare una maniglia inutile.
    @Test("Tramezzo a T: il tocco prende la stanza giusta, non la casa")
    func partitionPicksTheRoom() {
        let walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 700, y: 100)),
            wall(CGPoint(x: 700, y: 100), CGPoint(x: 700, y: 500)),
            wall(CGPoint(x: 700, y: 500), CGPoint(x: 100, y: 500)),
            wall(CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 100)),
            // tramezzo verticale che tocca sopra e sotto a metà
            wall(CGPoint(x: 400, y: 100), CGPoint(x: 400, y: 500))
        ]
        guard let left = RoomShapeTracer.roomPolygon(containing: CGPoint(x: 200, y: 300),
                                                     walls: walls),
              let right = RoomShapeTracer.roomPolygon(containing: CGPoint(x: 600, y: 300),
                                                      walls: walls)
        else { Issue.record("una delle due stanze non è stata trovata"); return }

        let leftXs = left.map(\.x)
        let rightXs = right.map(\.x)
        #expect((leftXs.max() ?? 0) < 401)
        #expect((rightXs.min() ?? 999) > 399)
        // Metà casa: 300×400. La casa intera sarebbe 600×400.
        #expect(left.count == 4 && right.count == 4)
    }

    /// Una stanza a L (cucina vera): il poligono deve seguire il rientro,
    /// sei vertici, non il bounding box.
    @Test("Stanza a L: sei vertici, non il rettangolo di ingombro")
    func lShapedRoom() {
        let walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
            wall(CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 300)),
            wall(CGPoint(x: 500, y: 300), CGPoint(x: 300, y: 300)),
            wall(CGPoint(x: 300, y: 300), CGPoint(x: 300, y: 500)),
            wall(CGPoint(x: 300, y: 500), CGPoint(x: 100, y: 500)),
            wall(CGPoint(x: 100, y: 500), CGPoint(x: 100, y: 100))
        ]
        guard let polygon = RoomShapeTracer.roomPolygon(containing: CGPoint(x: 200, y: 200),
                                                        walls: walls)
        else { Issue.record("nessun poligono"); return }
        #expect(polygon.count == 6)
        // Il punto nel rientro (fuori dalla L) non appartiene alla stanza.
        #expect(RoomShapeTracer.roomPolygon(containing: CGPoint(x: 450, y: 450),
                                            walls: walls) == nil)
    }

    /// Un muro monco che entra nella stanza (sperone) non deve né rompere il
    /// tracciato né lasciare vertici doppi.
    @Test("Sperone dentro la stanza: ignorato")
    func stubWallIsAbsorbed() {
        let walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
            wall(CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 400)),
            wall(CGPoint(x: 500, y: 400), CGPoint(x: 100, y: 400)),
            wall(CGPoint(x: 100, y: 400), CGPoint(x: 100, y: 100)),
            // sperone: parte dal muro nord e muore a metà stanza
            wall(CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 220))
        ]
        guard let polygon = RoomShapeTracer.roomPolygon(containing: CGPoint(x: 200, y: 300),
                                                        walls: walls)
        else { Issue.record("nessun poligono"); return }
        // Lo sperone non aggiunge area: il perimetro utile resta il rettangolo.
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        #expect(abs((xs.max() ?? 0) - (xs.min() ?? 0) - 400) < 2)
        #expect(abs((ys.max() ?? 0) - (ys.min() ?? 0) - 300) < 2)
    }
}
