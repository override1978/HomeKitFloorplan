import Foundation
import Testing
@testable import HomeFloorplan

/// Test della matematica pura di rimappatura marker estratta da
/// `FloorplanMarkerEditingCoordinator.preserveMarkerPositions`.
/// Tutto il containment è polygon-aware via `FloorplanRoomMatcher`, incluso il
/// fallback sulla stanza precedente per marker senza `linkedRoomUUID`.
@Suite("FloorplanMarkerRemapper — rototraslazione marker su cambio stanze")
struct FloorplanMarkerRemapperTests {

    private func room(_ id: UUID,
                      _ rect: CodableRect,
                      points: [CodablePoint]? = nil,
                      name: String = "Room") -> LinkedRoom {
        LinkedRoom(hmRoomUUID: id, name: name, normalizedRect: rect, normalizedPoints: points)
    }

    // MARK: - rotatedLocalPoint (core error-prone)

    @Test("rotatedLocalPoint: 0 quarti è l'identità")
    func rotationIdentity() {
        let p = FloorplanMarkerRemapper.rotatedLocalPoint(x: 0.2, y: 0.7, quarterTurns: 0)
        #expect(p.x == 0.2)
        #expect(p.y == 0.7)
    }

    @Test("rotatedLocalPoint: 1 quarto orario = (1 - y, x)")
    func rotationClockwise() {
        let p = FloorplanMarkerRemapper.rotatedLocalPoint(x: 0.2, y: 0.1, quarterTurns: 1)
        #expect(abs(p.x - 0.9) < 1e-12)
        #expect(abs(p.y - 0.2) < 1e-12)
    }

    @Test("rotatedLocalPoint: 2 quarti = (1 - x, 1 - y)")
    func rotationUpsideDown() {
        let p = FloorplanMarkerRemapper.rotatedLocalPoint(x: 0.2, y: 0.1, quarterTurns: 2)
        #expect(abs(p.x - 0.8) < 1e-12)
        #expect(abs(p.y - 0.9) < 1e-12)
    }

    @Test("rotatedLocalPoint: 3 quarti = (y, 1 - x)")
    func rotationCounterClockwise() {
        let p = FloorplanMarkerRemapper.rotatedLocalPoint(x: 0.2, y: 0.1, quarterTurns: 3)
        #expect(abs(p.x - 0.1) < 1e-12)
        #expect(abs(p.y - 0.8) < 1e-12)
    }

    // MARK: - Guardie: input che lasciano i marker invariati

