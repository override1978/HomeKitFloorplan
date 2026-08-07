import SwiftUI
import RealityKit
import HomeKit
import UIKit

// Il ponte UIKit: `ARView`, gesti, e il coordinatore che aggiorna la scena in
// posto. Qui vive tutto cio' che ha uno stato di scena; la geometria pura sta
// nel renderer, la SwiftUI in `FloorplanRealityPreviewView`.

// MARK: - RealityFloorplanView

struct RealityFloorplanView: UIViewRepresentable {
    let scene: FloorplanScene
    let background: UIColor
    let sun: FloorplanSunLight
    let lamps: [FloorplanLamp]
    /// Con uno strato tematico attivo il colore del pavimento appartiene allo
    /// strato: le pozze e i coni dipinti delle lampade si spengono, restano il
    /// bulbo e la luce vera. Un pavimento colorato in Ambiente deve voler dire
    /// una cosa sola.
    let lampEffects: Bool
    let climate: [FloorplanClimateUnit]
    /// Le stanze da far brillare attraverso i vetri, di notte.
    let litRooms: Set<UUID>
    let awnings: [FloorplanAwning]
    let cameras: [FloorplanCameraCone]
    let flags: [RoomFlag]
    let cameraCommand: CameraCommand
    let onRoomSelected: (UUID?, String?) -> Void
    /// Toccare un oggetto lo comanda: quello che mostra lo stato è anche quello
    /// che lo cambia, senza un segnaposto in mezzo.
    let onTargetTapped: (FloorplanTapTarget) -> Void
    /// Tenendolo premuto si apre la sua scheda, quella del 2D. Il tocco breve
    /// comanda, la pressione lunga approfondisce: e' la coppia che iOS usa
    /// ovunque, e non aggiunge nessun comando visibile al modello.
    let onTargetHeld: (FloorplanTapTarget) -> Void
    /// Il coordinatore esce dalla prima persona anche da solo (doppio tocco):
    /// la vista deve saperlo per ritirare il bottone «esci».
    let onFirstPersonExit: () -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.environment.background = .color(background)
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.panned(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.pinched(_:)))
        pinch.delegate = context.coordinator
        view.addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        // Il doppio non fa aspettare il singolo (niente `require(toFail:)`):
        // il singolo seleziona la stanza, il doppio la inquadra — i due
        // effetti si compongono invece di competere.
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator
        view.addGestureRecognizer(doubleTap)

        // Non serve `require(toFail:)`: un tocco tenuto oltre la sua durata
        // massima **fallisce da solo**, quindi la pressione lunga non produce
        // anche un'accensione. Incatenarli avrebbe invece ritardato di mezzo
        // secondo ogni accensione, che e' il gesto piu' frequente.
        let hold = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.held(_:)))
        hold.delegate = context.coordinator
        view.addGestureRecognizer(hold)

        context.coordinator.background = background
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.onRoomSelected = onRoomSelected
        context.coordinator.onTargetTapped = onTargetTapped
        context.coordinator.onTargetHeld = onTargetHeld
        context.coordinator.onFirstPersonExit = onFirstPersonExit
        if context.coordinator.background != background {
            context.coordinator.background = background
            view.environment.background = .color(background)
        }
        context.coordinator.updateSceneIfNeeded(scene)
        context.coordinator.updateSun(sun)
        context.coordinator.updateLamps(lamps)
        context.coordinator.updateLampEffects(lampEffects)
        context.coordinator.updateClimate(climate)
        context.coordinator.updateLitWindows(litRooms)
        context.coordinator.updateAwnings(awnings)
        context.coordinator.updateCameraCones(cameras)
        context.coordinator.updateFlags(flags)
        context.coordinator.applyCameraCommandIfNeeded(cameraCommand)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scene: scene, sun: sun, cameraCommand: cameraCommand,
                    onRoomSelected: onRoomSelected,
                    onTargetTapped: onTargetTapped, onTargetHeld: onTargetHeld)
            .prepared(withLamps: lamps)
            .prepared(withClimate: climate)
            .prepared(withLitRooms: litRooms)
            .prepared(withAwnings: awnings)
            .prepared(withCameras: cameras)
            .prepared(with: flags)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var scene: FloorplanScene
        var sun: FloorplanSunLight
        var background: UIColor = .black
        var azimuth: Double = .pi / 4
        var elevation: Double = .pi / 5
        var distanceMultiplier: Float = 2.2
        private let anchor = AnchorEntity(world: .zero)
        private let contentRoot = Entity()
        private let camera = PerspectiveCamera()
        /// Tre direzionali invece di una.
        ///
        /// Con materiali PBR e una sola sorgente le facce che non la guardano
        /// diventano **nere**: nella realtà le riempie la luce rimbalzata, che
        /// RealityKit non calcola. Due luci deboli da direzioni opposte costano
        /// nulla e fanno il lavoro dell'ambiente, senza portarsi dietro un HDR.
        private let keyLight = DirectionalLight()
        private let fillLight = DirectionalLight()
        private let rimLight = DirectionalLight()
        /// Le macchie di sole vivono fuori dal contenuto: dipendono dall'ora, non
        /// dalla geometria, e si rifanno senza ricostruire la casa.
        private let sunPatchRoot = Entity()
        /// Le bandierine vivono fuori dal contenuto: cambiano con i sensori,
        /// non con la geometria, e vanno rigirate verso la telecamera a ogni
        /// spostamento.
        private let flagRoot = Entity()
        /// Le macchie di calore sui pavimenti: fuori dal contenuto, così
        /// cambiano coi sensori senza toccare la geometria.
        private let heatRoot = Entity()
        /// Il contorno della stanza selezionata: un canale suo, che non si
        /// somma alle velature di stato.
        private let selectionRoot = Entity()
        /// Le lampade accese: luci vere, non decalcomanie, quindi illuminano
        /// muri e pavimento come farebbero nella stanza.
        private let lampRoot = Entity()
        private let climateRoot = Entity()
        private let litWindowRoot = Entity()
        private let cameraRoot = Entity()
        private var cameras: [FloorplanCameraCone] = []
        private let awningRoot = Entity()
        private var awnings: [FloorplanAwning] = []
        /// Il telo di ogni tenda, tenuto in vita fra un aggiornamento e l'altro:
        /// la corsa cambia la **mesh**, non l'oggetto.
        private struct AwningNode {
            var entity: ModelEntity
            /// L'ombra che il telo getta sul pavimento del balcone: e' cio' che
            /// chiude il cerchio col sole vero — una tenda che non fa ombra non
            /// sta facendo il suo mestiere.
            var shadow: ModelEntity
            var geometry: FloorplanExtruder.AwningGeometry
            /// Quanto e' fuori **adesso**, sullo schermo.
            var shown: Double
            /// Quanto dovra' esserlo, secondo HomeKit.
            var target: Double
        }
        private var awningNodes: [UUID: AwningNode] = [:]
        private var awningTimer: Timer?
        private var litRooms: Set<UUID> = []
        private var builtLitRooms: Set<UUID>? = nil
        private var climate: [FloorplanClimateUnit] = []
        /// Il corpo di ogni unità, tenuto in vita fra un aggiornamento e l'altro:
        /// accendere un condizionatore ne cambia il **colore**, non la forma.
        private var climateNodes: [UUID: ModelEntity] = [:]
        private var lamps: [FloorplanLamp] = []
        /// Gli oggetti di ogni lampada, tenuti in vita fra un aggiornamento e
        /// l'altro: e' quello che permette di cambiare stato senza ricostruire.
        private struct LampNode {
            var bulb: ModelEntity
            /// Il pendino che aggancia il bulbo al soffitto: senza, una
            /// sospensione e' una palla a mezz'aria.
            var cord: ModelEntity
            var spot: SpotLight
            var halo: ModelEntity
            var pool: Entity?
            /// Firme di cio' che richiede geometria nuova: senza, ogni tocco
            /// rifarebbe mesh identiche.
            var beamKey: String = ""
            var poolKey: String = ""
        }
        private var lampNodes: [UUID: LampNode] = [:]
        private var lampEffectsEnabled = true
        /// Serve per regolare la luce d'ambiente, che di notte va abbassata:
        /// quella non appartiene a nessuna delle tre direzionali.
        private weak var view: ARView?
        private var flagLabels: [Entity] = []
        private var flagStems: [ModelEntity] = []
        /// L'etichetta di ogni stanza, tenuta in vita fra un aggiornamento e
        /// l'altro: cambia il testo, non l'oggetto.
        private struct FlagNode {
            var label: ModelEntity
            var signature: String
        }
        private var flagNodes: [UUID: FlagNode] = [:]
        private var builtHeatSignature = "\u{0}"
        private var builtAccentSignature = "\u{0}"
        private var flags: [RoomFlag] = []
        private var flagsSignature = ""
        private var installedSignature: String?
        private var handledCommandID: UUID
        /// Il punto che la camera guarda: la casa intera, o una stanza dopo un
        /// doppio tocco.
        private var focus: SIMD3<Float> = .zero
        private var focusRadius: Float?
        /// In prima persona la camera **sta** nel fuoco e guarda fuori; in
        /// orbita sta fuori e guarda il fuoco. Stessi tre numeri, verso opposto.
        private var firstPerson = false
        private var gestureStart: (azimuth: Double, elevation: Double)?
        private var roomNames: [UUID: String] = [:]
        private var roomWallEntities: [UUID: ModelEntity] = [:]
        private var selectedRoomID: UUID?
        var onRoomSelected: (UUID?, String?) -> Void
        var onTargetTapped: (FloorplanTapTarget) -> Void
        var onTargetHeld: (FloorplanTapTarget) -> Void
        var onFirstPersonExit: () -> Void = {}

        init(scene: FloorplanScene,
             sun: FloorplanSunLight,
             cameraCommand: CameraCommand,
             onRoomSelected: @escaping (UUID?, String?) -> Void,
             onTargetTapped: @escaping (FloorplanTapTarget) -> Void,
             onTargetHeld: @escaping (FloorplanTapTarget) -> Void) {
            self.scene = scene
            self.sun = sun
            self.handledCommandID = cameraCommand.id
            self.onRoomSelected = onRoomSelected
            self.onTargetTapped = onTargetTapped
            self.onTargetHeld = onTargetHeld
        }

        func prepared(withAwnings awnings: [FloorplanAwning]) -> Coordinator {
            self.awnings = awnings
            return self
        }

        /// Il telo insegue lo stato invece di saltarci.
        ///
        /// HomeKit riporta la corsa a pezzi — 100, 74, 51… — e prima ogni
        /// valore riestrudeva la casa: venti scatti pagati carissimi. Ora la
        /// tenda e' un oggetto vivo come le lampade: il valore nuovo diventa un
        /// **bersaglio**, e il telo ci scivola alla velocita' di una tenda vera.
        func updateAwnings(_ newAwnings: [FloorplanAwning]) {
            guard newAwnings != awnings else { return }
            let sameBodies = newAwnings.map(\.roomID).sorted() == awningNodes.keys.sorted()
                && newAwnings.allSatisfy { awning in
                    awningNodes[awning.roomID]?.geometry == awning.geometry
                }
            awnings = newAwnings
            guard sameBodies else { rebuildAwnings(); return }

            for awning in newAwnings {
                awningNodes[awning.roomID]?.target = awning.extended
            }
            animateAwningsIfNeeded()
        }

        /// Costruisce i teli **fermi al loro stato**: l'animazione e' per la
        /// corsa, non per l'apertura della vista.
        private func rebuildAwnings() {
            awningTimer?.invalidate()
            awningTimer = nil
            awningRoot.children.removeAll()
            awningNodes = [:]

            for awning in awnings {
                guard let mesh = awningMesh(awning.geometry, fraction: awning.extended)
                else { continue }
                let entity = ModelEntity(mesh: mesh,
                                         materials: [FloorplanMaterialCatalog.material(for: .awning)])
                entity.generateCollisionShapes(recursive: false)
                entity.name = "awning:\(awning.roomID.uuidString)"
                awningRoot.addChild(entity)

                var shadowMaterial = UnlitMaterial(color: UIColor(red: 0.12, green: 0.13,
                                                                  blue: 0.17, alpha: 1))
                shadowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.22))
                let shadow = ModelEntity(mesh: .generatePlane(width: 0.01, height: 0.01),
                                         materials: [shadowMaterial])
                awningRoot.addChild(shadow)

                let node = AwningNode(entity: entity,
                                      shadow: shadow,
                                      geometry: awning.geometry,
                                      shown: awning.extended,
                                      target: awning.extended)
                updateAwningShadow(node, fraction: awning.extended)
                awningNodes[awning.roomID] = node
            }
        }

        private func animateAwningsIfNeeded() {
            guard awningTimer == nil,
                  awningNodes.values.contains(where: { $0.shown != $0.target })
            else { return }

            awningTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                               repeats: true) { [weak self] _ in
                Task { @MainActor in self?.stepAwnings() }
            }
        }

        private func stepAwnings() {
            // Corsa completa in ventidue secondi. I nove della prima stesura
            // sembravano «da tenda vera» sulla carta, ma accanto a quella vera
            // il telo del modello arrivava con largo anticipo: un motore da
            // balcone ci mette venti-trenta secondi. HomeKit non espone la
            // durata del singolo motore, quindi e' una costante — se un giorno
            // serve per-accessorio, il posto e' l'adapter.
            let step = 1.0 / 22.0 / 30.0
            var stillMoving = false

            for (roomID, node) in awningNodes where node.shown != node.target {
                var node = node
                let delta = node.target - node.shown
                if abs(delta) <= step {
                    node.shown = node.target
                    // La collisione si rifa' solo a telo fermo: serve al tocco,
                    // e nessuno tocca una tenda mentre corre.
                    if let mesh = awningMesh(node.geometry, fraction: node.shown) {
                        node.entity.model?.mesh = mesh
                        node.entity.generateCollisionShapes(recursive: false)
                    }
                } else {
                    node.shown += step * (delta > 0 ? 1 : -1)
                    stillMoving = true
                    if let mesh = awningMesh(node.geometry, fraction: node.shown) {
                        node.entity.model?.mesh = mesh
                    }
                }
                updateAwningShadow(node, fraction: node.shown)
                awningNodes[roomID] = node
            }

            if !stillMoving {
                awningTimer?.invalidate()
                awningTimer = nil
            }
        }

        /// Il telo a una frazione qualsiasi della corsa, gia' nello spazio della
        /// scena. La discesa scala con l'uscita, cosi' la pendenza resta quella
        /// e il cassonetto non diventa una parete verticale.
        private func awningMesh(_ geometry: FloorplanExtruder.AwningGeometry,
                                fraction: Double) -> MeshResource? {
            let centre = scene.bounds.center
            let reach = max(geometry.minReach,
                            geometry.maxReach * min(1, max(0, fraction)))
            let drop = geometry.fullDrop * (reach / geometry.maxReach)

            func scenePoint(_ point: SIMD2<Double>, _ height: Double) -> SIMD3<Float> {
                SIMD3(Float(point.x), Float(height), Float(point.y)) - centre
            }

            let a0 = scenePoint(geometry.attachA, geometry.attachHeight)
            let b0 = scenePoint(geometry.attachB, geometry.attachHeight)
            let a1 = scenePoint(geometry.attachA + geometry.inward * reach,
                                geometry.attachHeight - drop)
            let b1 = scenePoint(geometry.attachB + geometry.inward * reach,
                                geometry.attachHeight - drop)

            // Righe lungo la discesa, in metri: la tenda si riga nel verso in
            // cui esce, e il passo non dipende da quanto e' fuori.
            let edge = simd_length(b0 - a0) / 0.22
            let run = Float(reach) / 0.22
            let quad = [a0, b0, b1, a1]
            let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(edge, 0),
                                       SIMD2(edge, run), SIMD2(0, run)]
            let normal = RealityFloorplanRenderer.faceNormal(for: quad)

            var descriptor = MeshDescriptor(name: "awning")
            descriptor.positions = MeshBuffers.Positions(quad + quad.reversed())
            descriptor.normals = MeshBuffers.Normals(Array(repeating: normal, count: 4)
                                                     + Array(repeating: -normal, count: 4))
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs + uvs.reversed())
            descriptor.primitives = .triangles([0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7])
            return try? MeshResource.generate(from: [descriptor])
        }

        func prepared(withCameras cones: [FloorplanCameraCone]) -> Coordinator {
            self.cameras = cones
            return self
        }

        func updateCameraCones(_ cones: [FloorplanCameraCone]) {
            guard cones != cameras else { return }
            cameras = cones
            rebuildCameraCones()
        }

        private func rebuildCameraCones() {
            cameraRoot.children.removeAll()
            guard !cameras.isEmpty,
                  let material = FloorplanMaterialCatalog.cameraConeMaterial()
            else { return }
            for cone in cameras {
                guard let mesh = RealityFloorplanRenderer.cameraConeMesh(cone, scene: scene)
                else { continue }
                cameraRoot.addChild(ModelEntity(mesh: mesh, materials: [material]))
            }
        }

        func prepared(withLitRooms rooms: Set<UUID>) -> Coordinator {
            self.litRooms = rooms
            return self
        }

        func updateLitWindows(_ rooms: Set<UUID>) {
            litRooms = rooms
            rebuildLitWindows()
        }

        /// Un velo caldo appoggiato ai vetri delle stanze accese.
        ///
        /// Non è una luce vera: una `PointLight` per stanza costerebbe e
        /// illuminerebbe anche l'esterno, che di notte deve restare buio. Qui
        /// interessa solo ciò che si vede **da fuori** — il vetro che brilla — ed
        /// è esattamente quello che si disegna.
        private func rebuildLitWindows() {
            guard builtLitRooms != litRooms else { return }
            builtLitRooms = litRooms
            litWindowRoot.children.removeAll()
            guard !litRooms.isEmpty,
                  let material = FloorplanMaterialCatalog.litWindowMaterial()
            else { return }

            let centre = scene.bounds.center
            for face in scene.faces where face.role == .glass && face.points.count == 4 {
                guard let roomID = face.roomID, litRooms.contains(roomID) else { continue }
                let normal = RealityFloorplanRenderer.faceNormal(for: face.points)
                // ⚠️ Un velo **per faccia del vetro**, non uno solo: il verso
                // della normale non e' affidabile, quindi un velo singolo
                // finiva a caso sul lato interno o esterno — e da fuori le
                // finestre accese sembravano spente. Due centimetri per parte:
                // il vetro sta in mezzo allo spessore, si resta nel vano.
                for side: Float in [0.02, -0.02] {
                    let quad = face.points.map { $0 + normal * side - centre }
                    guard let mesh = RealityFloorplanRenderer.quadMesh(quad) else { continue }
                    litWindowRoot.addChild(ModelEntity(mesh: mesh, materials: [material]))
                }
            }
        }

        func prepared(withClimate units: [FloorplanClimateUnit]) -> Coordinator {
            self.climate = units
            return self
        }

        /// Un'unità si ricostruisce solo se cambia **dove sta o com'è fatta**.
        /// Accendersi e spegnersi cambia il materiale, e quello si sostituisce
        /// in posto — la lezione già pagata con le lampade che sparivano e
        /// ricomparivano a ogni interruttore.
        func updateClimate(_ newUnits: [FloorplanClimateUnit]) {
            guard newUnits != climate else { return }
            let sameBodies = newUnits.map(\.accessoryUUID).sorted() == climateNodes.keys.sorted()
                && newUnits.allSatisfy { unit in
                    climate.first { $0.accessoryUUID == unit.accessoryUUID }
                        .map { $0.position == unit.position && $0.height == unit.height
                               && $0.form == unit.form && $0.bearing == unit.bearing }
                        ?? false
                }
            climate = newUnits
            if sameBodies { applyClimateStates() } else { rebuildClimate() }
        }

        private func rebuildClimate() {
            climateRoot.children.removeAll()
            climateNodes = [:]
            let centre = scene.bounds.center
            let floorY = scene.bounds.min.y

            for unit in climate {
                let size = unit.form.size
                let material = FloorplanMaterialCatalog.deviceBodyMaterial(tint: unit.tint)
                let body: ModelEntity
                if unit.form == .radiator {
                    // Un termosifone si riconosce dagli **elementi**: una
                    // lastra liscia in basso e' uno zoccolo qualsiasi.
                    body = ModelEntity()
                    let count = 7
                    let step = size.x / Float(count)
                    for index in 0..<count {
                        let fin = ModelEntity(
                            mesh: .generateBox(size: SIMD3(step * 0.62, size.y, size.z),
                                               cornerRadius: 0.012),
                            materials: [material]
                        )
                        fin.position = SIMD3(-size.x / 2 + step * (Float(index) + 0.5), 0, 0)
                        body.addChild(fin)
                    }
                } else {
                    body = ModelEntity(
                        mesh: .generateBox(size: size, cornerRadius: size.y * 0.22),
                        materials: [material]
                    )
                }
                body.position = SIMD3(Float(unit.position.x) - centre.x,
                                      floorY - centre.y + Float(unit.height),
                                      Float(unit.position.y) - centre.z)
                body.orientation = simd_quatf(angle: Float(unit.bearing), axis: SIMD3(0, 1, 0))
                // Il bersaglio della pressione lunga: piu' largo del corpo,
                // perche' una valvola a schermo e' un francobollo.
                body.collision = CollisionComponent(shapes: [.generateSphere(radius: 0.30)])
                body.name = "climate:\(unit.accessoryUUID.uuidString)"

                // Il pallino di modalità: «acceso in freddo» si deve vedere
                // anche quando il compressore riposa e il corpo resta bianco.
                if unit.form != .securityPanel {
                    let dot = ModelEntity(
                        mesh: .generateSphere(radius: 0.035),
                        materials: [FloorplanMaterialCatalog.deviceBodyMaterial(
                            tint: unit.modeTint ?? .white)]
                    )
                    dot.name = "modeDot"
                    dot.position = SIMD3(size.x * 0.32, size.y * 0.22, size.z / 2 + 0.03)
                    dot.isEnabled = unit.modeTint != nil
                    body.addChild(dot)
                }
                climateRoot.addChild(body)
                climateNodes[unit.accessoryUUID] = body
            }
        }

        private func applyClimateStates() {
            for unit in climate {
                guard let node = climateNodes[unit.accessoryUUID] else { continue }
                let material = FloorplanMaterialCatalog.deviceBodyMaterial(tint: unit.tint)
                if node.model != nil {
                    node.model?.materials = [material]
                } else {
                    // Il radiatore e' un contenitore: la tinta va agli elementi.
                    for case let fin as ModelEntity in node.children
                    where fin.name != "modeDot" {
                        fin.model?.materials = [material]
                    }
                }
                if let dot = node.findEntity(named: "modeDot") as? ModelEntity {
                    dot.isEnabled = unit.modeTint != nil
                    if let modeTint = unit.modeTint {
                        dot.model?.materials =
                            [FloorplanMaterialCatalog.deviceBodyMaterial(tint: modeTint)]
                    }
                }
            }
        }

        func prepared(with flags: [RoomFlag]) -> Coordinator {
            self.flags = flags
            return self
        }

        func updateFlags(_ newFlags: [RoomFlag]) {
            let signature = newFlags
                .map { "\($0.roomID)=\($0.title)=\($0.value)" }
                .sorted()
                .joined(separator: "|")
            guard signature != flagsSignature else { return }
            // Le stesse stanze con valori diversi si aggiornano in posto; solo
            // un insieme diverso — un altro filtro che scopre stanze nuove, o
            // un'altra planimetria — merita di ricostruire gli steli.
            let sameRooms = Set(newFlags.map(\.roomID)) == Set(flagNodes.keys)
            flagsSignature = signature
            flags = newFlags
            if sameRooms { applyFlagStates() } else { rebuildFlags() }
            applyRoomAccents()
            rebuildHeat()
            rebuildLamps()
        }

        /// I muri interni della stanza prendono il colore del suo stato.
        ///
        /// Solo quelle che chiedono attenzione: accendere anche le stanze a
        /// posto vuol dire non accendere niente, perche' l'occhio non sa piu'
        /// dove andare.
        /// La mappa di calore è geometria, e la geometria dipende solo da
        /// **quali** stanze sono accese e di che colore — non dal valore.
        ///
        /// Cambiare filtro la rifà davvero, perché scopre stanze diverse. Una
        /// temperatura che si muove di un decimo di grado, dentro la stessa
        /// fascia, non cambia niente di ciò che è disegnato.
        private var heatSignature: String {
            flags.filter(\.needsAttention)
                .map { "\($0.roomID)|\($0.accent?.description ?? "")|\(Int($0.brightnessKey * 8))" }
                .sorted()
                .joined(separator: ",")
        }

        private func rebuildHeat() {
            guard heatSignature != builtHeatSignature else { return }
            builtHeatSignature = heatSignature
            heatRoot.children.removeAll()
            for entity in RealityFloorplanRenderer.roomHeatEntities(for: flags, scene: scene) {
                heatRoot.addChild(entity)
            }
        }

        /// Solo cio' che decide il colore di un muro: quale stanza, e di che
        /// tinta. Il numero scritto sulla bandierina cambia a ogni lettura del
        /// sensore e qui non sposta niente.
        private var accentSignature: String {
            flags.filter(\.needsAttention)
                .map { "\($0.roomID)|\($0.accent?.description ?? "")" }
                .sorted()
                .joined(separator: ",")
        }

        private func applyRoomAccents() {
            guard accentSignature != builtAccentSignature else { return }
            builtAccentSignature = accentSignature
            let accents = Dictionary(
                uniqueKeysWithValues: flags.filter(\.needsAttention)
                    .compactMap { flag in flag.accent.map { (flag.roomID, $0) } }
            )
            for (roomID, entity) in roomWallEntities {
                guard let accent = accents[roomID],
                      let material = FloorplanMaterialCatalog.wallGlowMaterial(accent)
                else {
                    entity.isEnabled = false
                    continue
                }
                entity.model?.materials = [material]
                entity.isEnabled = true
            }
        }

        /// Costruisce gli steli **una volta per insieme di stanze**.
        ///
        /// Cambiare filtro o aggiornare un sensore non sposta nessuna
        /// bandierina: cambia cosa c'è scritto sopra. Ricostruirle tutte voleva
        /// dire ridisegnare undici texture per una temperatura che si muove di
        /// un decimo di grado.
        private func rebuildFlags() {
            flagRoot.children.removeAll()
            flagLabels = []
            flagStems = []
            flagNodes = [:]
            for flag in RealityFloorplanRenderer.flagEntities(for: flags, scene: scene) {
                flagRoot.addChild(flag.root)
                flagLabels.append(flag.label)
                flagStems.append(flag.stem)
                flagNodes[flag.roomID] = FlagNode(label: flag.label, signature: signature(of: flag.roomID))
            }
            orientFlags()
        }

        /// Aggiorna solo le etichette il cui **testo è cambiato davvero**.
        private func applyFlagStates() {
            for flag in flags {
                guard var node = flagNodes[flag.roomID] else { continue }
                let current = "\(flag.title)|\(flag.value)|\(flag.accent?.description ?? "")"
                guard node.signature != current else { continue }
                if let label = FloorplanMaterialCatalog.flagLabelMaterial(title: flag.title,
                                                                         value: flag.value,
                                                                         accent: flag.accent) {
                    // La capsula si stringe sul testo, quindi cambiando testo
                    // cambia anche il piano che la porta.
                    node.label.model?.mesh = RealityFloorplanRenderer.flagLabelMesh(aspect: label.aspect)
                    node.label.model?.materials = [label.material]
                }
                node.signature = current
                flagNodes[flag.roomID] = node
            }
        }

        private func signature(of roomID: UUID) -> String {
            guard let flag = flags.first(where: { $0.roomID == roomID }) else { return "" }
            return "\(flag.title)|\(flag.value)|\(flag.accent?.description ?? "")"
        }

        /// Le etichette guardano la telecamera **davvero**, non solo di lato.
        ///
        /// Con il solo raddrizzamento sull'asse verticale restavano in piedi:
        /// viste da una telecamera alta finivano di scorcio e schiacciate, e più
        /// si inclinava la casa meno si leggevano. Aggiungendo l'inclinazione si
        /// mettono in faccia a chi guarda da qualunque angolazione.
        ///
        /// Il rollio resta a zero — la rotazione si compone in questo ordine
        /// apposta — così il testo è orizzontale sullo schermo comunque.
        private func orientFlags() {
            let orientation = simd_quatf(angle: Float(azimuth), axis: SIMD3(0, 1, 0))
                * simd_quatf(angle: -Float(elevation), axis: SIMD3(1, 0, 0))
            for label in flagLabels { label.orientation = orientation }
        }

        func prepared(withLamps lamps: [FloorplanLamp]) -> Coordinator {
            self.lamps = lamps
            return self
        }

        func updateLampEffects(_ enabled: Bool) {
            guard enabled != lampEffectsEnabled else { return }
            lampEffectsEnabled = enabled
            applyLampStates()
        }

        func updateLamps(_ newLamps: [FloorplanLamp]) {
            guard lamps != newLamps else { return }
            // Le stesse lampade in stato diverso si aggiornano in posto; solo
            // un insieme diverso — cioè un'altra planimetria — merita di
            // ricostruire.
            let sameSet = Set(newLamps.map(\.accessoryUUID)) == Set(lampNodes.keys)
            lamps = newLamps
            if sameSet { applyLampStates() } else { rebuildLamps() }
        }

        /// Una `PointLight` per lampada accesa.
        ///
        /// Luce vera e non una macchia dipinta: illumina i muri intorno, si
        /// attenua con la distanza e si somma alle altre come farebbe in una
        /// stanza. Di giorno non si vede — ed è giusto così, perché di giorno
        /// una lampada accesa non si vede.
        /// Costruisce **una volta** gli oggetti di ogni lampada.
        ///
        /// ⚠️ Si ricostruisce solo quando cambia l'**insieme** delle lampade —
        /// cioè al cambio di planimetria. Un acceso/spento non è un cambio di
        /// scena: prima svuotava e ricreava tutto, e si vedeva a occhio nudo
        /// sparire e riapparire mezza casa per accendere una luce.
        private func rebuildLamps() {
            lampRoot.children.removeAll()
            lampNodes = [:]
            let centre = scene.bounds.center
            let floorY = scene.bounds.min.y

            for lamp in lamps {
                // ⚠️ **Sopra la linea dei muri.** A 2,05 m un bulbo appoggiato a
                // una parete finisce *dentro* il muro, che arriva a 2,4: sparisce
                // e sembra che la lampada non esista. A 2,5 sta sempre in aria
                // libera, si vede da ogni angolazione, e il fascio punta in basso
                // lo stesso.
                let place = SIMD3(Float(lamp.position.x) - centre.x,
                                  floorY - centre.y + Float(lamp.height),
                                  Float(lamp.position.y) - centre.z)

                // Il bulbo c'è **sempre**, acceso o spento: se esistesse solo da
                // acceso non ci sarebbe niente da toccare per accenderlo. Spento
                // è un puntino discreto — un'icona ruberebbe la scena a una casa
                // che ne ha già dieci.
                let bulb = ModelEntity(
                    mesh: .generateSphere(radius: 0.15),
                    materials: [FloorplanMaterialCatalog.bulbMaterial(colour: lamp.colour,
                                                                     isOn: lamp.isOn)]
                )
                bulb.position = place
                // Il bersaglio è l'oggetto stesso, non un segnaposto accanto: la
                // sfera di collisione è più larga del bulbo perché a schermo
                // resta comunque un dito piccolo.
                bulb.collision = CollisionComponent(shapes: [.generateSphere(radius: 0.34)])
                bulb.name = "lamp:\(lamp.accessoryUUID.uuidString)"
                lampRoot.addChild(bulb)

                // Il pendino: mesh unitaria scalata in `apply`, cosi' il
                // cursore dell'altezza lo allunga senza rigenerare niente.
                let cord = ModelEntity(
                    mesh: .generateBox(size: SIMD3(0.014, 1, 0.014)),
                    materials: [FloorplanMaterialCatalog.deviceBodyMaterial(
                        tint: UIColor(white: 0.55, alpha: 1))]
                )
                lampRoot.addChild(cord)

                // **Faretto, non lampadina nuda.** Una `PointLight` irradia in
                // tutte le direzioni e su un modello senza soffitto si perde:
                // nessun fascio, nessuna pozza netta. Un faretto puntato in basso
                // è anche ciò che c'è davvero — spot nel cartongesso,
                // sospensione sul tavolo.
                let light = SpotLight()
                light.light.innerAngleInDegrees = 32
                light.light.outerAngleInDegrees = 72
                light.shadow = SpotLightComponent.Shadow()
                light.position = place
                light.look(at: SIMD3(place.x, floorY - centre.y, place.z),
                           from: place,
                           relativeTo: nil)
                lampRoot.addChild(light)

                // Il fascio, non un alone: una palla luminosa attorno alla
                // lampada sembra un pianeta e non dice da che parte va la luce.
                let beamHeight = place.y - (floorY - centre.y) - 0.02
                // ⚠️ Il ripiego NON e' una sfera. Con il materiale del fascio
                // addosso, una sfera e' un pallone lattiginoso a mezz'aria — il
                // sospettato numero uno di ogni «cos'e' quel coso grigio». Se il
                // cono non si puo' costruire, meglio nessun velo: la luce vera
                // del faretto c'e' comunque.
                let aura = ModelEntity(
                    mesh: RealityFloorplanRenderer.lampBeamMesh(height: beamHeight,
                                                                outerAngleDegrees: RealityFloorplanRenderer.beamAngle)
                        ?? .generatePlane(width: 0.001, height: 0.001),
                    materials: [FloorplanMaterialCatalog.lampBeamMaterial(colour: lamp.colour,
                                                                          brightness: 1)
                                ?? UnlitMaterial(color: .clear)]
                )
                // ⚠️ L'apice del cono sta **sul bulbo**, per tutte le direzioni.
                // Il distacco di 17 cm era il rimedio a un bulbo traslucido che
                // il fascio tingeva — ma il bulbo ora e' bianco opaco, e il velo
                // caldo davanti al bianco lo scalda invece di sporcarlo. Il
                // distacco invece faceva danni suoi: con «in alto» il cono
                // capovolto avvolgeva il bulbo e le tre direzioni sembravano
                // uguali; con «in basso» restava un pallino che fluttua staccato
                // dal proprio fascio.
                aura.position = place
                lampRoot.addChild(aura)

                var node = LampNode(bulb: bulb, cord: cord, spot: light, halo: aura, pool: nil)
                lampNodes[lamp.accessoryUUID] = node
                apply(lamp, to: &node)
                lampNodes[lamp.accessoryUUID] = node
            }
            // I dischi appena nati vanno girati subito verso la telecamera, o
            // restano di taglio fino al primo movimento.
            orientFlags()
        }

        /// Aggiorna in posto: nessuna entità nasce o muore, cambiano solo
        /// materiali, intensità e visibilità. È ciò che toglie lo sfarfallio.
        private func applyLampStates() {
            for lamp in lamps {
                guard var node = lampNodes[lamp.accessoryUUID] else { continue }
                apply(lamp, to: &node)
                lampNodes[lamp.accessoryUUID] = node
            }
        }

        private func apply(_ lamp: FloorplanLamp, to node: inout LampNode) {
            let centre = scene.bounds.center
            let floorY = scene.bounds.min.y
            let place = SIMD3(Float(lamp.position.x) - centre.x,
                              floorY - centre.y + Float(lamp.height),
                              Float(lamp.position.y) - centre.z)

            node.bulb.position = place
            // Dal soffitto alla cima del bulbo. Sotto i cinque centimetri non
            // e' una sospensione, e' un faretto: niente filo.
            let ceilingY = scene.bounds.max.y - centre.y
            let gap = ceilingY - (place.y + 0.15)
            node.cord.isEnabled = gap > 0.05
            if gap > 0.05 {
                node.cord.position = SIMD3(place.x, place.y + 0.15 + gap / 2, place.z)
                node.cord.scale = SIMD3(1, gap, 1)
            }
            node.spot.position = place
            node.halo.position = place

            node.bulb.model?.materials = [
                FloorplanMaterialCatalog.bulbMaterial(colour: lamp.colour, isOn: lamp.isOn)
            ]

            node.spot.isEnabled = lamp.isOn
            // ⚠️ **Senza ombra la luce attraversa i muri.** Un faretto vicino a
            // una parete esterna la illuminava anche **da fuori**, come se il
            // muro non ci fosse: di sera la casa perdeva i suoi contorni. Solo
            // sulle lampade accese, perche' ognuna costa una mappa d'ombra e le
            // spente non hanno niente da proiettare.
            node.spot.shadow = lamp.isOn ? SpotLightComponent.Shadow() : nil
            node.spot.light.color = lamp.colour
            // ⚠️ **La lampada deve vedersi sul tavolo sempre**: e' stato, non
            // fotometria. Di giorno serve il fattore grosso perche' c'e' un
            // key da 3000 lux da battere; di sera ne serve comunque uno,
            // perche' la prima taratura — pensata per non bruciare muri quasi
            // bianchi — lasciava la pozza visibile solo a zoom ravvicinato.
            let boost: Float = sun.isAboveHorizon ? 3.3 : 2.0
            node.spot.light.intensity = boost * Float(1_400 + 4_800 * lamp.brightness)
            node.spot.light.attenuationRadius = Float(3.6 + 2.8 * lamp.brightness)
            node.spot.light.outerAngleInDegrees = lamp.direction == .around ? 160 : 72
            // Il faretto guarda dove punta la luce. `look` orienta l'entità, e
            // basta cambiare il bersaglio per rovesciare il fascio.
            let target = lamp.direction == .up
                ? SIMD3(place.x, place.y + 2, place.z)
                : SIMD3(place.x, floorY - centre.y, place.z)
            node.spot.look(at: target, from: place, relativeTo: nil)

            // Il cono si vede solo quando ha una direzione: «intorno» non e' un
            // fascio, e disegnarlo comunque darebbe di nuovo l'effetto pianeta.
            let showsBeam = lamp.isOn && lamp.direction != .around && lampEffectsEnabled
            node.halo.isEnabled = showsBeam
            if showsBeam, node.beamKey != lamp.beamKey {
                let height = lamp.direction == .up
                    ? Float(0.9)
                    : max(0.2, place.y - (floorY - centre.y) - 0.02)
                if let mesh = RealityFloorplanRenderer.lampBeamMesh(height: height,
                                                                    outerAngleDegrees: RealityFloorplanRenderer.beamAngle) {
                    node.halo.model?.mesh = mesh
                }
                node.halo.orientation = lamp.direction == .up
                    ? simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
                    : simd_quatf(angle: 0, axis: SIMD3(0, 1, 0))
                node.beamKey = lamp.beamKey
            }
            if let beam = FloorplanMaterialCatalog.lampBeamMaterial(colour: lamp.colour,
                                                                    brightness: lamp.brightness) {
                node.halo.model?.materials = [beam]
            }

            // La pozza dipende dalla geometria, quindi si rifa' solo quando
            // cambia davvero. Una luce puntata in alto non ne fa nessuna.
            let wantsPool = lamp.isOn && lamp.direction != .up && lampEffectsEnabled
            if wantsPool, node.poolKey != lamp.poolKey {
                node.pool?.removeFromParent()
                node.pool = RealityFloorplanRenderer.lampPoolEntity(for: lamp, scene: scene)
                if let pool = node.pool { lampRoot.addChild(pool) }
                node.poolKey = lamp.poolKey
            }
            node.pool?.isEnabled = wantsPool
        }

        func updateSun(_ newSun: FloorplanSunLight) {
            guard sun != newSun else { return }
            sun = newSun
            configureLights()
            rebuildSunPatches()
            // L'ombra della tenda dipende dal sole quanto dal telo.
            for (roomID, node) in awningNodes {
                updateAwningShadow(node, fraction: node.shown)
                awningNodes[roomID] = node
            }
        }

        /// L'ombra del telo, proiettata a terra lungo il sole — la stessa
        /// proiezione delle macchie che entrano dai vetri, al contrario: li'
        /// il sole passa, qui si ferma.
        private func updateAwningShadow(_ node: AwningNode, fraction: Double) {
            guard sun.isAboveHorizon, sun.direction.y > 0.06,
                  fraction > 0.06,
                  let mesh = awningShadowMesh(node.geometry, fraction: fraction)
            else {
                node.shadow.isEnabled = false
                return
            }
            node.shadow.model?.mesh = mesh
            node.shadow.isEnabled = true
        }

        private func awningShadowMesh(_ geometry: FloorplanExtruder.AwningGeometry,
                                      fraction: Double) -> MeshResource? {
            let centre = scene.bounds.center
            let reach = max(geometry.minReach, geometry.maxReach * min(1, max(0, fraction)))
            let drop = geometry.fullDrop * (reach / geometry.maxReach)
            let floorY = scene.bounds.min.y

            func scenePoint(_ point: SIMD2<Double>, _ height: Double) -> SIMD3<Float> {
                SIMD3(Float(point.x), Float(height), Float(point.y)) - centre
            }
            let corners = [
                scenePoint(geometry.attachA, geometry.attachHeight),
                scenePoint(geometry.attachB, geometry.attachHeight),
                scenePoint(geometry.attachB + geometry.inward * reach, geometry.attachHeight - drop),
                scenePoint(geometry.attachA + geometry.inward * reach, geometry.attachHeight - drop)
            ]
            let landed = corners.map { point -> SIMD3<Float> in
                let travel = (point.y - (floorY - centre.y)) / sun.direction.y
                let ground = point - sun.direction * travel
                return SIMD3(ground.x, floorY - centre.y + 0.012, ground.z)
            }
            return RealityFloorplanRenderer.quadMesh(landed)
        }

        private func rebuildSunPatches() {
            sunPatchRoot.children.removeAll()
            guard let patch = RealityFloorplanRenderer.sunPatchEntity(for: scene, sun: sun) else { return }
            sunPatchRoot.addChild(patch)
        }

        func install(in view: ARView) {
            self.view = view
            camera.camera.fieldOfViewInDegrees = 38

            anchor.addChild(contentRoot)
            anchor.addChild(camera)
            anchor.addChild(keyLight)
            anchor.addChild(fillLight)
            anchor.addChild(rimLight)
            anchor.addChild(sunPatchRoot)
            anchor.addChild(flagRoot)
            anchor.addChild(heatRoot)
            anchor.addChild(selectionRoot)
            anchor.addChild(lampRoot)
            anchor.addChild(climateRoot)
            anchor.addChild(litWindowRoot)
            anchor.addChild(cameraRoot)
            anchor.addChild(awningRoot)
            view.scene.anchors.append(anchor)

            updateSceneIfNeeded(scene)
            builtLitRooms = nil
            rebuildLitWindows()
            rebuildCameraCones()
            rebuildClimate()
            configureLights()
            updateCamera()
        }

        /// Le luci sono **fisse rispetto al modello**, non alla telecamera.
        ///
        /// Se seguissero l'orbita, ogni faccia resterebbe illuminata sempre
        /// uguale mentre giri: sparirebbe proprio l'indizio che fa leggere il
        /// volume. Il sole sta fermo e la casa gira, come nella realtà.
        private func configureLights() {
            // Intensità in lux. RealityKit in modalità non-AR applica già una
            // luce d'ambiente di default: queste tre si **sommano** a quella,
            // quindi valori alti bruciano il bianco dei muri invece di
            // illuminarli. Se il modello risulta piatto si alza solo la key.
            let radius = max(scene.bounds.radius, 1)

            // ⚠️ **Il rapporto fra key e riempimento decide tutto.** Prima
            // fill e rim sommavano il 47% della key, con l'ambiente al massimo
            // sopra: la faccia in ombra riceveva quasi quanto quella
            // illuminata, quindi muri piatti e luminescenti e ombre deboli.
            // Ora stanno al 13%, che è la fascia in cui lavora
            // l'illuminazione architettonica.
            //
            // Di notte non basta cambiare colore alla key: se riempimento e
            // ambiente restano quelli del giorno, la casa resta luminosa come a
            // mezzogiorno e la notte non si legge. E le ombre **non si spengono**
            // — anche la luna le fa, e senza il volume si appiattisce.
            let isDay = sun.isAboveHorizon

            keyLight.light.intensity = isDay ? 3_000 : 760
            keyLight.light.color = isDay
                ? sunColour(atElevation: sun.elevationDegrees)
                : UIColor(red: 0.66, green: 0.76, blue: 1.0, alpha: 1)
            keyLight.shadow = DirectionalLightComponent.Shadow(
                maximumDistance: radius * 6,
                depthBias: 1.8
            )
            // Sotto l'orizzonte `sun.direction` punta comunque nella direzione
            // giusta, tenuta a dieci gradi dal clamp: la luna sta dove sta il
            // sole, il che è falso ma dà un'ombra plausibile e coerente.
            keyLight.look(at: .zero, from: sun.direction * radius * 3, relativeTo: nil)

            // ⚠️ Quasi neutro, non azzurro. Il riempimento e' cio' che colora
            // le facciate **in ombra**: con un fill blu e il key caldo, la
            // faccia al sole diventava crema e le altre grigio-azzurre — due
            // vernici, non luce e ombra. Un residuo di freddo resta (l'ombra
            // vera e' piu' fredda della luce), ma la forbice si stringe.
            fillLight.light.intensity = isDay ? 420 : 110
            fillLight.light.color = UIColor(red: 0.93, green: 0.95, blue: 1.0, alpha: 1)
            fillLight.shadow = nil
            fillLight.look(at: .zero,
                           from: SIMD3(radius * 2.6, radius * 1.4, -radius * 2.2),
                           relativeTo: nil)

            rimLight.light.intensity = isDay ? 160 : 60
            rimLight.light.color = UIColor(white: 1, alpha: 1)
            rimLight.shadow = nil
            rimLight.look(at: .zero,
                          from: SIMD3(radius * 0.4, radius * 0.5, radius * 3.0),
                          relativeTo: nil)

            // L'ambiente di default di RealityKit non passa da queste tre luci:
            // senza abbassarlo, di notte i muri restano bianchi qualunque cosa
            // si faccia alle direzionali.
            view?.environment.lighting.intensityExponent = isDay ? 0.60 : 0.30
        }

        func updateSceneIfNeeded(_ newScene: FloorplanScene) {
            scene = newScene
            guard installedSignature != newScene.renderSignature else { return }
            installedSignature = newScene.renderSignature

            contentRoot.children.removeAll()
            selectedRoomID = nil
            selectionRoot.children.removeAll()
            let rendered = RealityFloorplanRenderer.entity(for: newScene, background: background)
            roomWallEntities = rendered.roomWallEntities
            roomNames = rendered.roomNames
            contentRoot.addChild(rendered.root)
            configureLights()
            rebuildSunPatches()
            rebuildFlags()
            applyRoomAccents()
            rebuildHeat()
            rebuildLamps()
            rebuildAwnings()
            // ⚠️ Fuori dal giro di aggiornamento. `updateSceneIfNeeded` viene
            // chiamata da `updateUIView`, cioè **durante** l'update della vista:
            // scrivere lì uno `@State` è il «Modifying state during view update»
            // che compariva in console, e SwiftUI lo dichiara comportamento
            // indefinito.
            let notify = onRoomSelected
            DispatchQueue.main.async { notify(nil, nil) }
        }

        func updateCamera() {
            if firstPerson {
                let direction = SIMD3(cos(Float(elevation)) * sin(Float(azimuth)),
                                      sin(Float(elevation)),
                                      cos(Float(elevation)) * cos(Float(azimuth)))
                camera.look(at: focus + direction, from: focus, relativeTo: nil)
            } else {
                camera.look(at: focus, from: focus + orbitOffset, relativeTo: nil)
            }
            orientFlags()
            applyStemVisibility()
        }

        /// Sotto quest'angolo i pali delle bandierine trapassano mobili e
        /// facciate: a camera bassa restano le etichette, spariscono gli steli.
        private func applyStemVisibility() {
            let showStems = elevation > 0.38
            for stem in flagStems where stem.isEnabled != showStems {
                stem.isEnabled = showStems
            }
        }

        func applyCameraCommandIfNeeded(_ command: CameraCommand) {
            guard handledCommandID != command.id else { return }
            handledCommandID = command.id
            focus = .zero
            focusRadius = nil
            firstPerson = false
            camera.camera.fieldOfViewInDegrees = 38
            switch command.preset {
            case .top:
                elevation = 1.45
                distanceMultiplier = 2.5
            case .angle:
                azimuth = .pi / 4
                elevation = .pi / 5
                distanceMultiplier = 2.2
            case .front:
                elevation = 0.16
                distanceMultiplier = 1.9
            case .inside(let roomID):
                enterRoom(roomID)
                return
            }
            updateCamera()
        }

        /// Doppio tocco su una stanza: la camera la inquadra, mantenendo
        /// l'angolo. Sul vuoto, torna alla casa intera.
        /// I piedi al centro della stanza, gli occhi a un metro e mezzo:
        /// trascinare gira lo sguardo, il doppio tocco riporta fuori.
        private func enterRoom(_ roomID: UUID) {
            let points = scene.faces
                .filter { $0.role == .floor && $0.roomID == roomID }
                .flatMap(\.points)
            guard let first = points.first else { return }
            var minP = first, maxP = first
            for point in points {
                minP = SIMD3(min(minP.x, point.x), min(minP.y, point.y), min(minP.z, point.z))
                maxP = SIMD3(max(maxP.x, point.x), max(maxP.y, point.y), max(maxP.z, point.z))
            }
            let centre = scene.bounds.center
            let roomCentre = (minP + maxP) / 2 - centre
            focus = SIMD3(roomCentre.x, roomCentre.y + 1.5, roomCentre.z)
            firstPerson = true
            // Leggermente in giu' e **grandangolo**: a 38 gradi — il tele
            // giusto per l'orbita — una stanza vera e' claustrofobica, si vede
            // mezza parete e ci si perde la casa. A 68 si sta in una stanza.
            elevation = -0.12
            camera.camera.fieldOfViewInDegrees = 68
            updateCamera()
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? ARView else { return }
            // Da dentro, il doppio tocco e' l'uscita: si torna al tre quarti.
            if firstPerson {
                firstPerson = false
                camera.camera.fieldOfViewInDegrees = 38
                focus = .zero
                focusRadius = nil
                azimuth = .pi / 4
                elevation = .pi / 5
                distanceMultiplier = 2.2
                updateCamera()
                let notify = onFirstPersonExit
                DispatchQueue.main.async { notify() }
                return
            }
            if let entity = view.entity(at: recognizer.location(in: view)),
               let roomID = roomID(from: entity) {
                frame(roomID: roomID)
            } else {
                focus = .zero
                focusRadius = nil
                updateCamera()
            }
        }

        private func frame(roomID: UUID) {
            let points = scene.faces
                .filter { $0.role == .floor && $0.roomID == roomID }
                .flatMap(\.points)
            guard let first = points.first else { return }

            var minP = first, maxP = first
            for point in points {
                minP = SIMD3(min(minP.x, point.x), min(minP.y, point.y), min(minP.z, point.z))
                maxP = SIMD3(max(maxP.x, point.x), max(maxP.y, point.y), max(maxP.z, point.z))
            }
            let centre = scene.bounds.center
            let roomCentre = (minP + maxP) / 2 - centre
            // Il fuoco sta a mezza altezza stanza, non a terra: guardare il
            // pavimento taglierebbe fuori i muri.
            focus = SIMD3(roomCentre.x, roomCentre.y + 1.1, roomCentre.z)
            focusRadius = max(simd_length(maxP - minP) / 2, 1.2)
            updateCamera()
        }

        /// Radente vuol dire caldo. È l'unica correzione di colore che serve
        /// perché una scena letta alle otto di sera sembri le otto di sera.
        private func sunColour(atElevation elevation: Double) -> UIColor {
            let warmth = max(0, min(1, 1 - elevation / 35))
            return UIColor(red: 1.0,
                           green: 0.97 - 0.17 * warmth,
                           blue: 0.91 - 0.40 * warmth,
                           alpha: 1)
        }

        var orbitOffset: SIMD3<Float> {
            let radius = max(focusRadius ?? scene.bounds.radius, 1.0) * distanceMultiplier
            let horizontal = radius * cos(Float(elevation))
            return SIMD3(
                horizontal * sin(Float(azimuth)),
                radius * sin(Float(elevation)),
                horizontal * cos(Float(azimuth))
            )
        }

        @objc func panned(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                    gestureStart = (azimuth, elevation)
            case .changed:
                let origin = gestureStart ?? (azimuth, elevation)
                let translation = recognizer.translation(in: recognizer.view)
                azimuth = origin.azimuth - Double(translation.x) * 0.006
                elevation = min(max(origin.elevation + Double(translation.y) * 0.004,
                                    .pi / 12), .pi / 2.4)
                updateCamera()
            case .ended, .cancelled, .failed:
                gestureStart = nil
            default:
                break
            }
        }

        @objc func pinched(_ recognizer: UIPinchGestureRecognizer) {
            // Da dentro la stanza non c'e' una distanza da stringere.
            guard !firstPerson, recognizer.state == .changed else { return }
            distanceMultiplier = min(max(distanceMultiplier / Float(recognizer.scale), 1.4), 4.0)
            recognizer.scale = 1
            updateCamera()
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? ARView else { return }
            let location = recognizer.location(in: view)
            guard let entity = view.entity(at: location) else {
                selectRoom(nil)
                return
            }
            if let target = tapTarget(from: entity) {
                onTargetTapped(target)
                return
            }
            guard let roomID = roomID(from: entity) else {
                selectRoom(nil)
                return
            }
            selectRoom(roomID)
        }

        /// Solo sugli accessori: tenere premuto un muro o un pavimento non
        /// apre niente, perche' una stanza non ha una scheda da aprire.
        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let view = recognizer.view as? ARView,
                  let entity = view.entity(at: recognizer.location(in: view)),
                  // Prima gli accessori, poi la stanza: tenere premuto il
                  // pavimento apre la scheda della stanza — lo stesso gesto,
                  // la stessa direzione: approfondire.
                  let target = tapTarget(from: entity)
                    ?? roomID(from: entity).map({ FloorplanTapTarget.room(roomID: $0) })
            else { return }

            // Il ritorno aptico dice che la pressione e' stata presa **prima**
            // che il foglio salga: senza, mezzo secondo col dito fermo sembra
            // che non sia successo niente.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onTargetHeld(target)
        }

        private func tapTarget(from entity: Entity) -> FloorplanTapTarget? {
            if let id = accessoryID(from: entity, prefix: "lamp:") { return .accessory(id) }
            if let id = accessoryID(from: entity, prefix: "climate:") { return .accessory(id) }
            if let id = accessoryID(from: entity, prefix: "awning:") { return .awning(roomID: id) }
            if let id = accessoryID(from: entity, prefix: "shutter:") { return .shutter(openingID: id) }
            return nil
        }

        private func roomID(from entity: Entity) -> UUID? {
            if let id = parseRoomID(entity.name) { return id }
            return entity.parent.flatMap(roomID(from:))
        }

        private func accessoryID(from entity: Entity, prefix: String) -> UUID? {
            if entity.name.hasPrefix(prefix) {
                return UUID(uuidString: String(entity.name.dropFirst(prefix.count)))
            }
            return entity.parent.flatMap { accessoryID(from: $0, prefix: prefix) }
        }

        private func parseRoomID(_ name: String) -> UUID? {
            guard name.hasPrefix("room:") else { return nil }
            return UUID(uuidString: String(name.dropFirst(5)))
        }

        private func selectRoom(_ roomID: UUID?) {
            selectedRoomID = roomID
            selectionRoot.children.removeAll()

            guard let roomID else {
                onRoomSelected(nil, nil)
                return
            }
            if let outline = RealityFloorplanRenderer.selectionOutlineEntity(for: roomID, scene: scene) {
                selectionRoot.addChild(outline)
            }
            onRoomSelected(roomID, roomNames[roomID])
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
