import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Characterization test di `FloorplanMarkerCollisionResolver`.
/// Blocca il comportamento O(n²) attuale prima di memoizzarlo (C3):
/// dopo l'ottimizzazione, gli offset prodotti devono restare identici.
@Suite("FloorplanMarkerCollisionResolver — spaziatura marker sovrapposti")
struct FloorplanMarkerCollisionResolverTests {

    private let imageRect = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func marker(at point: NormalizedPoint) -> PlacedAccessory {
        PlacedAccessory(homeKitAccessoryUUID: UUID(), position: point)
    }

    @Test("In edit mode non viene applicato alcun offset")
    func noOffsetsWhileEditing() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        ]
        let resolver = FloorplanMarkerCollisionResolver(markers: markers, isEditing: true, effectiveScale: 1)
        #expect(resolver.offsets(in: imageRect).isEmpty)
    }

    @Test("Un solo marker non genera offset")
    func singleMarkerHasNoOffset() {
        let resolver = FloorplanMarkerCollisionResolver(
            markers: [marker(at: NormalizedPoint(x: 0.5, y: 0.5))],
            isEditing: false,
            effectiveScale: 1
        )
        #expect(resolver.offsets(in: imageRect).isEmpty)
    }

    @Test("Due marker sovrapposti ricevono entrambi un offset non nullo")
    func overlappingMarkersGetOffsets() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        ]
        let offsets = FloorplanMarkerCollisionResolver(markers: markers, isEditing: false, effectiveScale: 1)
            .offsets(in: imageRect)
        #expect(offsets.count == 2)
        for m in markers {
            let o = offsets[m.id]
            #expect(o != nil)
            #expect(hypot(o?.width ?? 0, o?.height ?? 0) > 0)
        }
    }

    @Test("Marker lontani oltre la soglia non ricevono offset")
    func distantMarkersHaveNoOffset() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.1, y: 0.1)), // (10,10)
            marker(at: NormalizedPoint(x: 0.9, y: 0.9))  // (90,90) — dist ~113 > 32
        ]
        let offsets = FloorplanMarkerCollisionResolver(markers: markers, isEditing: false, effectiveScale: 1)
            .offsets(in: imageRect)
        #expect(offsets.isEmpty)
    }

    @Test("Gli offset sono deterministici e indipendenti dall'ordine dei marker")
    func offsetsAreOrderIndependent() {
        let a = marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        let b = marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        let forward = FloorplanMarkerCollisionResolver(markers: [a, b], isEditing: false, effectiveScale: 1)
            .offsets(in: imageRect)
        let reversed = FloorplanMarkerCollisionResolver(markers: [b, a], isEditing: false, effectiveScale: 1)
            .offsets(in: imageRect)
        #expect(forward[a.id] == reversed[a.id])
        #expect(forward[b.id] == reversed[b.id])
    }
}
