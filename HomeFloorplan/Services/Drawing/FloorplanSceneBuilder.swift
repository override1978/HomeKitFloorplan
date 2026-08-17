import Foundation
import simd

// MARK: - FloorplanSceneBuilder

@MainActor
enum FloorplanSceneBuilder {
    static func scene(from document: DrawingDocument,
                      ceilingHeight: Double = 2.4,
                      includesFurniture: Bool = false,
                      openOpeningIDs: Set<UUID> = [],
                      closedShutters: [UUID: Double] = [:],
                      televisionSpots: [SIMD2<Double>] = []) -> FloorplanScene? {
        let faces = FloorplanExtruder.faces(
            from: document,
            heights: .init(ceiling: ceilingHeight),
            openOpeningIDs: openOpeningIDs,
            closedShutters: closedShutters,
            televisionSpots: televisionSpots
        )
        .compactMap { face -> FloorplanScene.MeshFace? in
            guard includesFurniture || !isFurniture(face.kind),
                  let role = materialRole(for: face.kind)
            else { return nil }

            return FloorplanScene.MeshFace(
                points: face.points.map(realityPoint),
                role: role,
                roomID: face.roomID,
                roomName: face.roomName,
                floorKind: role == .floor ? face.floorKind : nil,
                openingKind: face.openingKind,
                openingID: face.openingID,
                wallKind: face.wallKind,
                flipSide: face.flipSide,
                tint: face.tint,
                furnitureMaterial: face.furnitureMaterial ?? .plain
            )
        }

        guard !faces.isEmpty else { return nil }
        let points = faces.flatMap(\.points)
        let minPoint = points.reduce(points[0]) {
            SIMD3(min($0.x, $1.x), min($0.y, $1.y), min($0.z, $1.z))
        }
        let maxPoint = points.reduce(points[0]) {
            SIMD3(max($0.x, $1.x), max($0.y, $1.y), max($0.z, $1.z))
        }

        return FloorplanScene(
            faces: faces,
            bounds: .init(min: minPoint, max: maxPoint),
            // Una tapparella che scende **non cambia il numero di facce**: la
            // lastra c'è già, cambia solo quanto è alta. Senza il suo stato qui,
            // il filtro anti-ricostruzione scarterebbe l'aggiornamento — lo
            // stesso inganno già pagato con le ante che si aprivano.
            stateSignature: (openOpeningIDs.map(\.uuidString).sorted()
                             + closedShutters.map { "\($0.key):\(Int($0.value * 20))" }.sorted())
                .joined(separator: ",")
        )
    }

    private static func realityPoint(_ point: SIMD3<Double>) -> SIMD3<Float> {
        // Drawing coordinates are x/y on the canvas and z as height.
        // RealityKit uses y-up, so canvas y becomes horizontal z.
        SIMD3(Float(point.x), Float(point.z), Float(point.y))
    }

    /// L'ombra a terra segue l'arredo che la getta: senza arredi non c'è niente
    /// che possa farla.
    private static func isFurniture(_ kind: FloorplanExtruder.Face.Kind) -> Bool {
        kind == .furnitureTop || kind == .furnitureSide || kind == .groundContact
    }

    private static func materialRole(for kind: FloorplanExtruder.Face.Kind) -> FloorplanScene.MeshFace.MaterialRole? {
        switch kind {
        case .floor:
            return .floor
        case .baseSlab:
            return .baseSlab
        case .wallSide:
            return .wall
        case .wallTop:
            return .wallTop
        case .glass:
            return .glass
        case .frame:
            return .frame
        case .doorLeaf:
            return .door
        case .wallGlow:
            return .wallGlow
        case .wallContact:
            return .wallContact
        case .groundContact:
            return .groundContact
        case .shutter:
            return .shutter
        case .doorPanel:
            return .doorTrim
        case .handle:
            return .doorHandle
        case .parapetSide:
            return .balcony
        case .parapetTop:
            return .balconyTop
        case .furnitureTop, .furnitureSide:
            return .furniture
        }
    }
}
