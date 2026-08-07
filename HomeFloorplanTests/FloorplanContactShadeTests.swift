import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Le due velature di contatto non si possono giudicare a occhio su uno
/// screenshot: sono scure, basse e sfumate, e «non la vedo» può voler dire tanto
/// «non c'è» quanto «è troppo debole». Questi test separano le due cose —
/// rispondono solo alla prima, e lasciano la seconda al gusto.
@Suite("FloorplanExtruder — ombre di contatto")
struct FloorplanContactShadeTests {

    /// Una stanza di 5 × 4 metri, chiusa da quattro muri, con un letto dentro.
    /// Cento punti canvas per metro.
    private static func room(withFurniture: Bool = true) -> DrawingDocument {
        var document = DrawingDocument()
        let corners = [CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200),
                       CGPoint(x: 700, y: 600), CGPoint(x: 200, y: 600)]
        for index in corners.indices {
            document.walls.append(WallSegment(start: corners[index],
                                              end: corners[(index + 1) % corners.count],
                                              kind: .exterior))
        }
        document.roomAreas = [RoomArea(name: "Camera",
                                       rect: CGRect(x: 200, y: 200, width: 500, height: 400))]
        if withFurniture {
            document.furnitureItems = [
                FurnitureItem(rect: CGRect(x: 300, y: 300, width: 200, height: 100), kind: .bed)
            ]
        }
        return document
    }

    private static func faces(_ document: DrawingDocument) -> [FloorplanExtruder.Face] {
        FloorplanExtruder.faces(from: document)
    }

    @Test("La fascia alla base dei muri viene emessa")
    func wallContactIsEmitted() {
        let contacts = Self.faces(Self.room()).filter { $0.kind == .wallContact }
        #expect(!contacts.isEmpty)
    }

    @Test("Sta tutta nella fascia bassa, e parte da terra")
    func wallContactStaysLow() {
        let contacts = Self.faces(Self.room()).filter { $0.kind == .wallContact }
        for face in contacts {
            let heights = face.points.map(\.z)
            #expect(heights.min() ?? -1 >= -0.001)
            #expect(heights.max() ?? 99 <= FloorplanExtruder.contactHeight + 0.001)
        }
    }

    /// La velatura vive **sulla facciata interna**: emessa sulla mediana del muro
    /// finirebbe murata dentro, e non si vedrebbe mai — che è precisamente
    /// l'esito che uno screenshot non permette di distinguere da «troppo
    /// debole».
    @Test("Sta davanti al muro, non dentro")
    func wallContactSitsInFrontOfTheWall() {
        let all = Self.faces(Self.room())
        let sides = all.filter { $0.kind == .wallSide }
        let contacts = all.filter { $0.kind == .wallContact }
        #expect(!contacts.isEmpty)

        // Il muro sud va da y = 2 a y = 2.16 (16 pt di spessore): la facciata
        // interna guarda la stanza, quindi la velatura deve stare più in basso
        // in y di quella facciata, non sopra di essa.
        for contact in contacts {
            let nearest = sides.min {
                $0.centroid.distanceSquared(to: contact.centroid)
                    < $1.centroid.distanceSquared(to: contact.centroid)
            }
            guard let nearest else { continue }
            let offset = hypot(nearest.centroid.x - contact.centroid.x,
                               nearest.centroid.y - contact.centroid.y)
            // Tre millimetri di spostamento, con la tolleranza del centroide di
            // una faccia più alta.
            #expect(offset > 0.0005)
            #expect(offset < 0.05)
        }
    }

    @Test("Ogni arredo lascia una macchia a terra, larga una volta e mezzo")
    func furnitureCastsOneGroundContact() {
        let contacts = Self.faces(Self.room()).filter { $0.kind == .groundContact }
        #expect(contacts.count == 1)

        guard let face = contacts.first else { return }
        let xs = face.points.map(\.x)
        let ys = face.points.map(\.y)
        // Il letto è 2 × 1 m: la macchia è 3 × 1.5.
        #expect(abs(((xs.max() ?? 0) - (xs.min() ?? 0)) - 3.0) < 0.01)
        #expect(abs(((ys.max() ?? 0) - (ys.min() ?? 0)) - 1.5) < 0.01)
        // Appoggiata al pavimento, non sospesa.
        #expect(face.points.allSatisfy { abs($0.z - 0.004) < 0.0001 })
    }

    @Test("Senza arredi non c'è nessuna macchia a terra")
    func noFurnitureNoGroundContact() {
        let contacts = Self.faces(Self.room(withFurniture: false))
            .filter { $0.kind == .groundContact }
        #expect(contacts.isEmpty)
    }
}

private extension SIMD3 where Scalar == Double {
    func distanceSquared(to other: SIMD3<Double>) -> Double {
        let delta = self - other
        return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z
    }
}
