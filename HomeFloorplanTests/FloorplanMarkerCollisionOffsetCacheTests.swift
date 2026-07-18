import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Verifica che la cache memoizzante degli offset anti-collisione sia
/// trasparente (stesso output del resolver diretto) e che ricalcoli solo
/// quando gli input cambiano davvero.
@MainActor
@Suite("FloorplanMarkerCollisionOffsetCache — memoizzazione trasparente")
struct FloorplanMarkerCollisionOffsetCacheTests {

    private let imageRect = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func marker(at point: NormalizedPoint) -> PlacedAccessory {
        PlacedAccessory(homeKitAccessoryUUID: UUID(), position: point)
    }

    @Test("La cache restituisce lo stesso output del resolver diretto")
    func cacheMatchesDirectResolver() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.9, y: 0.9))
        ]
        let cache = FloorplanMarkerCollisionOffsetCache()
        let viaCache = cache.offsets(markers: markers, isEditing: false, effectiveScale: 1.5, in: imageRect)
        let direct = FloorplanMarkerCollisionResolver(markers: markers, isEditing: false, effectiveScale: 1.5)
            .offsets(in: imageRect)
        #expect(viaCache == direct)
    }

    @Test("Input identici: un solo ricalcolo effettivo")
    func identicalInputsHitCache() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        ]
        let cache = FloorplanMarkerCollisionOffsetCache()
        let first = cache.offsets(markers: markers, isEditing: false, effectiveScale: 1, in: imageRect)
        let second = cache.offsets(markers: markers, isEditing: false, effectiveScale: 1, in: imageRect)
        let third = cache.offsets(markers: markers, isEditing: false, effectiveScale: 1, in: imageRect)
        #expect(cache.computeCount == 1)
        #expect(first == second)
        #expect(second == third)
    }

    @Test("Cambio di scala invalida la cache")
    func scaleChangeInvalidates() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        ]
        let cache = FloorplanMarkerCollisionOffsetCache()
        _ = cache.offsets(markers: markers, isEditing: false, effectiveScale: 1, in: imageRect)
        _ = cache.offsets(markers: markers, isEditing: false, effectiveScale: 2, in: imageRect)
        #expect(cache.computeCount == 2)
    }

    @Test("Spostamento di un marker invalida la cache e cambia l'output")
    func positionChangeInvalidates() {
        let a = marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        let b = marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        let cache = FloorplanMarkerCollisionOffsetCache()

        let before = cache.offsets(markers: [a, b], isEditing: false, effectiveScale: 1, in: imageRect)
        #expect(before.count == 2)

        // Allontano b oltre la soglia di collisione.
        b.position = NormalizedPoint(x: 0.05, y: 0.05)
        let after = cache.offsets(markers: [a, b], isEditing: false, effectiveScale: 1, in: imageRect)

        #expect(cache.computeCount == 2)
        #expect(after.isEmpty)
    }

    @Test("Toggle di edit mode invalida la cache")
    func editingToggleInvalidates() {
        let markers = [
            marker(at: NormalizedPoint(x: 0.5, y: 0.5)),
            marker(at: NormalizedPoint(x: 0.5, y: 0.5))
        ]
        let cache = FloorplanMarkerCollisionOffsetCache()
        let normal = cache.offsets(markers: markers, isEditing: false, effectiveScale: 1, in: imageRect)
        let editing = cache.offsets(markers: markers, isEditing: true, effectiveScale: 1, in: imageRect)
        #expect(cache.computeCount == 2)
        #expect(!normal.isEmpty)
        #expect(editing.isEmpty)
    }
}
