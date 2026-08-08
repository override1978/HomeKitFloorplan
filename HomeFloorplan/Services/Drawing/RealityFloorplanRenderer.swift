import SwiftUI
import RealityKit
import UIKit

// La fabbrica della scena: da `FloorplanScene` a entita' RealityKit. Tutto
// statico e senza stato — lo stato vive nel coordinatore di
// `RealityFloorplanView`.

// MARK: - RealityFloorplanRenderer

enum RealityFloorplanRenderer {
    struct RenderedFloorplan {
        var root: Entity
        var roomEntities: [UUID: ModelEntity]
        /// I muri **interni** di ogni stanza, spezzati in fasce di altezza per
        /// poterli accendere con un colore che sfuma invece che piatto.
        var roomWallEntities: [UUID: ModelEntity] = [:]
        var roomNames: [UUID: String]
        var roomFloorKinds: [UUID: FloorKind]
        /// Muri e sommita', per la trasparenza a richiesta: il coordinatore
        /// scambia il materiale senza toccare la geometria.
        var ghostableWalls: [ModelEntity] = []
        /// Le ombre di contatto alla base: su un muro fantasma fluttuerebbero,
        /// quindi si spengono insieme.
        var wallShades: [ModelEntity] = []
    }

    static func entity(for scene: FloorplanScene, background: UIColor) -> RenderedFloorplan {
        let root = Entity()
        var ghostableWalls: [ModelEntity] = []
        var wallShades: [ModelEntity] = []
        let center = scene.bounds.center
        let grouped = Dictionary(grouping: scene.faces, by: \.role)
        var roomEntities: [UUID: ModelEntity] = [:]
        var roomWallEntities: [UUID: ModelEntity] = [:]
        var roomNames: [UUID: String] = [:]
        var roomFloorKinds: [UUID: FloorKind] = [:]

        // Un piano sotto la casa. Un'ombra vera ha bisogno di qualcosa su cui
        // cadere, e lo sfondo è un colore, non geometria: senza questo la casa
        // proietterebbe l'ombra nel vuoto e resterebbe a galleggiare.
        let groundSize = max(scene.bounds.radius, 1) * 12
        let ground = ModelEntity(mesh: .generatePlane(width: groundSize, depth: groundSize),
                                 materials: [FloorplanMaterialCatalog.groundMaterial(background: background)])
        ground.position = SIMD3(0, scene.bounds.min.y - center.y - 0.02, 0)
        root.addChild(ground)

        for role in FloorplanScene.MeshFace.MaterialRole.renderOrder {
            guard let faces = grouped[role] else { continue }

            if role == .floor {
                for face in faces {
                    guard let mesh = mesh(for: [face], role: role, center: center) else { continue }
                    let model = ModelEntity(mesh: mesh, materials: [FloorplanMaterialCatalog.material(for: role, floorKind: face.floorKind)])
                    model.generateCollisionShapes(recursive: false)
                    if let roomID = face.roomID {
                        model.name = "room:\(roomID.uuidString)"
                        roomEntities[roomID] = model
                        roomNames[roomID] = face.roomName ?? String(localized: "floorplan.room", defaultValue: "Room")
                        if let floorKind = face.floorKind {
                            roomFloorKinds[roomID] = floorKind
                        }
                    }
                    root.addChild(model)

                    if let detailMesh = floorDetailMesh(for: face, center: center),
                       let detailMaterial = FloorplanMaterialCatalog.floorDetailMaterial(for: face.floorKind) {
                        root.addChild(ModelEntity(mesh: detailMesh, materials: [detailMaterial]))
                    }
                }
                continue
            }

            if role == .door {
                for face in faces {
                    guard let doorMesh = mesh(for: [face], role: .door, center: center) else { continue }
                    let material = face.openingKind == .frenchDoor || face.openingKind == .slidingDoor
                        ? FloorplanMaterialCatalog.doorGlassMaterial()
                        : FloorplanMaterialCatalog.doorMaterial(openingKind: face.openingKind, wallKind: face.wallKind)
                    root.addChild(ModelEntity(mesh: doorMesh, materials: [material]))
                }
                continue
            }

            if role == .wallGlow {
                // Una velatura per stanza: e' l'unico modo di accenderne una
                // senza accenderle tutte.
                for (roomID, group) in Dictionary(grouping: faces, by: \.roomID) {
                    guard let roomID,
                          let mesh = mesh(for: group, role: role, center: center,
                                          floorY: scene.bounds.min.y)
                    else { continue }
                    let model = ModelEntity(mesh: mesh,
                                            materials: [FloorplanMaterialCatalog.material(for: role)])
                    model.isEnabled = false
                    root.addChild(model)
                    roomWallEntities[roomID] = model
                }
                continue
            }

            // Gli arredi si raggruppano **per tinta**: una mesh per colore,
            // non una per mobile — le draw call restano una manciata e ogni
            // pezzo porta finalmente il proprio materiale.
            if role == .furniture {
                let groups = Dictionary(grouping: faces) { face in
                    face.tint.map { UIColor(cgColor: $0).description } ?? ""
                }
                for (_, group) in groups {
                    guard let mesh = mesh(for: group, role: role, center: center) else { continue }
                    let tint = group.first?.tint.map { UIColor(cgColor: $0) }
                    root.addChild(ModelEntity(
                        mesh: mesh,
                        materials: [FloorplanMaterialCatalog.furnitureMaterial(tint: tint)]
                    ))
                }
                continue
            }

            // Le tapparelle sono **oggetti**, non superfici: ognuna deve
            // potersi toccare, quindi non finisce nella mesh unita del proprio
            // ruolo. Portano il nome del vano che coprono, perche' la geometria
            // non conosce gli UUID di HomeKit: la traduzione la fa la vista,
            // che ha costruito lei quel legame. (La tenda non passa di qui: e'
            // un oggetto vivo del coordinatore, come le lampade.)
            if role == .shutter {
                for face in faces {
                    guard let mesh = mesh(for: [face], role: role, center: center) else { continue }
                    let model = ModelEntity(mesh: mesh,
                                            materials: [FloorplanMaterialCatalog.material(for: role)])
                    model.generateCollisionShapes(recursive: false)
                    if let openingID = face.openingID {
                        model.name = "shutter:\(openingID.uuidString)"
                    }
                    root.addChild(model)
                }
                continue
            }

            guard let mesh = mesh(for: faces, role: role, center: center,
                                  floorY: scene.bounds.min.y) else { continue }

            let model = ModelEntity(mesh: mesh, materials: [FloorplanMaterialCatalog.material(for: role)])
            if role == .wall || role == .wallTop { ghostableWalls.append(model) }
            if role == .wallContact { wallShades.append(model) }
            root.addChild(model)
        }

        return RenderedFloorplan(root: root,
                                 roomEntities: roomEntities,
                                 roomWallEntities: roomWallEntities,
                                 roomNames: roomNames,
                                 roomFloorKinds: roomFloorKinds,
                                 ghostableWalls: ghostableWalls,
                                 wallShades: wallShades)
    }

