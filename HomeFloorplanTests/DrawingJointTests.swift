import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Il «ginocchio»: trascinando un estremo, gli estremi coincidenti degli altri
/// muri devono muoversi insieme. Qui si testa il pezzo puro — chi fa parte
/// della giunzione — perché se questa lista sbaglia, l'angolo si apre o si
/// porta dietro muri che non c'entrano.
@Suite("DrawingDocument.jointEndpoints — chi si piega col ginocchio")
struct DrawingJointTests {

    private func wall(_ a: CGPoint, _ b: CGPoint, kind: WallKind = .exterior) -> WallSegment {
        WallSegment(start: a, end: b, kind: kind)
    }

    /// Angolo a L: l'estremo condiviso deve restituire l'altro muro, con
    /// l'indice giusto (0 = start), e il muro trascinato escluso.
    @Test("Angolo a L: un compagno, indice corretto")
    func cornerJoint() {
        let a = wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100))
        let b = wall(CGPoint(x: 500, y: 100), CGPoint(x: 500, y: 400))
        var doc = DrawingDocument()
        doc.walls = [a, b]

        let joints = doc.jointEndpoints(at: a.end, excluding: a.id)
        #expect(joints.count == 1)
        #expect(joints.first?.wallID == b.id)
        #expect(joints.first?.endpointIndex == 0)
    }

    /// Giunzione a T: tre muri sullo stesso vertice → due compagni.
    @Test("Giunzione a T: due compagni")
    func teeJoint() {
        let hub = CGPoint(x: 300, y: 300)
        let a = wall(CGPoint(x: 100, y: 300), hub)
        let b = wall(hub, CGPoint(x: 500, y: 300))
        let c = wall(hub, CGPoint(x: 300, y: 500))
        var doc = DrawingDocument()
        doc.walls = [a, b, c]

        let joints = doc.jointEndpoints(at: hub, excluding: a.id)
        #expect(joints.count == 2)
        #expect(Set(joints.map(\.wallID)) == Set([b.id, c.id]))
    }

    /// Estremi vicini ma oltre ε non sono una giunzione: il ginocchio non
    /// deve catturare muri che l'utente ha tenuto staccati apposta.
    @Test("Oltre la tolleranza: nessun compagno")
    func beyondTolerance() {
        let a = wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100))
        let b = wall(CGPoint(x: 500 + DrawingDocument.jointTolerance * 2, y: 100),
                     CGPoint(x: 500, y: 400))
        var doc = DrawingDocument()
        doc.walls = [a, b]

        #expect(doc.jointEndpoints(at: a.end, excluding: a.id).isEmpty)
    }

    /// Dentro ε la giunzione tiene: è la stessa fusione di vertici del
    /// RoomShapeTracer (unica costante), quindi un residuo appena sotto
    /// la soglia si piega col ginocchio invece di aprire la stanza.
    @Test("Dentro la tolleranza: il ginocchio tiene")
    func withinTolerance() {
        let a = wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100))
        let b = wall(CGPoint(x: 500 + DrawingDocument.jointTolerance - 0.1, y: 100),
                     CGPoint(x: 500, y: 400))
        var doc = DrawingDocument()
        doc.walls = [a, b]

        let joints = doc.jointEndpoints(at: a.end, excluding: a.id)
        #expect(joints.count == 1)
        #expect(joints.first?.wallID == b.id)
    }

    /// Un muro logico che condivide il vertice segue la piega: il confine
    /// invisibile fa parte della stanza quanto i muri veri.
    @Test("Il muro logico fa parte del ginocchio")
    func logicalWallJoins() {
        let hub = CGPoint(x: 300, y: 300)
        let a = wall(CGPoint(x: 100, y: 300), hub)
        let b = wall(hub, CGPoint(x: 500, y: 300), kind: .logical)
        var doc = DrawingDocument()
        doc.walls = [a, b]

        let joints = doc.jointEndpoints(at: hub, excluding: a.id)
        #expect(joints.count == 1)
        #expect(joints.first?.wallID == b.id)
    }

    /// Il muro chiuso ad anello su se stesso (start e end sullo stesso punto
    /// di un ALTRO vertice) conta una volta per estremo: due voci, non una.
    @Test("Entrambi gli estremi coincidenti: due voci per lo stesso muro")
    func bothEndpointsAtJoint() {
        let hub = CGPoint(x: 300, y: 300)
        let a = wall(CGPoint(x: 100, y: 300), hub)
        let loop = wall(hub, hub)
        var doc = DrawingDocument()
        doc.walls = [a, loop]

        let joints = doc.jointEndpoints(at: hub, excluding: a.id)
        #expect(joints.count == 2)
        #expect(joints.allSatisfy { $0.wallID == loop.id })
    }
}

