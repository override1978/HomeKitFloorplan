import Foundation

/// Logica pura di rimappatura delle posizioni dei marker quando le stanze linkate
/// (e/o la rotazione di export del disegno) cambiano.
///
/// Estratta da `FloorplanMarkerEditingCoordinator.preserveMarkerPositions` per
/// isolare la matematica di rototraslazione da SwiftData/CloudKit e renderla
/// testabile. Ogni marker mantiene la propria posizione *relativa* dentro la stanza
/// di appartenenza; i marker non rimappabili restano invariati.
///
/// Tutto il containment passa da `FloorplanRoomMatcher` (polygon-aware): anche il
/// fallback sulla stanza *precedente* per marker senza `linkedRoomUUID`, che in
/// origine usava un test solo-rettangolo e ignorava le stanze poligonali.
enum FloorplanMarkerRemapper {

    /// Snapshot posizionale di un marker, indipendente da SwiftData.
    struct Placement: Equatable {
        var positionX: Double
        var positionY: Double
        var linkedRoomUUID: UUID?

        init(positionX: Double, positionY: Double, linkedRoomUUID: UUID?) {
            self.positionX = positionX
            self.positionY = positionY
            self.linkedRoomUUID = linkedRoomUUID
        }
    }

    /// Rimappa un batch di marker. Restituisce un array della stessa lunghezza e
    /// ordine dell'input; le voci non rimappabili sono restituite invariate.
    static func remap(
        placements: [Placement],
        previousRooms: [LinkedRoom],
        newRooms: [LinkedRoom],
        previousRotation: DrawingExportRotation,
        newRotation: DrawingExportRotation
    ) -> [Placement] {
        guard !previousRooms.isEmpty, !newRooms.isEmpty else { return placements }

        let previousByID = Dictionary(uniqueKeysWithValues: previousRooms.map { ($0.hmRoomUUID, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newRooms.map { ($0.hmRoomUUID, $0) })
        let rotationDelta = (newRotation.quarterTurns - previousRotation.quarterTurns + 4) % 4

        return placements.map { placement in
            remapped(
                placement,
                previousByID: previousByID,
                newByID: newByID,
                previousRooms: previousRooms,
                newRooms: newRooms,
                rotationDelta: rotationDelta
            )
        }
    }

    /// Ruota un punto locale `[0, 1]²` di `quarterTurns` quarti di giro orari.
    static func rotatedLocalPoint(x: Double, y: Double, quarterTurns: Int) -> (x: Double, y: Double) {
        switch quarterTurns {
        case 1:
            return (1 - y, x)
        case 2:
            return (1 - x, 1 - y)
        case 3:
            return (y, 1 - x)
        default:
            return (x, y)
        }
    }

    // MARK: - Private

    private static func remapped(
        _ placement: Placement,
        previousByID: [UUID: LinkedRoom],
        newByID: [UUID: LinkedRoom],
        previousRooms: [LinkedRoom],
        newRooms: [LinkedRoom],
        rotationDelta: Int
    ) -> Placement {
        let markerPoint = NormalizedPoint(x: placement.positionX, y: placement.positionY)
        guard let roomID = placement.linkedRoomUUID
                ?? FloorplanRoomMatcher.linkedRoomID(containing: markerPoint, in: previousRooms),
              let previousRoom = previousByID[roomID],
              let newRoom = newByID[roomID] else { return placement }

        let previousRect = previousRoom.normalizedRect
        let newRect = newRoom.normalizedRect
        guard previousRect.width > 0, previousRect.height > 0 else { return placement }

        let localX = (placement.positionX - previousRect.x) / previousRect.width
        let localY = (placement.positionY - previousRect.y) / previousRect.height
        let rotatedLocal = rotatedLocalPoint(x: localX, y: localY, quarterTurns: rotationDelta)
        let newPositionX = clamped(newRect.x + rotatedLocal.x * newRect.width)
        let newPositionY = clamped(newRect.y + rotatedLocal.y * newRect.height)
        let newLinkedRoomID = FloorplanRoomMatcher.linkedRoomID(
            containing: NormalizedPoint(x: newPositionX, y: newPositionY),
            in: newRooms
        ) ?? roomID

        return Placement(
            positionX: newPositionX,
            positionY: newPositionY,
            linkedRoomUUID: newLinkedRoomID
        )
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
