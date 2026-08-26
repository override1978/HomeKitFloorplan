import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Bloccano la matematica della rotazione planimetria (v3-B): trasposizione
/// 90° orario delle coordinate normalizzate e criterio di attivazione.
@Suite("FloorplanRotation — trasposizione 90° e criterio")
struct FloorplanRotationTests {

    @Test("Gli angoli ruotano di 90° orario")
    func cornersRotateClockwise() {
        // alto-sinistra → alto-destra
        let tl = FloorplanRotation.point(NormalizedPoint(x: 0, y: 0))
        #expect(tl.x == 1 && tl.y == 0)
        // alto-destra → basso-destra
        let tr = FloorplanRotation.point(NormalizedPoint(x: 1, y: 0))
        #expect(tr.x == 1 && tr.y == 1)
        // basso-destra → basso-sinistra
        let br = FloorplanRotation.point(NormalizedPoint(x: 1, y: 1))
        #expect(br.x == 0 && br.y == 1)
        // il centro resta al centro
        let c = FloorplanRotation.point(NormalizedPoint(x: 0.5, y: 0.5))
        #expect(abs(c.x - 0.5) < 0.0001 && abs(c.y - 0.5) < 0.0001)
    }

    @Test("Il rettangolo trasposto contiene gli stessi punti trasposti")
    func rectTransposesConsistently() {
        let rect = CodableRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3)
        let rotated = FloorplanRotation.rect(rect)

        // Dimensioni scambiate.
        #expect(abs(rotated.width - rect.height) < 0.0001)
        #expect(abs(rotated.height - rect.width) < 0.0001)

        // Il centro del rettangolo ruotato = rotazione del centro.
        let center = FloorplanRotation.codablePoint(
            CodablePoint(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
        )
        #expect(abs((rotated.x + rotated.width / 2) - center.x) < 0.0001)
        #expect(abs((rotated.y + rotated.height / 2) - center.y) < 0.0001)
    }

    @Test("La stanza trasposta conserva identità e vertici coerenti")
    func roomKeepsIdentity() {
        let room = LinkedRoom(
            hmRoomUUID: UUID(),
            name: "Cucina",
            normalizedRect: CodableRect(x: 0, y: 0, width: 0.4, height: 0.2),
            normalizedPoints: [
                CodablePoint(x: 0, y: 0),
                CodablePoint(x: 0.4, y: 0),
                CodablePoint(x: 0.4, y: 0.2),
                CodablePoint(x: 0, y: 0.2)
            ]
        )
        let rotated = FloorplanRotation.room(room)
        #expect(rotated.hmRoomUUID == room.hmRoomUUID)
        #expect(rotated.name == room.name)
        #expect(rotated.normalizedPoints?.count == 4)
        // Ogni vertice trasposto cade dentro il rect trasposto (con tolleranza).
        for p in rotated.normalizedPoints ?? [] {
            #expect(p.x >= rotated.normalizedRect.x - 0.0001)
            #expect(p.x <= rotated.normalizedRect.x + rotated.normalizedRect.width + 0.0001)
            #expect(p.y >= rotated.normalizedRect.y - 0.0001)
            #expect(p.y <= rotated.normalizedRect.y + rotated.normalizedRect.height + 0.0001)
        }
    }

    @Test("Ruota solo quando la sproporzione supera 1.5× e girare aiuta")
    func rotationCriterion() {
        // Piantina larga (2:1) su schermo alto (~9:19.5): ruotare aiuta.
        #expect(FloorplanRotation.shouldRotate(
            imageSize: CGSize(width: 2000, height: 1000),
            container: CGSize(width: 390, height: 844)
        ))
        // Piantina quasi quadrata su schermo alto: sproporzione sì, ma
        // girarla non la riduce abbastanza da giustificare la rotazione…
        #expect(!FloorplanRotation.shouldRotate(
            imageSize: CGSize(width: 1000, height: 1000),
            container: CGSize(width: 1000, height: 1000)
        ))
        // …e su viewport uguale all'aspect non si ruota mai.
        #expect(!FloorplanRotation.shouldRotate(
            imageSize: CGSize(width: 2000, height: 1000),
            container: CGSize(width: 844, height: 390)
        ))
    }
}
