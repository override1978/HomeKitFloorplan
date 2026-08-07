import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Da una vista dall'alto una tapparella messa **dentro** la stanza e una messa
/// fuori sono quasi identiche: entrambe coprono il vano, entrambe sembrano
/// giuste. È il tipo di errore che si spedisce.
@Suite("FloorplanExtruder — tapparelle")
struct FloorplanShutterTests {

    /// Stanza 5 × 4 m con una finestra al centro del muro nord (y = 2 m).
    /// La stanza sta **sotto** quel muro, quindi «fuori» è y minore.
    private static func room(shutter: Double?) -> (DrawingDocument, UUID) {
        var document = DrawingDocument()
        let corners = [CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200),
                       CGPoint(x: 700, y: 600), CGPoint(x: 200, y: 600)]
        var wallIDs: [UUID] = []
        for index in corners.indices {
            let wall = WallSegment(start: corners[index],
                                   end: corners[(index + 1) % corners.count],
                                   kind: .exterior)
            wallIDs.append(wall.id)
            document.walls.append(wall)
        }
        let window = PlacedOpening(wallID: wallIDs[0], t: 0.5, kind: .window, width: 120)
        document.openings = [window]
        document.roomAreas = [RoomArea(name: "Camera",
                                       rect: CGRect(x: 200, y: 200, width: 500, height: 400))]
        return (document, window.id)
    }

    private static func faces(shutter: Double?) -> ([FloorplanExtruder.Face], UUID) {
        let (document, openingID) = room(shutter: shutter)
        let closed = shutter.map { [openingID: $0] } ?? [:]
        return (FloorplanExtruder.faces(from: document, closedShutters: closed), openingID)
    }

    @Test("Senza tapparella non c'è nessuna lastra")
    func noShutterNoFace() {
        let (all, _) = Self.faces(shutter: nil)
        #expect(all.filter { $0.kind == .shutter }.isEmpty)
    }

    @Test("Tutta giù copre il vano intero, a metà ne copre metà")
    func dropIsProportional() {
        let (down, _) = Self.faces(shutter: 1)
        let (half, _) = Self.faces(shutter: 0.5)

        guard let full = down.first(where: { $0.kind == .shutter }),
              let middle = half.first(where: { $0.kind == .shutter })
        else { Issue.record("nessuna tapparella emessa"); return }

        // Il vano finestra va da 0,9 a 2,2 m: 1,3 m di luce.
        let fullDrop = (full.points.map(\.z).max() ?? 0) - (full.points.map(\.z).min() ?? 0)
        let halfDrop = (middle.points.map(\.z).max() ?? 0) - (middle.points.map(\.z).min() ?? 0)
        #expect(abs(fullDrop - 1.3) < 0.01)
        #expect(abs(halfDrop - fullDrop / 2) < 0.01)
        // Cala **dall'architrave**, non sale dal davanzale.
        #expect(abs((middle.points.map(\.z).max() ?? 0) - (full.points.map(\.z).max() ?? 0)) < 0.001)
    }

    /// Il muro nord sta a y = 2 m e la stanza si estende verso y crescenti:
    /// «fuori» è quindi y **minore** del muro. Una tapparella dentro la stanza
    /// dall'alto sembra identica, ed è per questo che serve un numero.
    @Test("Sta fuori dalla stanza, non dentro")
    func shutterIsOutside() {
        let (all, _) = Self.faces(shutter: 1)
        guard let shutter = all.first(where: { $0.kind == .shutter })
        else { Issue.record("nessuna tapparella emessa"); return }

        let y = shutter.points.map(\.y).reduce(0, +) / Double(shutter.points.count)
        #expect(y < 2.0)
    }

    @Test("Ogni faccia dell'apertura sa da quale apertura viene")
    func facesCarryTheOpeningID() {
        let (all, openingID) = Self.faces(shutter: 1)
        let glass = all.filter { $0.kind == .glass }
        #expect(!glass.isEmpty)
        #expect(glass.allSatisfy { $0.openingID == openingID })
        #expect(all.first { $0.kind == .shutter }?.openingID == openingID)
    }
}
