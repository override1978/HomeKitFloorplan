import Testing
import SwiftUI
@testable import HomeFloorplan

/// Il bagliore che nasce dalle stanze accese.
///
/// È ciò che resta della luce circadiana: il fondo che seguiva il sole, le
/// superfici che ne ereditavano la temperatura e il sole dal balcone sono stati
/// tolti. Le prove che restano sono quelle della parte che valeva.
@Suite("Le luci delle stanze")
struct RoomLightGlowTests {

    @Test("Su fondo chiaro non si disegna niente")
    func nothingOnLightGround() {
        // Un alone caldo su una superficie chiara non si vede, e disegnarlo
        // significa pagare un gradiente per niente. Prima la condizione era la
        // quantità di luce del giorno, calcolata da una curva solare: ma la
        // ragione vera non era l'ora, era il fondo — e il fondo lo sa di sé.
        #expect(RoomLightGlow.lamps(byRoom: [[.center]], onDarkGround: false).isEmpty)
        #expect(RoomLightGlow.lamps(byRoom: [[.center]], onDarkGround: true).isEmpty == false)
    }

    @Test("Due stanze accese fanno due pozze, non una in mezzo")
    func twoRoomsMakeTwoPools() {
        // Con un solo bagliore al baricentro, soggiorno e cucina accesi
        // producevano un alone nel corridoio fra i due, dove non è acceso
        // niente.
        let glows = RoomLightGlow.lamps(byRoom: [[UnitPoint(x: 0.2, y: 0.5)],
                                                 [UnitPoint(x: 0.8, y: 0.5)]],
                                        onDarkGround: true)
        #expect(glows.count == 2)
        #expect(glows.allSatisfy { abs($0.centre.x - 0.5) > 0.2 },
                "nessuna pozza dove non c'è nessuna lampada")
    }

    @Test("Dentro una stanza le lampade si mediano")
    func lampsWithinARoomAverage() throws {
        let glow = try #require(RoomLightGlow.lamps(byRoom: [[UnitPoint(x: 0.2, y: 0.5),
                                                              UnitPoint(x: 0.4, y: 0.5)]],
                                                    onDarkGround: true).first)
        #expect(abs(glow.centre.x - 0.3) < 0.01)
    }

    @Test("Più luci in una stanza, più bagliore — ma non all'infinito")
    func moreLampsSaturate() throws {
        func intensity(_ count: Int) throws -> Double {
            let points = (0..<count).map { _ in UnitPoint.center }
            return try #require(RoomLightGlow.lamps(byRoom: [points], onDarkGround: true).first).intensity
        }
        #expect(try intensity(1) < intensity(3))
        #expect(try abs(intensity(3) - intensity(9)) < 0.001)
    }

    @Test("Nessuna luce accesa, nessun bagliore")
    func noLampsNoGlow() {
        #expect(RoomLightGlow.lamps(byRoom: [], onDarkGround: true).isEmpty)
        #expect(RoomLightGlow.lamps(byRoom: [[]], onDarkGround: true).isEmpty)
    }

    @Test("Una lampada illumina una stanza, non un piano")
    func lampsStayTight() throws {
        // Una luce larga metà schermo non somiglia a una lampada: somiglia a
        // una vignettatura, ed è quella che va a sbattere contro i bordi.
        let lamp = try #require(RoomLightGlow.lamps(byRoom: [[.center]], onDarkGround: true).first)
        #expect(lamp.radius < 0.25)
    }
}

@Suite("Dove cade il bagliore")
struct GlowPlacementTests {

    private func glow(_ x: CGFloat, _ y: CGFloat) -> RoomLightGlow {
        RoomLightGlow(centre: UnitPoint(x: x, y: y), intensity: 0.3, radius: 0.2, color: .orange)
    }

    @Test("Il centro dell'immagine resta il centro dell'immagine")
    func imageCentreMapsToImageCentre() {
        // La planimetria occupa la metà destra di una superficie larga il
        // doppio: il suo centro cade a tre quarti dello schermo.
        let rect = CGRect(x: 100, y: 0, width: 100, height: 100)
        let point = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: rect,
                             container: CGSize(width: 200, height: 100))
        #expect(abs(point.x - 0.75) < 0.001)
        #expect(abs(point.y - 0.5) < 0.001)
    }

    @Test("Un angolo della planimetria resta quell'angolo")
    func cornersMapToCorners() {
        let rect = CGRect(x: 50, y: 20, width: 100, height: 60)
        let container = CGSize(width: 200, height: 100)
        let topLeft = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0, 0), imageRect: rect, container: container)
        #expect(abs(topLeft.x - 0.25) < 0.001)
        #expect(abs(topLeft.y - 0.20) < 0.001)
    }

    @Test("La sorgente non scivola quando l'immagine cambia misura")
    func sourceDoesNotDriftWithImageSize() {
        // È la ragione per cui la conversione esiste: il balcone sta dove sta
        // sulla planimetria, non dove capita sullo schermo.
        let container = CGSize(width: 400, height: 300)
        let small = CGRect(x: 100, y: 75, width: 200, height: 150)
        let large = CGRect(x: 0, y: 0, width: 400, height: 300)
        let a = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: small, container: container)
        let b = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: large, container: container)
        #expect(abs(a.x - b.x) < 0.001, "il centro della planimetria è lo stesso punto")
    }

    @Test("Una superficie degenere non produce coordinate assurde")
    func degenerateContainerIsSafe() {
        let point = FloorplanCanvasView<EmptyView, EmptyView, EmptyView, EmptyView, EmptyView>
            .containerCentre(of: glow(0.5, 0.5), imageRect: .zero, container: .zero)
        #expect(point == .center)
    }
}