/// La risanatura silenziosa all'apertura dell'editor: le fessure «a occhio
/// giuste» devono chiudersi da sole, perché nessun utente deve invocare
/// «salda giunzioni» su un disegno che gli sembra già corretto.
@Suite("DrawingDocument.healJoints — la risanatura silenziosa")
struct DrawingHealJointsTests {

    private func wall(_ a: CGPoint, _ b: CGPoint) -> WallSegment {
        WallSegment(start: a, end: b, kind: .exterior)
    }

    /// Angolo quasi chiuso (10 pt di fessura): dopo la risanatura i due
    /// estremi coincidono e il tracciatore può chiudere la stanza.
    @Test("Angolo con fessura: si salda al baricentro")
    func cornerGapHeals() {
        var doc = DrawingDocument()
        doc.walls = [
            wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100)),
            wall(CGPoint(x: 506, y: 108), CGPoint(x: 500, y: 400))
        ]
        doc.healJoints()
        #expect(doc.walls[0].end == doc.walls[1].start)
    }

    /// Giunzione a T: il diagonale che muore a 8 pt dalla parete atterra
    /// sul corpo del muro — il caso vero del balcone dell'utente.
    @Test("T-giunzione: l'estremo atterra sul corpo del muro")
    func teeGapHeals() {
        var doc = DrawingDocument()
        doc.walls = [
            wall(CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 600)),
            wall(CGPoint(x: 0, y: 200), CGPoint(x: 292, y: 300))
        ]
        doc.healJoints()
        let end = doc.walls[1].end
        #expect(abs(end.x - 300) < 0.01)
        #expect(abs(end.y - 300) < 0.5)
    }

    /// Oltre la tolleranza niente si muove: una fessura da 30 pt è una
    /// scelta di disegno, non un errore di mano.
    @Test("Oltre tolleranza: intoccato")
    func beyondToleranceUntouched() {
        var doc = DrawingDocument()
        let a = wall(CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 100))
        let b = wall(CGPoint(x: 530, y: 130), CGPoint(x: 500, y: 400))
        doc.walls = [a, b]
        doc.healJoints()
        #expect(doc.walls[0].end == a.end)
        #expect(doc.walls[1].start == b.start)
    }

    /// Idempotente: su un documento sano (rettangolo saldato) non muove
    /// un solo punto — è il contratto che permette di girare a ogni apertura.
    @Test("Documento sano: risanatura senza effetti")
    func healthyDocumentUntouched() {
        var doc = DrawingDocument()
        doc.walls = [
            wall(CGPoint(x: 0, y: 0), CGPoint(x: 400, y: 0)),
            wall(CGPoint(x: 400, y: 0), CGPoint(x: 400, y: 300)),
            wall(CGPoint(x: 400, y: 300), CGPoint(x: 0, y: 300)),
            wall(CGPoint(x: 0, y: 300), CGPoint(x: 0, y: 0))
        ]
        let before = doc.walls
        doc.healJoints()
        #expect(doc.walls == before)
    }

    /// Il caso completo: stanza col diagonale quasi chiuso → dopo la
    /// risanatura il RoomShapeTracer la chiude e restituisce il poligono.
    @Test("Dopo la risanatura il tracciatore chiude la stanza")
    func tracerClosesAfterHeal() {
        var doc = DrawingDocument()
        doc.walls = [
            wall(CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 0)),
            wall(CGPoint(x: 600, y: 0), CGPoint(x: 600, y: 400)),
            wall(CGPoint(x: 600, y: 400), CGPoint(x: 0, y: 300)),
            wall(CGPoint(x: 8, y: 291), CGPoint(x: 0, y: 0))
        ]
        #expect(RoomShapeTracer.roomPolygon(containing: CGPoint(x: 300, y: 150),
                                            walls: doc.walls) == nil)
        doc.healJoints()
        let polygon = RoomShapeTracer.roomPolygon(containing: CGPoint(x: 300, y: 150),
                                                  walls: doc.walls)
        #expect(polygon != nil)
        #expect((polygon?.count ?? 0) >= 4)
    }
}
