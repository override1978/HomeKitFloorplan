import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Characterization test della geometria condivisa del floorplan.
/// Bloccano il comportamento ATTUALE di `FloorplanCanvasGeometry`,
/// `FloorplanCoordinateHelper` e `FloorplanRoomTapResolver` prima di
/// deduplicare l'algoritmo di aspect-fit (C2) e memoizzare i path caldi (C3).
@Suite("FloorplanCanvasGeometry — aspect-fit imageRect")
struct FloorplanCanvasGeometryTests {

    @Test("Immagine più larga del contenitore: fit in larghezza, centrata in verticale")
    func landscapeFitsWidth() {
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: CGSize(width: 200, height: 100),
            container: CGSize(width: 100, height: 100)
        )
        #expect(rect.origin.x == 0)
        #expect(rect.origin.y == 25)
        #expect(rect.width == 100)
        #expect(rect.height == 50)
    }

    @Test("Immagine più alta del contenitore: fit in altezza, centrata in orizzontale")
    func portraitFitsHeight() {
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: CGSize(width: 100, height: 200),
            container: CGSize(width: 100, height: 100)
        )
        #expect(rect.origin.x == 25)
        #expect(rect.origin.y == 0)
        #expect(rect.width == 50)
        #expect(rect.height == 100)
    }

    @Test("Immagine quadrata in contenitore quadrato: riempie tutto")
    func squareFillsContainer() {
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: CGSize(width: 100, height: 100),
            container: CGSize(width: 100, height: 100)
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }
}

@Suite("FloorplanCoordinateHelper — conversioni normalizzate ↔ schermo")
struct FloorplanCoordinateHelperTests {

    private let imageRect = CGRect(x: 10, y: 20, width: 100, height: 200)

    @Test("screenPoint mappa il punto normalizzato dentro imageRect")
    func screenPointFromNormalizedPoint() {
        let helper = FloorplanCoordinateHelper(imageRect: imageRect)
        let p = helper.screenPoint(from: NormalizedPoint(x: 0.5, y: 0.5))
        #expect(p.x == 60)
        #expect(p.y == 120)
    }