    // MARK: - Bandierine di stanza

    struct Flag {
        var roomID: UUID
        var root: Entity
        /// Solo l'etichetta si gira verso la telecamera: lo stelo è verticale e
        /// non ha un davanti.
        var label: ModelEntity
        /// Serve al coordinatore per spegnerlo a camera bassa, quando i pali
        /// trapassano mobili e facciate.
        var stem: ModelEntity
    }

    /// Uno stelo piantato nel punto più interno della stanza, con il valore in
    /// cima. Sopra la linea dei muri, così nessuna bandierina finisce nascosta
    /// da una parete e tutte stanno alla stessa quota — che è ciò che permette
    /// di confrontarle a colpo d'occhio invece di cercarle.
    static func flagEntities(for flags: [RoomFlag], scene: FloorplanScene) -> [Flag] {
        guard !flags.isEmpty else { return [] }
        let centre = scene.bounds.center
        let floorY = scene.bounds.min.y
        let topY = scene.bounds.max.y + 0.55

        return flags.compactMap { flag -> Flag? in
            guard let label = FloorplanMaterialCatalog.flagLabelMaterial(
                title: flag.title, value: flag.value, accent: flag.accent
            ) else { return nil }

            // Il disegno ha x/y in pianta, RealityKit ha y in alto: la y del
            // disegno diventa z, come per tutto il resto della scena.
            let x = Float(flag.anchor.x) - centre.x
            let z = Float(flag.anchor.y) - centre.z

            let root = Entity()
            let height = topY - floorY
            let stem = ModelEntity(mesh: .generateBox(size: SIMD3(0.026, height, 0.026)),
                                   materials: [FloorplanMaterialCatalog.flagStemMaterial()])
            stem.position = SIMD3(x, floorY - centre.y + height / 2, z)
            root.addChild(stem)

            let plate = ModelEntity(mesh: flagLabelMesh(aspect: label.aspect),
                                    materials: [label.material])
            plate.position = SIMD3(x, topY - centre.y + 0.19, z)
            root.addChild(plate)

            return Flag(roomID: flag.roomID, root: root, label: plate, stem: stem)
        }
    }

    /// Altezza fissa, larghezza dal contenuto: cosi' tutte le capsule restano
    /// sulla stessa riga ottica anche quando dicono cose di lunghezza diversa.
    static func flagLabelMesh(aspect: CGFloat) -> MeshResource {
        let height: Float = 0.32
        return .generatePlane(width: height * Float(aspect), height: height)
    }

    /// Una fascia lungo il perimetro del pavimento della stanza.
    ///
    /// Il verso «dentro» si trova provandolo: per ogni lato si sposta il punto
    /// medio da una parte e si guarda se cade dentro il poligono. Dedurlo dal
    /// verso di avvolgimento sarebbe più elegante e meno affidabile — le stanze
    /// arrivano disegnate a mano, in entrambi i sensi.
    static func selectionOutlineEntity(for roomID: UUID, scene: FloorplanScene) -> Entity? {
        let faces = scene.faces.filter { $0.role == .floor && $0.roomID == roomID }
        guard !faces.isEmpty else { return nil }

        let centre = scene.bounds.center
        let lift: Float = 0.022
        let width: Float = 0.07

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for face in faces where face.points.count >= 3 {
            let polygon = orderedPoints(for: face, role: .floor)
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                let along = SIMD2(b.x - a.x, b.z - a.z)
                let length = simd_length(along)
                guard length > 0.001 else { continue }

                var inward = SIMD2(-along.y, along.x) / length
                let middle = SIMD2((a.x + b.x) / 2, (a.z + b.z) / 2)
                if !contains(point: middle + inward * 0.05, in: polygon) { inward = -inward }

                let y = a.y + lift
                let quad = [
                    SIMD3(a.x, y, a.z),
                    SIMD3(b.x, y, b.z),
                    SIMD3(b.x + inward.x * width, y, b.z + inward.y * width),
                    SIMD3(a.x + inward.x * width, y, a.z + inward.y * width)
                ]
                let start = UInt32(positions.count)
                positions.append(contentsOf: quad.map { $0 - centre })
                normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
                indices.append(contentsOf: [start, start + 1, start + 2,
                                            start, start + 2, start + 3,
                                            start, start + 2, start + 1,
                                            start, start + 3, start + 2])
            }
        }

