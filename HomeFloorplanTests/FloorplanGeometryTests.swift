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

    // I test dell'inscrizione passano `topInset: 0` per isolare l'aspect-fit dal
    // margine di chrome. Il margine ha il proprio test qui sotto.

    @Test("Immagine più larga del contenitore: fit in larghezza, centrata in verticale")
    func landscapeFitsWidth() {
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: CGSize(width: 200, height: 100),
            container: CGSize(width: 100, height: 100),
            topInset: 0
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
            container: CGSize(width: 100, height: 100),
            topInset: 0
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
            container: CGSize(width: 100, height: 100),
            topInset: 0
        )
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test("Il margine di chrome rimpicciolisce l'immagine e la spinge sotto la barra")
    func topInsetShrinksAndPushesDown() {
        // Contenitore 100×100, margine 20 → si inscrive in 100×80.
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: CGSize(width: 100, height: 100),
            container: CGSize(width: 100, height: 100),
            topInset: 20
        )
        #expect(rect.height == 80)
        #expect(rect.width == 80)
        #expect(rect.origin.y == 20)
        #expect(rect.origin.x == 10)
    }

    @Test("Senza argomento il margine di chrome è quello di default")
    func defaultAppliesChromeInset() {
        let container = CGSize(width: 400, height: 400)
        let size = CGSize(width: 100, height: 100)
        // Nessun chiamante passa il margine: lo eredita, ed è ciò che tiene
        // allineati renderer e risolutore dei tap senza doverlo ricordare.
        let implicit = FloorplanCanvasGeometry.imageRect(imageSize: size, container: container)
        let explicit = FloorplanCanvasGeometry.imageRect(
            imageSize: size,
            container: container,
            topInset: FloorplanCanvasGeometry.chromeTopInset
        )
        #expect(implicit == explicit)
        #expect(implicit.origin.y >= FloorplanCanvasGeometry.chromeTopInset)
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

    /// Contenitore ampio come uno schermo vero: con una fixture di 100×100 il
    /// margine di chrome schiaccerebbe l'immagine a una striscia e i test
    /// misurerebbero un caso degenere che sul device non esiste.
    private static let container = CGSize(width: 400, height: 400)
    private static let imageSize = CGSize(width: 100, height: 100)

    private func makeResolver(
        rooms: [LinkedRoom] = [],
        imageSize: CGSize = imageSize,
        container: CGSize = container,
        scale: CGFloat = 1,
        offset: CGSize = .zero
    ) -> FloorplanRoomTapResolver {
        FloorplanRoomTapResolver(
            linkedRooms: rooms,
            imageSize: imageSize,
            containerSize: container,
            effectiveScale: scale,
            effectiveOffset: offset
        )
    }

    /// Centro dell'immagine **ricavato dalla stessa funzione di geometria** che
    /// usa il risolutore, invece che scritto a mano.
    ///
    /// È il punto: `chromeTopInset` è un numero pensato per essere regolato a
    /// occhio, e dei test con coordinate cablate si romperebbero a ogni ritocco
    /// trasformando una regolazione estetica in una manutenzione di test. Così
    /// invece verificano la proprietà che conta davvero — un tap sul centro
    /// dell'immagine mappa al centro normalizzato — qualunque sia il margine.
    private func imageCentre(imageSize: CGSize = imageSize,
                             container: CGSize = container) -> CGPoint {
        let rect = FloorplanCanvasGeometry.imageRect(imageSize: imageSize, container: container)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test("Scala 1, nessun offset: il tap al centro dell'immagine mappa a (0.5, 0.5)")
    func identityTransform() {
        let result = makeResolver().resolve(tapLocation: imageCentre())
        #expect(result != nil)
        #expect(abs((result?.markerPosition.x ?? -1) - 0.5) < 1e-9)
        #expect(abs((result?.markerPosition.y ?? -1) - 0.5) < 1e-9)
        #expect(result?.roomID == nil) // nessuna stanza fornita
    }

    @Test("Tap fuori dall'immagine restituisce nil")
    func outOfBoundsReturnsNil() {
        // Immagine verticale: lascia due bande vuote ai lati. Il tap cade a
        // sinistra del bordo sinistro, qualunque sia il margine superiore.
        let imageSize = CGSize(width: 50, height: 100)
        let rect = FloorplanCanvasGeometry.imageRect(imageSize: imageSize, container: Self.container)
        let resolver = makeResolver(imageSize: imageSize)
        let outside = CGPoint(x: rect.minX - 10, y: rect.midY)
        #expect(resolver.resolve(tapLocation: outside) == nil)
    }

    /// Sostituisce il vecchio `topBarShiftsVerticalMapping`: l'altezza della top
    /// bar non entra più nella mappatura — la planimetria è centrata nel canvas
    /// intero e scorre sotto la chrome, che le è sovrapposta. Resta però da
    /// coprire la matematica verticale, che ora dipende dal solo offset di
    /// scorrimento: è lo stesso termine che l'immagine applica, e i due devono
    /// continuare ad annullarsi.
    @Test("L'offset verticale sposta la mappatura del tap")
    func verticalOffsetShiftsMapping() {
        // L'immagine è scesa di 20: per colpirne il centro il tap deve scendere
        // di altrettanto. È la cancellazione dei due termini, verificata senza
        // dipendere da dove si trovi il centro.
        let shift: CGFloat = 20
        let resolver = makeResolver(offset: CGSize(width: 0, height: shift))
        let centre = imageCentre()
        let result = resolver.resolve(
            tapLocation: CGPoint(x: centre.x, y: centre.y + shift)
        )
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
        let result = makeResolver(rooms: [room]).resolve(tapLocation: imageCentre())
        #expect(result?.roomID == roomID)
    }
}