    @Test("screenRect scala origine e dimensioni nello spazio schermo")
    func screenRectScalesRect() {
        let helper = FloorplanCoordinateHelper(imageRect: imageRect)
        let r = helper.screenRect(from: CodableRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25))
        #expect(r.origin.x == 20)      // 10 + 0.1*100
        #expect(r.origin.y == 60)      // 20 + 0.2*200
        #expect(r.width == 50)         // 0.5*100
        #expect(r.height == 50)        // 0.25*200
    }

    @Test("centroid di una stanza a rettangolo è il centro del rect")
    func centroidRectRoom() {
        let helper = FloorplanCoordinateHelper(imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let room = LinkedRoom(
            hmRoomUUID: UUID(),
            name: "Salotto",
            normalizedRect: CodableRect(x: 0, y: 0, width: 0.5, height: 0.5),
            normalizedPoints: nil
        )
        let c = helper.centroid(for: room)
        #expect(c.x == 25)
        #expect(c.y == 25)
    }

    @Test("centroid di una stanza a poligono è la media dei vertici")
    func centroidPolygonRoom() {
        let helper = FloorplanCoordinateHelper(imageRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let room = LinkedRoom(
            hmRoomUUID: UUID(),
            name: "Cucina",
            normalizedRect: CodableRect(x: 0, y: 0, width: 1, height: 1),
            normalizedPoints: [
                CodablePoint(x: 0, y: 0),
                CodablePoint(x: 0.4, y: 0),
                CodablePoint(x: 0.4, y: 0.4),
                CodablePoint(x: 0, y: 0.4)
            ]
        )
        let c = helper.centroid(for: room)
        #expect(abs(c.x - 20) < 1e-9)  // media x = 0.2 → 20
        #expect(abs(c.y - 20) < 1e-9)  // media y = 0.2 → 20
    }

    /// Guardia di regressione per la dedup di C2: la factory `make` deve
    /// restituire lo stesso rect di `FloorplanCanvasGeometry.imageRect`.
    @Test("make() coincide con FloorplanCanvasGeometry.imageRect (contratto single-source)")
    func makeMatchesCanvasGeometry() {
        let cases: [(CGSize, CGSize)] = [
            (CGSize(width: 200, height: 100), CGSize(width: 100, height: 100)),
            (CGSize(width: 100, height: 200), CGSize(width: 100, height: 100)),
            (CGSize(width: 100, height: 100), CGSize(width: 320, height: 480)),
            (CGSize(width: 1024, height: 768), CGSize(width: 390, height: 844))
        ]
        for (imageSize, container) in cases {
            let viaHelper = FloorplanCoordinateHelper.make(imageSize: imageSize, container: container).imageRect
            let viaGeometry = FloorplanCanvasGeometry.imageRect(imageSize: imageSize, container: container)
            #expect(viaHelper == viaGeometry, "Mismatch per image=\(imageSize) container=\(container)")
        }
    }
}

@Suite("FloorplanRoomTapResolver — tap schermo → coordinate normalizzate")
struct FloorplanRoomTapResolverTests {

    private func makeResolver(
        rooms: [LinkedRoom] = [],
        imageSize: CGSize = CGSize(width: 100, height: 100),
        container: CGSize = CGSize(width: 100, height: 100),
        scale: CGFloat = 1,
        offset: CGSize = .zero,
        topBar: CGFloat = 0
    ) -> FloorplanRoomTapResolver {
        FloorplanRoomTapResolver(
            linkedRooms: rooms,
            imageSize: imageSize,
            containerSize: container,
            effectiveScale: scale,
            effectiveOffset: offset,
            topBarHeight: topBar
        )
    }

    @Test("Scala 1, nessun offset: il tap al centro mappa a (0.5, 0.5)")
    func identityTransform() {
        let result = makeResolver().resolve(tapLocation: CGPoint(x: 50, y: 50))
        #expect(result != nil)
        #expect(abs((result?.markerPosition.x ?? -1) - 0.5) < 1e-9)
        #expect(abs((result?.markerPosition.y ?? -1) - 0.5) < 1e-9)
        #expect(result?.roomID == nil) // nessuna stanza fornita
    }

    @Test("Tap fuori dall'immagine restituisce nil")
    func outOfBoundsReturnsNil() {
        // Immagine verticale: imageRect = (25, 0, 50, 100); x=10 cade nella banda vuota.
        let resolver = makeResolver(imageSize: CGSize(width: 50, height: 100))
        #expect(resolver.resolve(tapLocation: CGPoint(x: 10, y: 50)) == nil)
    }

    @Test("La topBar sposta la mappatura verticale del tap")
    func topBarShiftsVerticalMapping() {
        // visualYOffset = offset.height + topBar/2 = 0 + 20 = 20.
        // adjustedY = (tapY - 50 - 20)/1 + 50 = tapY - 20 → tap a y=70 mappa al centro.
        let resolver = makeResolver(topBar: 40)
        let result = resolver.resolve(tapLocation: CGPoint(x: 50, y: 70))
        #expect(result != nil)
        #expect(abs((result?.markerPosition.y ?? -1) - 0.5) < 1e-9)
    }

    @Test("Con una stanza che copre l'immagine, il tap ne restituisce l'ID")
    func tapHitsRoom() {
        let roomID = UUID()
        let room = LinkedRoom(
            hmRoomUUID: roomID,
            name: "Studio",
            normalizedRect: CodableRect(x: 0, y: 0, width: 1, height: 1),
            normalizedPoints: nil
        )
        let result = makeResolver(rooms: [room]).resolve(tapLocation: CGPoint(x: 50, y: 50))
        #expect(result?.roomID == roomID)
    }
}
