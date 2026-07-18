import SwiftUI

/// Memoizza l'output di `FloorplanMarkerCollisionResolver`.
///
/// Il resolver è O(n²) sui marker e veniva rieseguito a ogni valutazione del
/// `body` dell'editor; i suoi input però cambiano solo su eventi discreti
/// (spostamento marker, zoom, toggle edit, resize del contenitore). La cache
/// confronta gli input effettivi (O(n)) e ricalcola solo quando differiscono.
///
/// È una classe tenuta in `@State` nella view: l'identità sopravvive alle
/// rivalutazioni del `body` e la mutazione interna non invalida la view.
/// La correttezza è garantita per costruzione: a parità di input il resolver
/// è deterministico (coperto da `FloorplanMarkerCollisionResolverTests`).
@MainActor
final class FloorplanMarkerCollisionOffsetCache {

    private struct Key: Equatable {
        struct MarkerKey: Equatable {
            let id: UUID
            let x: Double
            let y: Double
        }
        let markers: [MarkerKey]
        let isEditing: Bool
        let scale: CGFloat
        let imageRect: CGRect
    }

    private var key: Key?
    private var cachedOffsets: [UUID: CGSize] = [:]

    /// Numero di ricalcoli effettivi eseguiti — esposto per i test.
    private(set) var computeCount = 0

    func offsets(markers: [PlacedAccessory],
                 isEditing: Bool,
                 effectiveScale: CGFloat,
                 in imageRect: CGRect) -> [UUID: CGSize] {
        let newKey = Key(
            markers: markers.map { Key.MarkerKey(id: $0.id, x: $0.positionX, y: $0.positionY) },
            isEditing: isEditing,
            scale: effectiveScale,
            imageRect: imageRect
        )

        if newKey == key {
            return cachedOffsets
        }

        cachedOffsets = FloorplanMarkerCollisionResolver(
            markers: markers,
            isEditing: isEditing,
            effectiveScale: effectiveScale
        ).offsets(in: imageRect)
        key = newKey
        computeCount += 1
        return cachedOffsets
    }
}
