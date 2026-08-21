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