    @Test("Nessuna stanza precedente: placements invariati")
    func emptyPreviousRoomsIsNoop() {
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.3, positionY: 0.4, linkedRoomUUID: UUID())]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [],
            newRooms: [room(UUID(), CodableRect(x: 0, y: 0, width: 1, height: 1))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out == placements)
    }

    @Test("Nessuna stanza nuova: placements invariati")
    func emptyNewRoomsIsNoop() {
        let id = UUID()
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.3, positionY: 0.4, linkedRoomUUID: id)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(id, CodableRect(x: 0, y: 0, width: 1, height: 1))],
            newRooms: [],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out == placements)
    }

    @Test("Marker senza room e fuori da ogni rettangolo: invariato")
    func unmatchedMarkerStaysPut() {
        let a = UUID()
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.95, positionY: 0.95, linkedRoomUUID: nil)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 0.2, height: 0.2))],
            newRooms: [room(a, CodableRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out == placements)
    }

    @Test("Larghezza rettangolo precedente nulla: invariato")
    func zeroWidthPreviousRectIsNoop() {
        let a = UUID()
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.1, positionY: 0.1, linkedRoomUUID: a)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 0, height: 0.5))],
            newRooms: [room(a, CodableRect(x: 0, y: 0, width: 1, height: 1))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out == placements)
    }

    // MARK: - Remap posizionale

    @Test("Senza rotazione, la stanza si sposta: il marker mantiene la posizione relativa")
    func relativePositionPreservedOnTranslation() {
        let a = UUID()
        // marker a (0.25,0.25) in rect (0,0,0.5,0.5) → local (0.5,0.5)
        // nuovo rect (0.5,0.5,0.5,0.5) → nuova pos (0.75,0.75)
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.25, positionY: 0.25, linkedRoomUUID: a)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 0.5, height: 0.5))],
            newRooms: [room(a, CodableRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(abs(out[0].positionX - 0.75) < 1e-12)
        #expect(abs(out[0].positionY - 0.75) < 1e-12)
        #expect(out[0].linkedRoomUUID == a)
    }

    @Test("Rotazione oraria di un quarto ruota la posizione locale del marker")
    func clockwiseRotationRemap() {
        let a = UUID()
        // rect identità (0,0,1,1) → local == pos. marker (0.2,0.1), delta=1 → (0.9,0.2)
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.2, positionY: 0.1, linkedRoomUUID: a)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 1, height: 1))],
            newRooms: [room(a, CodableRect(x: 0, y: 0, width: 1, height: 1))],
            previousRotation: .asDrawn,
            newRotation: .clockwise
        )
        #expect(abs(out[0].positionX - 0.9) < 1e-12)
        #expect(abs(out[0].positionY - 0.2) < 1e-12)
    }

    @Test("Marker con linkedRoomUUID nil usa il containment sulla stanza precedente")
    func nilLinkFallsBackToContainment() {
        let a = UUID()
        // marker (0.1,0.1) senza link → cade nel rect precedente (0,0,0.5,0.5) di 'a'
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.1, positionY: 0.1, linkedRoomUUID: nil)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 0.5, height: 0.5))],
            newRooms: [room(a, CodableRect(x: 0, y: 0, width: 1, height: 1))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        // local (0.2,0.2) in nuovo rect (0,0,1,1) → (0.2,0.2), link assegnato ad 'a'
        #expect(abs(out[0].positionX - 0.2) < 1e-12)
        #expect(abs(out[0].positionY - 0.2) < 1e-12)
        #expect(out[0].linkedRoomUUID == a)
    }

    @Test("Marker senza link dentro il poligono di una stanza a L viene rimappato")
    func nilLinkInsidePolygonIsRemapped() {
        let a = UUID()
        // Stanza a L: quadrato (0,0)-(0.4,0.4) meno la tacca in alto a destra.
        let lShape = [
            CodablePoint(x: 0.0, y: 0.0),
            CodablePoint(x: 0.2, y: 0.0),
            CodablePoint(x: 0.2, y: 0.2),
            CodablePoint(x: 0.4, y: 0.2),
            CodablePoint(x: 0.4, y: 0.4),
            CodablePoint(x: 0.0, y: 0.4)
        ]
        let bounding = CodableRect(x: 0, y: 0, width: 0.4, height: 0.4)
        // (0.1, 0.1) è dentro il braccio verticale della L.
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.1, positionY: 0.1, linkedRoomUUID: nil)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, bounding, points: lShape)],
            newRooms: [room(a, CodableRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), points: nil)],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        // local (0.25, 0.25) rispetto al bounding rect → nuova pos (0.6, 0.6).
        #expect(abs(out[0].positionX - 0.6) < 1e-12)
        #expect(abs(out[0].positionY - 0.6) < 1e-12)
    }

    @Test("Marker senza link nella tacca di una stanza a L NON viene catturato dal suo bounding rect")
    func nilLinkInPolygonNotchStaysPut() {
        let a = UUID()
        // Stessa L di cui sopra: la tacca (0.2,0)-(0.4,0.2) è fuori dal poligono
        // ma dentro il bounding rect. Il vecchio fallback rect-only catturava
        // erroneamente il marker; ora deve restare invariato.
        let lShape = [
            CodablePoint(x: 0.0, y: 0.0),
            CodablePoint(x: 0.2, y: 0.0),
            CodablePoint(x: 0.2, y: 0.2),
            CodablePoint(x: 0.4, y: 0.2),
            CodablePoint(x: 0.4, y: 0.4),
            CodablePoint(x: 0.0, y: 0.4)
        ]
        let bounding = CodableRect(x: 0, y: 0, width: 0.4, height: 0.4)
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.3, positionY: 0.1, linkedRoomUUID: nil)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, bounding, points: lShape)],
            newRooms: [room(a, CodableRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), points: nil)],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out == placements)
    }

    @Test("Il risultato è clampato a [0, 1]")
    func resultIsClamped() {
        let a = UUID()
        // marker (0.9,0.9) local (0.9,0.9) in rect precedente (0,0,1,1);
        // nuovo rect (0.5,0.5,1,1) → 0.5+0.9*1 = 1.4 → clamp a 1
        let placements = [FloorplanMarkerRemapper.Placement(positionX: 0.9, positionY: 0.9, linkedRoomUUID: a)]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 1, height: 1))],
            newRooms: [room(a, CodableRect(x: 0.5, y: 0.5, width: 1, height: 1))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out[0].positionX == 1)
        #expect(out[0].positionY == 1)
    }

    @Test("L'ordine e la lunghezza dell'array sono preservati")
    func orderAndCountPreserved() {
        let a = UUID()
        let b = UUID()
        let placements = [
            FloorplanMarkerRemapper.Placement(positionX: 0.1, positionY: 0.1, linkedRoomUUID: a),
            FloorplanMarkerRemapper.Placement(positionX: 0.9, positionY: 0.9, linkedRoomUUID: b)
        ]
        let out = FloorplanMarkerRemapper.remap(
            placements: placements,
            previousRooms: [room(a, CodableRect(x: 0, y: 0, width: 0.5, height: 0.5))],
            newRooms: [room(a, CodableRect(x: 0, y: 0, width: 0.5, height: 0.5))],
            previousRotation: .asDrawn,
            newRotation: .asDrawn
        )
        #expect(out.count == 2)
        // Il secondo marker (room 'b' assente dalle mappe) resta invariato.
        #expect(out[1] == placements[1])
    }
}
