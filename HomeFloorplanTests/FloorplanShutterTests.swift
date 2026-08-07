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

    /// Il caso che ha fatto trovare il bug: una portafinestra su un balcone ha
    /// una stanza **da tutte e due le parti**, perché il balcone è un'area come
    /// le altre. Fermandosi al primo controllo la tapparella finiva dentro il
    /// soggiorno.
    @Test("Su una portafinestra verso il balcone la copertura sta sul balcone")
    func coveringGoesToTheBalconySide() {
        var document = DrawingDocument()
        // Soggiorno da y = 2 a y = 6; balcone da y = 0 a y = 2, chiuso da parapetti.
        let shared = WallSegment(start: CGPoint(x: 200, y: 200),
                                 end: CGPoint(x: 700, y: 200), kind: .exterior)
        document.walls = [
            shared,
            WallSegment(start: CGPoint(x: 700, y: 200), end: CGPoint(x: 700, y: 600), kind: .exterior),
            WallSegment(start: CGPoint(x: 700, y: 600), end: CGPoint(x: 200, y: 600), kind: .exterior),
            WallSegment(start: CGPoint(x: 200, y: 600), end: CGPoint(x: 200, y: 200), kind: .exterior),
            WallSegment(start: CGPoint(x: 200, y: 200), end: CGPoint(x: 200, y: 0), kind: .balcony),
            WallSegment(start: CGPoint(x: 200, y: 0), end: CGPoint(x: 700, y: 0), kind: .balcony),
            WallSegment(start: CGPoint(x: 700, y: 0), end: CGPoint(x: 700, y: 200), kind: .balcony)
        ]
        let door = PlacedOpening(wallID: shared.id, t: 0.5, kind: .frenchDoor, width: 120)
        document.openings = [door]
        document.roomAreas = [
            RoomArea(name: "Soggiorno", rect: CGRect(x: 200, y: 200, width: 500, height: 400)),
            RoomArea(name: "Balcone", rect: CGRect(x: 200, y: 0, width: 500, height: 200))
        ]

        let balconies = FloorplanExtruder.balconyAreaIDs(in: document)
        #expect(balconies.count == 1)

        let faces = FloorplanExtruder.faces(from: document, closedShutters: [door.id: 1])
        guard let shutter = faces.first(where: { $0.kind == .shutter })
        else { Issue.record("nessuna copertura emessa"); return }

        // Il muro condiviso sta a y = 2: il balcone è sotto, il soggiorno sopra.
        let y = shutter.points.map(\.y).reduce(0, +) / Double(shutter.points.count)
        #expect(y < 2.0)
    }

    @Test("Una tenda stesa compare sopra il balcone, attaccata al lato di casa")
    func awningHangsFromTheHouseSide() {
        var document = DrawingDocument()
        let shared = WallSegment(start: CGPoint(x: 200, y: 200),
                                 end: CGPoint(x: 700, y: 200), kind: .exterior)
        document.walls = [
            shared,
            WallSegment(start: CGPoint(x: 700, y: 200), end: CGPoint(x: 700, y: 600), kind: .exterior),
            WallSegment(start: CGPoint(x: 700, y: 600), end: CGPoint(x: 200, y: 600), kind: .exterior),
            WallSegment(start: CGPoint(x: 200, y: 600), end: CGPoint(x: 200, y: 200), kind: .exterior),
            WallSegment(start: CGPoint(x: 200, y: 200), end: CGPoint(x: 200, y: 0), kind: .balcony),
            WallSegment(start: CGPoint(x: 200, y: 0), end: CGPoint(x: 700, y: 0), kind: .balcony),
            WallSegment(start: CGPoint(x: 700, y: 0), end: CGPoint(x: 700, y: 200), kind: .balcony)
        ]
        let balcony = RoomArea(name: "Balcone", rect: CGRect(x: 200, y: 0, width: 500, height: 200))
        document.roomAreas = [
            RoomArea(name: "Soggiorno", rect: CGRect(x: 200, y: 200, width: 500, height: 400)),
            balcony
        ]

        let ritirata = FloorplanExtruder.faces(from: document, extendedAwnings: [balcony.id: 0])
        #expect(ritirata.filter { $0.kind == .awning }.isEmpty)

        let stesa = FloorplanExtruder.faces(from: document, extendedAwnings: [balcony.id: 1])
        guard let awning = stesa.first(where: { $0.kind == .awning })
        else { Issue.record("nessuna tenda emessa"); return }

        // Attaccata al lato di casa (y = 2) e in discesa verso il vuoto (y < 2).
        let heights = awning.points.map(\.z)
        #expect((heights.max() ?? 0) > (heights.min() ?? 0))
        #expect(abs((awning.points.map(\.y).max() ?? 0) - 2.0) < 0.01)
        #expect((awning.points.map(\.y).min() ?? 9) < 2.0)
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