        guard !positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "room-outline")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }

        return ModelEntity(mesh: mesh,
                           materials: [FloorplanMaterialCatalog.selectionOutlineMaterial()])
    }

    /// Il cono di luce di un faretto: apice sul bulbo, base sul pavimento.
    ///
    /// Costruito a mano invece che con una primitiva perché servono le UV: la
    /// **v** va da 0 all'apice a 1 alla base, così la sfumatura verticale lo
    /// spegne scendendo. Emesso da entrambi i lati, o entrandoci dentro con la
    /// telecamera sparirebbe.
    /// Il cono **visibile** e' piu' stretto di quello che illumina.
    ///
    /// A 72 gradi la base larga come tutta l'apertura del faretto usciva dal
    /// muro quando la lampada era a mezzo metro da una parete, e quel pezzo di
    /// cono si vedeva **da fuori casa**. La luce resta larga; il velo che la
    /// racconta si stringe, perche' il suo mestiere e' dire da che parte va,
    /// non misurare l'apertura.
    static let beamAngle: Float = 44

    static func lampBeamMesh(height: Float, outerAngleDegrees: Float) -> MeshResource? {
        guard height > 0.1 else { return nil }
        let segments = 28
        let radius = height * tan(outerAngleDegrees * .pi / 180 / 2)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for segment in 0..<segments {
            let a = Float(segment) / Float(segments) * 2 * .pi
            let b = Float(segment + 1) / Float(segments) * 2 * .pi
            let apex = SIMD3<Float>(0, 0, 0)
            let left = SIMD3(cos(a) * radius, -height, sin(a) * radius)
            let right = SIMD3(cos(b) * radius, -height, sin(b) * radius)
            let normal = simd_normalize(simd_cross(left - apex, right - apex))

            for (points, facing) in [([apex, left, right], normal), ([apex, right, left], -normal)] {
                let start = UInt32(positions.count)
                positions.append(contentsOf: points)
                normals.append(contentsOf: Array(repeating: facing, count: 3))
                uvs.append(contentsOf: [SIMD2(0.5, 0), SIMD2(0.5, 1), SIMD2(0.5, 1)])
                indices.append(contentsOf: [start, start + 1, start + 2])
            }
        }

        var descriptor = MeshDescriptor(name: "lamp-beam")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// La pozza di luce di una lampada, ritagliata sul pavimento.
    ///
    /// Si riusa il ritaglio a celle delle macchie di sole: la luce non attraversa
    /// i muri, quindi la pozza deve fermarsi dove finisce il pavimento.
    static func lampPoolEntity(for lamp: FloorplanLamp, scene: FloorplanScene) -> Entity? {
        guard let material = FloorplanMaterialCatalog.lampPoolMaterial(lamp.colour) else { return nil }
        let floors = scene.faces.filter { $0.role == .floor && $0.points.count >= 3 }
        guard !floors.isEmpty else { return nil }

        let centre = scene.bounds.center
        let floorY = scene.bounds.min.y + 0.010
        let radius = Float(1.1 + 1.5 * lamp.brightness)
        let x = Float(lamp.position.x)
        let z = Float(lamp.position.y)

        let quad = [
            SIMD3(x - radius, floorY, z - radius),
            SIMD3(x + radius, floorY, z - radius),
            SIMD3(x + radius, floorY, z + radius),
            SIMD3(x - radius, floorY, z + radius)
        ]

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        for cell in patchCells(of: quad, landingOn: floors) {
            let start = UInt32(positions.count)
            positions.append(contentsOf: cell.map { $0 - centre })
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
            uvs.append(contentsOf: cell.map {
                SIMD2(0.5 + ($0.x - x) / (2 * radius), 0.5 + ($0.z - z) / (2 * radius))
            })
            indices.append(contentsOf: [start, start + 1, start + 2, start, start + 2, start + 3])
        }

        guard !positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "lamp-pool")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }

        return ModelEntity(mesh: mesh, materials: [material])
    }

    // MARK: - Il sole che entra

    /// La macchia di luce che un vetro lascia cadere sul pavimento.
    ///
    /// RealityKit non fa passare la luce attraverso la geometria trasparente:
    /// una finestra illuminata resta un rettangolo azzurro, e la stanza dietro
    /// non se ne accorge. Qui la si costruisce a mano, ed è **geometria esatta**,
    /// non un effetto: con un sole all'infinito l'immagine di un'apertura sul
    /// pavimento è l'apertura stessa proiettata lungo i raggi.
    ///
    /// Poi si ritaglia su ciò che è davvero pavimento — a celle, perché le stanze
    /// non sono convesse e un ritaglio analitico non reggerebbe una stanza a L —
    /// così la luce non esce dai muri e non si posa sul prato.
    static func sunPatchEntity(for scene: FloorplanScene, sun: FloorplanSunLight) -> Entity? {
        guard sun.isAboveHorizon, sun.direction.y > 0.06 else { return nil }

        let floors = scene.faces.filter { $0.role == .floor && $0.points.count >= 3 }
        guard !floors.isEmpty else { return nil }

        let floorY = scene.bounds.min.y
        let center = scene.bounds.center
        var quads: [[SIMD3<Float>]] = []
        var alreadySeen: Set<SIMD2<Int>> = []

        // Un vetro con la tapparella giu' non fa passare niente: la macchia va
        // tolta, non attenuata. E' il vero effetto della tapparella sul modello,
        // molto piu' della lastra che si vede da fuori.
        let blocked = Set(scene.faces.filter { $0.role == .shutter }.compactMap(\.openingID))

        for face in scene.faces where face.role == .glass && face.points.count == 4 {
            if let openingID = face.openingID, blocked.contains(openingID) { continue }
            // Un vetro è un solido sottile, quindi arriva sei volte. Si tengono le
            // facce larghe e verticali, e si scarta chi proietta dove ha già
            // proiettato qualcun altro: due lastre a 8 mm di distanza fanno la
            // stessa macchia, e sommarle la raddoppierebbe di luminosità.
            let normal = faceNormal(for: face.points)
            guard abs(normal.y) < 0.45, quadArea(face.points) > 0.05 else { continue }

            let projected = face.points.map { point -> SIMD3<Float> in
                let travel = (point.y - floorY) / sun.direction.y
                let landed = point - sun.direction * travel
                return SIMD3(landed.x, floorY + 0.006, landed.z)
            }

            let centroid = projected.reduce(SIMD3<Float>.zero, +) / 4
            let key = SIMD2(Int((centroid.x * 12).rounded()), Int((centroid.z * 12).rounded()))
            guard alreadySeen.insert(key).inserted else { continue }

            quads += patchCells(of: projected, landingOn: floors)
        }

        guard !quads.isEmpty else { return nil }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for quad in quads {
            let start = UInt32(positions.count)
            positions.append(contentsOf: quad.map { $0 - center })
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
            indices.append(contentsOf: [start, start + 1, start + 2, start, start + 2, start + 3])
        }

        var descriptor = MeshDescriptor(name: "sun-patch")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }

        return ModelEntity(mesh: mesh, materials: [FloorplanMaterialCatalog.material(for: .sunPatch)])
    }

    private static func patchCells(of quad: [SIMD3<Float>],
                                   landingOn floors: [FloorplanScene.MeshFace]) -> [[SIMD3<Float>]] {
        let steps = 7
        func at(_ u: Float, _ v: Float) -> SIMD3<Float> {
            let bottom = quad[0] + (quad[1] - quad[0]) * u
            let top = quad[3] + (quad[2] - quad[3]) * u
            return bottom + (top - bottom) * v
        }

        var cells: [[SIMD3<Float>]] = []
        for column in 0..<steps {
            for row in 0..<steps {
                let u0 = Float(column) / Float(steps), u1 = Float(column + 1) / Float(steps)
                let v0 = Float(row) / Float(steps), v1 = Float(row + 1) / Float(steps)
                let middle = at((u0 + u1) / 2, (v0 + v1) / 2)
                let flat = SIMD2(middle.x, middle.z)
                guard floors.contains(where: { contains(point: flat, in: $0.points) }) else { continue }
                cells.append([at(u0, v0), at(u1, v0), at(u1, v1), at(u0, v1)])
            }
        }
        return cells
    }

    private static func quadArea(_ points: [SIMD3<Float>]) -> Float {
        guard points.count == 4 else { return 0 }
        return simd_length(simd_cross(points[2] - points[0], points[3] - points[1])) / 2
    }

    /// Una macchia morbida sul pavimento di ogni stanza che chiede attenzione.
    ///
    /// Il poligono del pavimento fa da ritaglio — la macchia non esce dalla
    /// stanza — ma la sfumatura la spegne **prima** di arrivare ai muri, quindi
    /// il bordo del poligono non si vede mai. È il contrario del riempimento
    /// pieno che avevamo prima: lì era il bordo a definire la forma, qui è la
    /// sfumatura, e il bordo non esiste.
    static func roomHeatEntities(for flags: [RoomFlag], scene: FloorplanScene) -> [Entity] {
        let centre = scene.bounds.center
        let lift: Float = 0.014

        return flags.compactMap { flag -> Entity? in
            guard flag.needsAttention,
                  let accent = flag.accent,
                  let material = FloorplanMaterialCatalog.roomHeatMaterial(accent)
            else { return nil }

            let faces = scene.faces.filter { $0.role == .floor && $0.roomID == flag.roomID }
            guard !faces.isEmpty else { return nil }

            let points = faces.flatMap(\.points)
            let anchorX = Float(flag.anchor.x)
            let anchorZ = Float(flag.anchor.y)
            // Il raggio copre la stanza con un margine: la sfumatura arriva a
            // zero appena oltre il punto più lontano, non prima.
            let radius = max(0.6, points.map {
                max(abs($0.x - anchorX), abs($0.z - anchorZ))
            }.max() ?? 1) * 1.05

            var positions: [SIMD3<Float>] = []
            var normals: [SIMD3<Float>] = []
            var uvs: [SIMD2<Float>] = []
            var indices: [UInt32] = []

            for face in faces where face.points.count >= 3 {
                let ordered = orderedPoints(for: face, role: .floor)
                let start = UInt32(positions.count)
                positions.append(contentsOf: ordered.map { SIMD3($0.x, $0.y + lift, $0.z) - centre })
                normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: ordered.count))
                uvs.append(contentsOf: ordered.map {
                    SIMD2(0.5 + ($0.x - anchorX) / (2 * radius),
                          0.5 + ($0.z - anchorZ) / (2 * radius))
                })
                for index in 1..<(ordered.count - 1) {
                    indices.append(contentsOf: [start, start + UInt32(index), start + UInt32(index + 1)])
                }
            }

            guard !positions.isEmpty else { return nil }
            var descriptor = MeshDescriptor(name: "room-heat")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
            descriptor.primitives = .triangles(indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }

            return ModelEntity(mesh: mesh, materials: [material])
        }
    }

    private static func doorEntities(for face: FloorplanScene.MeshFace,
                                     center: SIMD3<Float>) -> [Entity] {
        guard face.points.count == 4 else { return [] }

        let isWindowedDoor = face.openingKind == .frenchDoor || face.openingKind == .slidingDoor
        var entities: [Entity] = []

        if !isWindowedDoor,
           let doorMesh = mesh(for: [face], role: .door, center: center) {
            entities.append(ModelEntity(mesh: doorMesh,
                                        materials: [FloorplanMaterialCatalog.doorMaterial(openingKind: face.openingKind,
                                                                                         wallKind: face.wallKind)]))
        }

        if let edgeMesh = mesh(for: [face], role: .doorEdge, center: center),
           !isWindowedDoor {
            entities.append(ModelEntity(mesh: edgeMesh, materials: [FloorplanMaterialCatalog.material(for: .doorEdge)]))
        }

        let trimFaces = isWindowedDoor ? windowedDoorTrimFaces(for: face) : []
        for trimFace in trimFaces {
            guard let trimMesh = mesh(for: [trimFace], role: .doorTrim, center: center) else { continue }
            entities.append(ModelEntity(mesh: trimMesh,
                                        materials: [FloorplanMaterialCatalog.doorTrimMaterial(openingKind: face.openingKind,
                                                                                             wallKind: face.wallKind)]))
        }

        for glassFace in windowedDoorGlassFaces(for: face) {
            guard let glassMesh = mesh(for: [glassFace], role: .doorGlass, center: center) else { continue }
            entities.append(ModelEntity(mesh: glassMesh, materials: [FloorplanMaterialCatalog.doorGlassMaterial()]))
        }

        for handleFace in doorHandleFaces(for: face) {
            guard let handleMesh = mesh(for: [handleFace], role: .doorHandle, center: center) else { continue }
            entities.append(ModelEntity(mesh: handleMesh, materials: [FloorplanMaterialCatalog.doorHandleMaterial()]))
        }

        return entities
    }

    private static func windowedDoorTrimFaces(for face: FloorplanScene.MeshFace) -> [FloorplanScene.MeshFace] {
        [
            doorSubFaces(for: face, u0: 0.00, u1: 0.085, v0: 0.00, v1: 1.00, role: .doorTrim),
            doorSubFaces(for: face, u0: 0.915, u1: 1.00, v0: 0.00, v1: 1.00, role: .doorTrim),
            doorSubFaces(for: face, u0: 0.00, u1: 1.00, v0: 0.00, v1: 0.085, role: .doorTrim),
            doorSubFaces(for: face, u0: 0.00, u1: 1.00, v0: 0.915, v1: 1.00, role: .doorTrim),
            doorSubFaces(for: face, u0: 0.475, u1: 0.525, v0: 0.08, v1: 0.92, role: .doorTrim)
        ].flatMap { $0 }
    }

    private static func windowedDoorGlassFaces(for face: FloorplanScene.MeshFace) -> [FloorplanScene.MeshFace] {
        guard face.openingKind == .frenchDoor || face.openingKind == .slidingDoor else { return [] }

        return [
            doorSubFace(for: face, u0: 0.11, u1: 0.46, v0: 0.14, v1: 0.88, role: .doorGlass, lift: 0.026),
            doorSubFace(for: face, u0: 0.54, u1: 0.89, v0: 0.14, v1: 0.88, role: .doorGlass, lift: 0.026)
        ].compactMap { $0 }
    }

    private static func doorHandleFaces(for face: FloorplanScene.MeshFace) -> [FloorplanScene.MeshFace] {
        guard face.openingKind != .slidingDoor else {
            return doorSubFaces(for: face, u0: 0.47, u1: 0.53, v0: 0.42, v1: 0.58, role: .doorHandle, lift: 0.042)
        }

        let handleU0: Float = face.flipSide ? 0.12 : 0.80
        return doorSubFaces(for: face, u0: handleU0, u1: handleU0 + 0.075, v0: 0.46, v1: 0.54, role: .doorHandle, lift: 0.044)
    }

    private static func doorSubFaces(for face: FloorplanScene.MeshFace,
                                     u0: Float,
                                     u1: Float,
                                     v0: Float,
                                     v1: Float,
                                     role: FloorplanScene.MeshFace.MaterialRole,
                                     lift: Float = 0.028) -> [FloorplanScene.MeshFace] {
        [
            doorSubFace(for: face, u0: u0, u1: u1, v0: v0, v1: v1, role: role, lift: lift)
        ].compactMap { $0 }
    }

    private static func doorSubFace(for face: FloorplanScene.MeshFace,
                                    u0: Float,
                                    u1: Float,
                                    v0: Float,
                                    v1: Float,
                                    role: FloorplanScene.MeshFace.MaterialRole,
                                    lift: Float = 0.028) -> FloorplanScene.MeshFace? {
        let panelPoints = doorPanelPoints(for: face)
        guard panelPoints.count == 4 else { return nil }

        let quad = [
            interpolatedDoorPoint(panelPoints, u: u0, v: v0),
            interpolatedDoorPoint(panelPoints, u: u1, v: v0),
            interpolatedDoorPoint(panelPoints, u: u1, v: v1),
            interpolatedDoorPoint(panelPoints, u: u0, v: v1)
        ]
        let normal = faceNormal(for: panelPoints)

        return FloorplanScene.MeshFace(points: quad.map { $0 + normal * lift },
                                       role: role,
                                       roomID: nil,
                                       roomName: nil,
                                       openingKind: face.openingKind,
                                       wallKind: face.wallKind,
                                       flipSide: face.flipSide)
    }

    private static func interpolatedDoorPoint(_ points: [SIMD3<Float>],
                                              u: Float,
                                              v: Float) -> SIMD3<Float> {
        let bottom = points[0] + (points[1] - points[0]) * u
        let top = points[3] + (points[2] - points[3]) * u
        return bottom + (top - bottom) * v
    }

    private static func mesh(for faces: [FloorplanScene.MeshFace],
                             role: FloorplanScene.MeshFace.MaterialRole,
                             center: SIMD3<Float>,
                             floorY: Float = 0) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        // Ogni faccia emessa **da entrambi i lati, con normali opposte**.
        //
        // L'estrusore non garantisce un verso di avvolgimento coerente, e finché
        // i materiali erano unlit non contava niente. Con la luce conta moltissimo:
        // una faccia con la normale girata al contrario si illumina al rovescio e
        // diventa nera. Prima si duplicavano i triangoli riusando la **stessa**
        // normale, che risolve la visibilità ma non l'illuminazione.
        func append(_ points: [SIMD3<Float>], _ normal: SIMD3<Float>) {
            let start = UInt32(positions.count)
            positions.append(contentsOf: points.map { $0 - center })
            normals.append(contentsOf: Array(repeating: normal, count: points.count))
            uvs.append(contentsOf: textureCoordinates(for: points, role: role, floorY: floorY))
            for index in 1..<(points.count - 1) {
                indices.append(start)
                indices.append(start + UInt32(index))
                indices.append(start + UInt32(index + 1))
            }
        }

        for face in faces where face.points.count >= 3 {
            let points = orderedPoints(for: face, role: role)
            let normal = faceNormal(for: points)
            append(points, normal)
            append(Array(points.reversed()), -normal)
        }

        guard !positions.isEmpty, !indices.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: "floorplan")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func floorDetailMesh(for face: FloorplanScene.MeshFace,
                                        center: SIMD3<Float>) -> MeshResource? {
        guard let floorKind = face.floorKind,
              face.points.count >= 3
        else { return nil }

        let polygon = floorPointsNeedReversing(face.points) ? face.points.reversed() : face.points
        let bounds = polygonBounds(polygon)
        let y = (polygon.map(\.y).min() ?? 0) + 0.009
        let lines: [(SIMD2<Float>, SIMD2<Float>, Float)]

        switch floorKind {
        case .legno:
            return nil
        case .piastrelle:
            lines = floorAxisLines(in: polygon, bounds: bounds, spacing: 0.55, width: 0.010, axis: .x)
                + floorAxisLines(in: polygon, bounds: bounds, spacing: 0.55, width: 0.010, axis: .z)
        case .gres:
            lines = floorAxisLines(in: polygon, bounds: bounds, spacing: 0.75, width: 0.012, axis: .x)
                + floorAxisLines(in: polygon, bounds: bounds, spacing: 0.75, width: 0.012, axis: .z)
        case .marmo:
            return nil
        case .cemento, .erba:
            return nil
        }

        return stripMesh(from: lines, y: y, center: center)
    }

    private enum FloorAxis {
        case x
        case z
    }

    private static func polygonBounds(_ points: [SIMD3<Float>]) -> (minX: Float, maxX: Float, minZ: Float, maxZ: Float) {
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minZ = points.map(\.z).min() ?? 0
        let maxZ = points.map(\.z).max() ?? 0
        return (minX, maxX, minZ, maxZ)
    }

    private static func floorAxisLines(in polygon: [SIMD3<Float>],
                                       bounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float),
                                       spacing: Float,
                                       width: Float,
                                       axis: FloorAxis) -> [(SIMD2<Float>, SIMD2<Float>, Float)] {
        var lines: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        let start = axis == .x ? bounds.minX : bounds.minZ
        let end = axis == .x ? bounds.maxX : bounds.maxZ
        // Le fughe stanno sui multipli **mondiali** del passo, non sui bounds
        // della stanza: due stanze adiacenti con lo stesso pavimento devono
        // condividere la griglia, o alla porta le righe si sfalsano e il
        // pavimento si legge come due. Le texture (doghe, marmo) sono già
        // continue perché le UV sono metriche sul mondo — questa era l'unica
        // parte ancorata alla stanza.
        var cursor = (start / spacing).rounded(.down) * spacing + spacing

        while cursor < end {
            let segment: (SIMD2<Float>, SIMD2<Float>)
            switch axis {
            case .x:
                segment = (SIMD2(cursor, bounds.minZ), SIMD2(cursor, bounds.maxZ))
            case .z:
                segment = (SIMD2(bounds.minX, cursor), SIMD2(bounds.maxX, cursor))
            }
            clippedSegments(for: segment, in: polygon).forEach { lines.append(($0.0, $0.1, width)) }
            cursor += spacing
        }
        return lines
    }

    private static func floorStripes(in polygon: [SIMD3<Float>],
                                     bounds: (minX: Float, maxX: Float, minZ: Float, maxZ: Float),
                                     direction: SIMD2<Float>,
                                     spacing: Float,
                                     width: Float) -> [(SIMD2<Float>, SIMD2<Float>, Float)] {
        let perpendicular = SIMD2<Float>(-direction.y, direction.x)
        let center = SIMD2((bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2)
        let radius = max(bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ) * 0.85
        var lines: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        var offset = -radius

        while offset <= radius {
            let lineCenter = center + perpendicular * offset
            let segment = (lineCenter - direction * radius, lineCenter + direction * radius)
            clippedSegments(for: segment, in: polygon).forEach { lines.append(($0.0, $0.1, width)) }
            offset += spacing
        }
        return lines
    }

    private static func clippedSegments(for segment: (SIMD2<Float>, SIMD2<Float>),
                                        in polygon: [SIMD3<Float>]) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let start = segment.0
        let end = segment.1
        let direction = end - start
        var parameters: [Float] = [0, 1]

        for index in polygon.indices {
            let a = SIMD2(polygon[index].x, polygon[index].z)
            let bPoint = polygon[(index + 1) % polygon.count]
            let b = SIMD2(bPoint.x, bPoint.z)
            if let intersection = lineIntersectionParameter(start: start, direction: direction, edgeStart: a, edgeEnd: b) {
                parameters.append(intersection)
            }
        }

        parameters = Array(Set(parameters.map { min(max($0, 0), 1) })).sorted()
        guard parameters.count >= 2 else { return [] }

        var segments: [(SIMD2<Float>, SIMD2<Float>)] = []
        for index in 0..<(parameters.count - 1) {
            let t0 = parameters[index]
            let t1 = parameters[index + 1]
            guard t1 - t0 > 0.001 else { continue }
            let midpoint = start + direction * ((t0 + t1) / 2)
            guard contains(point: midpoint, in: polygon) else { continue }
            segments.append((start + direction * t0, start + direction * t1))
        }
        return segments
    }

    private static func lineIntersectionParameter(start: SIMD2<Float>,
                                                  direction: SIMD2<Float>,
                                                  edgeStart: SIMD2<Float>,
                                                  edgeEnd: SIMD2<Float>) -> Float? {
        let edge = edgeEnd - edgeStart
        let denominator = cross(direction, edge)
        guard abs(denominator) > 0.0001 else { return nil }
        let delta = edgeStart - start
        let t = cross(delta, edge) / denominator
        let u = cross(delta, direction) / denominator
        guard t >= -0.0001, t <= 1.0001, u >= -0.0001, u <= 1.0001 else { return nil }
        return t
    }

    private static func contains(point: SIMD2<Float>, in polygon: [SIMD3<Float>]) -> Bool {
        var isInside = false
        var previous = polygon.count - 1

        for current in polygon.indices {
            let currentPoint = SIMD2(polygon[current].x, polygon[current].z)
            let previousPoint = SIMD2(polygon[previous].x, polygon[previous].z)
            let crosses = (currentPoint.y > point.y) != (previousPoint.y > point.y)
            let denominator = previousPoint.y - currentPoint.y
            guard abs(denominator) > 0.0001 else {
                previous = current
                continue
            }
            let intersectionX = (previousPoint.x - currentPoint.x)
                * (point.y - currentPoint.y)
                / denominator
                + currentPoint.x

            if crosses && point.x < intersectionX {
                isInside.toggle()
            }
            previous = current
        }

        return isInside
    }

    private static func stripMesh(from lines: [(SIMD2<Float>, SIMD2<Float>, Float)],
                                  y: Float,
                                  center: SIMD3<Float>) -> MeshResource? {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        for (start, end, width) in lines {
            let vector = end - start
            let length = simd_length(vector)
            guard length > 0.04 else { continue }
            let normal2D = SIMD2<Float>(-vector.y, vector.x) / length * (width / 2)
            let base = UInt32(positions.count)
            positions.append(SIMD3(start.x + normal2D.x, y, start.y + normal2D.y) - center)
            positions.append(SIMD3(end.x + normal2D.x, y, end.y + normal2D.y) - center)
            positions.append(SIMD3(end.x - normal2D.x, y, end.y - normal2D.y) - center)
            positions.append(SIMD3(start.x - normal2D.x, y, start.y - normal2D.y) - center)
            normals.append(contentsOf: Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }

        guard !positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "floor-detail")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func cross(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        a.x * b.y - a.y * b.x
    }

    /// UV in **metri**, non normalizzate sulla stanza.
    ///
    /// Prima le coordinate andavano da 0 a 1 sul rettangolo della stanza, quindi
    /// la texture si stirava per riempire l'area: il parquet aveva le stesse
    /// doghe in una camera da 6 m e in un bagno da 2 m, larghe il triplo. Ora la
    /// scala di ripetizione la decide il materiale, ed è la stessa ovunque.
    private static func textureCoordinates(for points: [SIMD3<Float>],
                                           role: FloorplanScene.MeshFace.MaterialRole,
                                           floorY: Float = 0) -> [SIMD2<Float>] {
        switch role {
        case .floor:
            return points.map { SIMD2($0.x, $0.z) }
        case .wallGlow:
            // La sfumatura si misura da terra, non dalla quota del muro: così
            // l'architrave sopra una porta non riparte da capo.
            //
            // ⚠️ La u sta **fissa a metà texture**, non in metri: il
            // campionamento è `clampToZero`, che fuori dall'intervallo 0–1
            // restituisce trasparente. Lasciandoci la coordinata del mondo la
            // velatura c'era ed era invisibile ovunque. E la v va limitata, o un
            // soffitto più alto della sfumatura taglia di netto invece di
            // spegnersi.
            //
            // ⚠️ **`v = 0` pesca il fondo dell'immagine, non la cima.** L'asse
            // verticale delle UV è ribaltato rispetto allo spazio immagine di
            // UIKit, dove `y = 0` è in alto. Con la mappatura opposta la
            // sfumatura usciva perfetta e capovolta: piena al soffitto e spenta
            // a terra.
            return points.map {
                SIMD2(0.5, max(0, min(1, ($0.y - floorY) / wallGlowHeight)))
            }
        case .wallContact:
            // Stessa regola della velatura di stato, su una fascia molto piu'
            // bassa: la v si misura da terra, la u sta ferma a meta' texture.
            return points.map {
                SIMD2(0.5, max(0, min(1, ($0.y - floorY) / Float(FloorplanExtruder.contactHeight))))
            }
        case .shutter:
            // Il passo delle stecche sta **in metri**, non in frazione di
            // finestra: sette centimetri sono sette centimetri sia sul bagno
            // sia sulla portafinestra. Normalizzarlo darebbe stecche larghe il
            // doppio sulle aperture grandi.
            return points.map { SIMD2($0.x, $0.y / 0.07) }
        case .groundContact:
            // Le UV **seguono l'ordine dei vertici**, non le coordinate del
            // mondo: il quadrato e' ruotato come il mobile, e una mappatura per
            // bounding box strapperebbe la macchia di sghembo.
            guard points.count == 4 else { return points.map { SIMD2($0.x, $0.z) } }
            return [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        default:
            return points.map { SIMD2($0.x, $0.y) }
        }
    }

    /// Sopra questa quota la velatura è spenta del tutto.
    private static let wallGlowHeight: Float = 2.30

    private static func orderedPoints(for face: FloorplanScene.MeshFace,
                                      role: FloorplanScene.MeshFace.MaterialRole) -> [SIMD3<Float>] {
        switch role {
        case .floor:
            return floorPointsNeedReversing(face.points) ? face.points.reversed() : face.points
        case .door:
            return liftedPanePoints(face.points)
        case .doorEdge:
            return liftedPanePoints(face.points)
        case .glass:
            return liftedPanePoints(face.points)
        default:
            return face.points
        }
    }

    private static func floorPointsNeedReversing(_ points: [SIMD3<Float>]) -> Bool {
        guard points.count >= 3 else { return false }
        var signedArea: Float = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            signedArea += points[index].x * next.z - next.x * points[index].z
        }
        return signedArea > 0
    }

    /// Un ventaglio appoggiato al pavimento: pieno all'obiettivo, spento al
    /// bordo.
    ///
    /// Non è ritagliato sulla stanza, e non serve che lo sia: si spegne prima di
    /// arrivare dove finirebbe, quindi un bordo che sbordasse di mezzo metro non
    /// avrebbe comunque una forma da riconoscere. È la stessa ragione per cui la
    /// mappa di calore non ha bisogno del contorno del pavimento.
    static func cameraConeMesh(_ cone: FloorplanCameraCone, scene: FloorplanScene) -> MeshResource? {
        let centre = scene.bounds.center
        let apex = SIMD3(Float(cone.position.x) - centre.x,
                         scene.bounds.min.y - centre.y + 0.018,
                         Float(cone.position.y) - centre.z)
        let bearing = atan2(cone.direction.y, cone.direction.x)
        let halfSpread = Double.pi * 40 / 180
        let reach: Double = 4.2
        let steps = 18

        var positions: [SIMD3<Float>] = [apex]
        var uvs: [SIMD2<Float>] = [SIMD2(0.5, 0)]
        var indices: [UInt32] = []

        for step in 0...steps {
            let angle = bearing - halfSpread + halfSpread * 2 * Double(step) / Double(steps)
            positions.append(SIMD3(apex.x + Float(cos(angle) * reach),
                                   apex.y,
                                   apex.z + Float(sin(angle) * reach)))
            uvs.append(SIMD2(0.5, 1))
            if step > 0 {
                indices.append(contentsOf: [0, UInt32(step), UInt32(step + 1)])
            }
        }

        var descriptor = MeshDescriptor(name: "camera-cone")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 1, 0),
                                                       count: positions.count))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return try? MeshResource.generate(from: [descriptor])
    }

    /// Un quadrilatero sciolto, con la sua normale. Serve ai veli che non
    /// appartengono alla geometria della casa e si rifanno per conto loro.
    static func quadMesh(_ points: [SIMD3<Float>]) -> MeshResource? {
        guard points.count == 4 else { return nil }
        let normal = faceNormal(for: points)
        var descriptor = MeshDescriptor(name: "quad")
        descriptor.positions = MeshBuffers.Positions(points + points.reversed())
        descriptor.normals = MeshBuffers.Normals(Array(repeating: normal, count: 4)
                                                 + Array(repeating: -normal, count: 4))
        descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
        return try? MeshResource.generate(from: [descriptor])
    }

    static func faceNormal(for points: [SIMD3<Float>]) -> SIMD3<Float> {
        guard points.count >= 3 else { return [0, 1, 0] }
        let a = points[1] - points[0]
        let b = points[2] - points[0]
        let normal = simd_cross(a, b)
        let length = simd_length(normal)
        guard length > 0.0001 else { return [0, 1, 0] }
        return normal / length
    }

    private static func doorPanelPoints(for face: FloorplanScene.MeshFace) -> [SIMD3<Float>] {
        guard doorShouldOpen(face) else {
            return liftedPanePoints(face.points)
        }

        return openedDoorPoints(face)
    }

    private static func doorShouldOpen(_ face: FloorplanScene.MeshFace) -> Bool {
        face.openingKind == .door && face.wallKind == .interior
    }

    private static func openedDoorPoints(_ face: FloorplanScene.MeshFace) -> [SIMD3<Float>] {
        let points = face.points
        guard points.count == 4 else { return points }
        let angle: Float = face.flipSide ? .pi / 5.6 : -.pi / 5.6
        let hingeIndices: Set<Int> = face.flipSide ? [1, 2] : [0, 3]
        let pivot = face.flipSide ? points[1] : points[0]
        let opened = points.enumerated().map { index, point in
            guard !hingeIndices.contains(index) else { return point }
            return rotate(point, around: pivot, angle: angle)
        }
        let normal = faceNormal(for: points)
        return opened.map { $0 + normal * 0.01 }
    }

    private static func rotate(_ point: SIMD3<Float>,
                               around pivot: SIMD3<Float>,
                               angle: Float) -> SIMD3<Float> {
        let dx = point.x - pivot.x
        let dz = point.z - pivot.z
        return SIMD3(
            pivot.x + dx * cos(angle) - dz * sin(angle),
            point.y,
            pivot.z + dx * sin(angle) + dz * cos(angle)
        )
    }

    private static func doorEdgePoints(_ face: FloorplanScene.MeshFace) -> [SIMD3<Float>] {
        let opened = doorPanelPoints(for: face)
        guard opened.count == 4 else { return opened }

        let freeBottom = face.flipSide ? opened[0] : opened[1]
        let freeTop = face.flipSide ? opened[3] : opened[2]
        let hingeBottom = face.flipSide ? opened[1] : opened[0]
        let freeToHinge = hingeBottom - freeBottom
        let length = simd_length(freeToHinge)
        guard length > 0.0001 else { return opened }

        let edgeWidth: Float = min(0.045, length * 0.18)
        let inset = freeToHinge / length * edgeWidth
        let normal = faceNormal(for: opened) * 0.006

        return [
            freeBottom + normal,
            freeBottom + inset + normal,
            freeTop + inset + normal,
            freeTop + normal
        ]
    }

    private static func liftedPanePoints(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard points.count >= 3 else { return points }
        let normal = faceNormal(for: points)
        return points.map { $0 + normal * 0.015 }
    }


}

extension FloorplanScene.MeshFace.MaterialRole {
    static let renderOrder: [Self] = [
        .floor,
        .groundContact,
        .furniture,
        .door,
        .doorTrim,
        .doorHandle,
        .doorEdge,
        .frame,
        .balcony,
        .shutter,
        .wall,
        .wallContact,
        .wallGlow,
        .balconyTop,
        .wallTop,
        .glass
    ]
}
