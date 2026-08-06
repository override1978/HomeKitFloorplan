import SwiftUI
import SwiftData
import RealityKit
import UIKit

/// Richiesta di anteprima: il documento viaggia per valore, così il foglio non
/// tiene vivo il modello SwiftData mentre è aperto.
struct Preview3DRequest: Identifiable {
    let id = UUID()
    let document: DrawingDocument
    let title: String
    /// Verso dove guarda il lato alto della pianta, in gradi da nord.
    let northBearingDegrees: Double
    /// La scrittura su SwiftData resta in `FloorplanListView`: l'anteprima
    /// riceve una chiusura e non conosce né il modello né il contesto.
    let applyNorthBearing: (Double) -> Void
    /// Marker della planimetria, in coordinate normalizzate sull'immagine.
    let markers: [(uuid: UUID, position: CGPoint, name: String)]
    let linkedRooms: [LinkedRoom]
    /// Rotazione con cui l'immagine è stata esportata: serve a rimettere i
    /// marker in coordinate del disegno.
    let exportRotation: DrawingExportRotation
}

/// Cosa mostra la bandierina di una stanza. Il contenuto arriva dal modello
/// ambientale condiviso con la 2D; qui resta solo come disegnarlo.
struct RoomFlag {
    var roomID: UUID
    var anchor: SIMD2<Double>
    var title: String
    var value: String
    var accent: UIColor
}

// MARK: - FloorplanSunLight

/// Il sole, già tradotto nello spazio del modello.
///
/// La vista fa l'astronomia una volta e passa al renderer un vettore: il
/// Coordinator non deve sapere niente di latitudini e ore.
struct FloorplanSunLight: Equatable {
    /// Versore che punta **verso** il sole. y in alto, come in RealityKit.
    var direction: SIMD3<Float>
    var elevationDegrees: Double
    var isAboveHorizon: Bool
}

// MARK: - FloorplanRealityPreviewView

struct FloorplanRealityPreviewView: View {
    let document: DrawingDocument
    let title: String
    /// Verso dove guarda il lato alto della pianta, in gradi da nord.
    let northBearingDegrees: Double
    /// Chiamata quando l'utente sceglie l'esposizione: la persistenza sta fuori
    /// di qui, così questa vista non conosce SwiftData.
    let onNorthBearingChange: (Double) -> Void
    /// Marker degli accessori, per risolvere qui quali infissi sono aperti.
    let markers: [(uuid: UUID, position: CGPoint, name: String)]
    /// Serve a invertire l'inquadratura dell'export: i marker sono normalizzati
    /// sull'immagine, che può essere ruotata rispetto alla tela.
    let exportRotation: DrawingExportRotation

    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext
    @State private var ceilingHeight: Double = 2.4
    @State private var floorplanScene: FloorplanScene?
    @State private var cameraResetID = UUID()
    @State private var selectedRoomName: String?
    @State private var exposure: Exposure = .north
    /// Ora locale con cui si calcola il sole. Parte da adesso.
    ///
    /// Serve **perché la funzione sia verificabile**: metà delle volte che apri
    /// la vista è buio, e senza poter spostare l'ora non vedresti mai se
    /// l'esposizione che hai scelto è quella giusta. È anche il modo in cui la
    /// domanda «di mattina il sole entra in cucina?» trova risposta.
    @State private var hourOfDay: Double = SolarClock.currentHourOfDay()
    /// Il modello ambientale è **lo stesso della 2D**: punteggi, giudizi,
    /// soglie e tipi disponibili vengono da qui. Riscriverli darebbe una casa
    /// che dice due cose diverse a seconda di dove la guardi.
    @State private var envVM = EnvironmentViewModel()
    @State private var isEnvironmentOn = false
    @State private var sensorFilter: SensorServiceType?

    var body: some View {
        ZStack(alignment: .bottom) {
            if let floorplanScene {
                RealityFloorplanView(scene: floorplanScene,
                                     sun: sun,
                                     flags: roomFlags,
                                     cameraResetID: cameraResetID,
                                     onRoomSelected: { selectedRoomName = $0 })
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            controls
        }
        .overlay(alignment: .top) { topChrome }
        .statusBarHidden()
        .onAppear {
            exposure = Exposure.nearest(to: northBearingDegrees)
            // Senza questo i sensori non sono mai stati letti e risultano tutti
            // chiusi: `startObserving` fa il readValue iniziale e arma le
            // notifiche. La vista si apre dalla lista, che non osserva niente.
            homeKit.startObserving(accessoryUUIDs: Set(markers.map(\.uuid)))
            envVM.configure(modelContainer: modelContext.container)
            envVM.loadFromCoreData()
            rebuildScene()
        }
        // Lo stato non è più una fotografia: se apri una finestra mentre stai
        // guardando, l'anta si muove. `characteristicValues` è osservabile, e
        // ricalcolare l'insieme costa una manciata di confronti.
        .onChange(of: openOpeningIDs) { _, _ in rebuildScene() }
    }

    /// Una bandierina per stanza. Le stanze senza dati restano **senza**: un
    /// valore neutro su una stanza che non misura niente sembra una misura.
    ///
    /// Le stanze si accoppiano per **nome**, come fa la 2D — non per UUID, che
    /// fra device non è stabile.
    private var roomFlags: [RoomFlag] {
        guard isEnvironmentOn else { return [] }
        return FloorplanRoomEnvironment.anchors(in: document).compactMap { anchor in
            guard let data = envVM.rooms.first(where: { $0.roomName == anchor.roomName })
            else { return nil }

            if let filter = sensorFilter {
                guard let sensor = data.sensors.first(where: { $0.serviceType == filter })
                else { return nil }
                return RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                                title: anchor.roomName,
                                value: sensor.formattedValue,
                                accent: UIColor(urgencyColour(sensor.urgency)))
            }

            return RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                            title: anchor.roomName,
                            value: "\(Int(data.qualityScore * 100))% \(data.qualityLabel)",
                            accent: UIColor(data.qualityColor))
        }
    }

    /// `SensorUrgency.color` dà `.primary` per lo stato normale, che su
    /// un'etichetta scura sopra un modello sparisce. Qui serve un verde.
    private func urgencyColour(_ urgency: SensorUrgency) -> Color {
        switch urgency {
        case .normal:  .green
        case .warning: .orange
        case .danger:  .red
        }
    }

    /// Gli infissi da disegnare aperti, contro lo stato corrente di HomeKit.
    private var openOpeningIDs: Set<UUID> {
        FloorplanOpeningMatcher.openOpenings(
            in: document,
            exportRotation: exportRotation,
            markers: markers.map { (uuid: $0.uuid, position: $0.position) },
            homeKit: homeKit
        )
    }

    // MARK: - Sole

    /// Dal cielo vero allo spazio del disegno.
    ///
    /// L'azimut solare è un rilevamento da nord; il disegno ha un nord suo, che
    /// è quello che l'utente sceglie qui sotto. La differenza fra i due è
    /// l'angolo nello spazio del modello — dove «in alto sulla pianta» è −z,
    /// perché sulla tela la y cresce verso il basso.
    private var sun: FloorplanSunLight {
        let coordinate = SolarClock.homeCoordinate()
        let solar = SolarPosition.position(at: SolarClock.date(hourOfDay: hourOfDay),
                                           latitude: coordinate.latitude,
                                           longitude: coordinate.longitude)

        // Sotto i dieci gradi l'ombra si allunga fino a coprire tutta la scena e
        // non si legge più niente: il sole si tiene un po' più alto di quanto sia.
        let elevation = max(solar.elevationDegrees, 10) * .pi / 180
        let bearing = (solar.azimuthDegrees - northBearingDegrees) * .pi / 180

        return FloorplanSunLight(
            direction: SIMD3(Float(cos(elevation) * sin(bearing)),
                             Float(sin(elevation)),
                             Float(-cos(elevation) * cos(bearing))),
            elevationDegrees: solar.elevationDegrees,
            isAboveHorizon: solar.isAboveHorizon
        )
    }

    private var topChrome: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { chrome("xmark") }

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.34), in: Capsule())
                .frame(maxWidth: .infinity)

            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    cameraResetID = UUID()
                }
            } label: {
                chrome("arrow.counterclockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func chrome(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.35), in: Circle())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if let selectedRoomName {
                Text(selectedRoomName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.45), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            #if DEBUG
            // Temporanea: dice a che punto della catena si perde lo stato degli
            // infissi. Da togliere quando la funzione è assestata.
            Text(FloorplanOpeningMatcher.diagnostics(
                in: document,
                exportRotation: exportRotation,
                markers: markers.map { (uuid: $0.uuid, position: $0.position) },
                homeKit: homeKit
            ).summary)
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.4), in: Capsule())
            #endif

            environmentControls

            sunControls

            HStack(spacing: 18) {
                Button {
                    ceilingHeight = max(2.0, ceilingHeight - 0.1)
                    selectedRoomName = nil
                    rebuildScene()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 44, height: 44)
                }

                VStack(spacing: 2) {
                    Text(String(localized: "floorplan.ceilingHeight", defaultValue: "Ceiling height"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(ceilingHeight.formatted(.number.precision(.fractionLength(1))) + " m")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(minWidth: 150)

                Button {
                    ceilingHeight = min(4.0, ceilingHeight + 0.1)
                    selectedRoomName = nil
                    rebuildScene()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.34), in: Capsule())
        }
        .padding(.bottom, 28)
    }

    /// Otto punti cardinali, che è la granularità con cui la gente conosce casa
    /// propria. Nessuno dice «la mia facciata guarda a 237 gradi».
    private var sunControls: some View {
        VStack(spacing: 8) {
            Text(String(localized: "floorplan.exposure",
                        defaultValue: "Top of the plan faces"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 4) {
                ForEach(Exposure.allCases) { value in
                    Button {
                        exposure = value
                        onNorthBearingChange(value.bearingDegrees)
                    } label: {
                        Text(value.shortLabel)
                            .font(.caption.weight(exposure == value ? .bold : .regular))
                            .foregroundStyle(.white.opacity(exposure == value ? 1 : 0.6))
                            .frame(minWidth: 32, minHeight: 30)
                            .background(exposure == value ? Color.white.opacity(0.22) : .clear,
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: sun.isAboveHorizon ? "sun.max.fill" : "moon.stars.fill")
                    .foregroundStyle(.white.opacity(0.8))
                Slider(value: $hourOfDay, in: 0...24, step: 0.25)
                Text(SolarClock.label(hourOfDay: hourOfDay))
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// I filtri **non sono un elenco mio**: sono `envVM.availableSensorTypes`,
    /// cioè i tipi per cui esistono dati veri, gli stessi che la 2D mostra nella
    /// sua barra. Un secondo elenco scritto a mano sarebbe rimasto indietro al
    /// primo sensore nuovo.
    private var environmentControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(label: String(localized: "environment.layer.none", defaultValue: "Off"),
                     icon: "eye.slash",
                     isSelected: !isEnvironmentOn) {
                    isEnvironmentOn = false
                    sensorFilter = nil
                }
                chip(label: String(localized: "filter.all", defaultValue: "Tutto"),
                     icon: "leaf.fill",
                     isSelected: isEnvironmentOn && sensorFilter == nil) {
                    isEnvironmentOn = true
                    sensorFilter = nil
                }
                ForEach(envVM.availableSensorTypes) { type in
                    chip(label: type.displayName,
                         icon: type.sfSymbol,
                         isSelected: isEnvironmentOn && sensorFilter == type) {
                        isEnvironmentOn = true
                        sensorFilter = sensorFilter == type ? nil : type
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: 640)
        .padding(.vertical, 5)
        .background(.black.opacity(0.34), in: Capsule())
    }

    private func chip(label: String, icon: String, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2), action)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.caption.weight(isSelected ? .bold : .regular))
            }
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.6))
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(isSelected ? Color.white.opacity(0.22) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func rebuildScene() {
        floorplanScene = FloorplanSceneBuilder.scene(from: document,
                                                     ceilingHeight: ceilingHeight,
                                                     includesFurniture: true,
                                                     openOpeningIDs: openOpeningIDs)
    }
}

// MARK: - RealityFloorplanView

private struct RealityFloorplanView: UIViewRepresentable {
    let scene: FloorplanScene
    let sun: FloorplanSunLight
    let flags: [RoomFlag]
    let cameraResetID: UUID
    let onRoomSelected: (String?) -> Void

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        view.environment.background = .color(UIColor(red: 0.28, green: 0.36, blue: 0.23, alpha: 1))
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

        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.onRoomSelected = onRoomSelected
        context.coordinator.updateSceneIfNeeded(scene)
        context.coordinator.updateSun(sun)
        context.coordinator.updateFlags(flags)
        context.coordinator.resetCameraIfNeeded(cameraResetID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scene: scene, sun: sun, cameraResetID: cameraResetID, onRoomSelected: onRoomSelected)
            .prepared(with: flags)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var scene: FloorplanScene
        var sun: FloorplanSunLight
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
        private var flagLabels: [Entity] = []
        private var flags: [RoomFlag] = []
        private var flagsSignature = ""
        private var installedSignature: String?
        private var handledResetID: UUID
        private var gestureStart: (azimuth: Double, elevation: Double)?
        private var roomEntities: [UUID: ModelEntity] = [:]
        private var roomNames: [UUID: String] = [:]
        private var roomFloorKinds: [UUID: FloorKind] = [:]
        private var selectedRoomID: UUID?
        var onRoomSelected: (String?) -> Void

        init(scene: FloorplanScene,
             sun: FloorplanSunLight,
             cameraResetID: UUID,
             onRoomSelected: @escaping (String?) -> Void) {
            self.scene = scene
            self.sun = sun
            self.handledResetID = cameraResetID
            self.onRoomSelected = onRoomSelected
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
            flagsSignature = signature
            flags = newFlags
            rebuildFlags()
            applyRoomTints()
        }

        /// Il pavimento della stanza prende la tinta del suo stato, come il
        /// riempimento nella 2D. Il colore risponde a «dov'è il problema» senza
        /// leggere niente; la bandierina dice «quanto».
        private func applyRoomTints() {
            let accents = Dictionary(uniqueKeysWithValues: flags.map { ($0.roomID, $0.accent) })
            for (roomID, entity) in roomEntities where roomID != selectedRoomID {
                entity.model?.materials = [
                    FloorplanMaterialCatalog.material(for: .floor,
                                                      isSelected: false,
                                                      floorKind: roomFloorKinds[roomID],
                                                      tint: accents[roomID])
                ]
            }
        }

        private func rebuildFlags() {
            flagRoot.children.removeAll()
            flagLabels = []
            let built = RealityFloorplanRenderer.flagEntities(for: flags, scene: scene)
            for flag in built {
                flagRoot.addChild(flag.root)
                flagLabels.append(flag.label)
            }
            orientFlags()
        }

        /// Le etichette girano **solo attorno alla verticale**: seguono la
        /// telecamera ma restano dritte, o il testo si inclinerebbe con lei.
        private func orientFlags() {
            let yaw = simd_quatf(angle: Float(azimuth), axis: SIMD3(0, 1, 0))
            for label in flagLabels { label.orientation = yaw }
        }

        func updateSun(_ newSun: FloorplanSunLight) {
            guard sun != newSun else { return }
            sun = newSun
            configureLights()
            rebuildSunPatches()
        }

        private func rebuildSunPatches() {
            sunPatchRoot.children.removeAll()
            guard let patch = RealityFloorplanRenderer.sunPatchEntity(for: scene, sun: sun) else { return }
            sunPatchRoot.addChild(patch)
        }

        func install(in view: ARView) {
            camera.camera.fieldOfViewInDegrees = 38

            anchor.addChild(contentRoot)
            anchor.addChild(camera)
            anchor.addChild(keyLight)
            anchor.addChild(fillLight)
            anchor.addChild(rimLight)
            anchor.addChild(sunPatchRoot)
            anchor.addChild(flagRoot)
            view.scene.anchors.append(anchor)

            updateSceneIfNeeded(scene)
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

            if sun.isAboveHorizon {
                keyLight.light.intensity = 2_600
                keyLight.light.color = sunColour(atElevation: sun.elevationDegrees)
                keyLight.shadow = DirectionalLightComponent.Shadow(
                    maximumDistance: radius * 6,
                    depthBias: 1.8
                )
            } else {
                // Sole tramontato: luce fredda e **nessuna ombra**. Di notte le
                // ombre le fanno le lampade, e quelle arriveranno quando la vista
                // saprà quali luci di casa sono accese in questo momento.
                keyLight.light.intensity = 900
                keyLight.light.color = UIColor(red: 0.70, green: 0.79, blue: 1.0, alpha: 1)
                keyLight.shadow = nil
            }
            keyLight.look(at: .zero, from: sun.direction * radius * 3, relativeTo: nil)

            fillLight.light.intensity = 800
            fillLight.light.color = UIColor(red: 0.84, green: 0.90, blue: 1.0, alpha: 1)
            fillLight.shadow = nil
            fillLight.look(at: .zero,
                           from: SIMD3(radius * 2.6, radius * 1.4, -radius * 2.2),
                           relativeTo: nil)

            rimLight.light.intensity = 420
            rimLight.light.color = UIColor(white: 1, alpha: 1)
            rimLight.shadow = nil
            rimLight.look(at: .zero,
                          from: SIMD3(radius * 0.4, radius * 0.5, radius * 3.0),
                          relativeTo: nil)
        }

        func updateSceneIfNeeded(_ newScene: FloorplanScene) {
            scene = newScene
            guard installedSignature != newScene.renderSignature else { return }
            installedSignature = newScene.renderSignature

            contentRoot.children.removeAll()
            selectedRoomID = nil
            let rendered = RealityFloorplanRenderer.entity(for: newScene)
            roomEntities = rendered.roomEntities
            roomNames = rendered.roomNames
            roomFloorKinds = rendered.roomFloorKinds
            contentRoot.addChild(rendered.root)
            configureLights()
            rebuildSunPatches()
            rebuildFlags()
            onRoomSelected(nil)
        }

        func updateCamera() {
            camera.look(at: .zero, from: cameraPosition, relativeTo: nil)
            orientFlags()
        }

        func resetCameraIfNeeded(_ resetID: UUID) {
            guard handledResetID != resetID else { return }
            handledResetID = resetID
            azimuth = .pi / 4
            elevation = .pi / 5
            distanceMultiplier = 2.2
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

        var cameraPosition: SIMD3<Float> {
            let radius = max(scene.bounds.radius, 1.0) * distanceMultiplier
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
            guard recognizer.state == .changed else { return }
            distanceMultiplier = min(max(distanceMultiplier / Float(recognizer.scale), 1.4), 4.0)
            recognizer.scale = 1
            updateCamera()
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? ARView else { return }
            let location = recognizer.location(in: view)
            guard let entity = view.entity(at: location),
                  let roomID = roomID(from: entity)
            else {
                selectRoom(nil)
                return
            }
            selectRoom(roomID)
        }

        private func roomID(from entity: Entity) -> UUID? {
            if let id = parseRoomID(entity.name) { return id }
            return entity.parent.flatMap(roomID(from:))
        }

        private func parseRoomID(_ name: String) -> UUID? {
            guard name.hasPrefix("room:") else { return nil }
            return UUID(uuidString: String(name.dropFirst(5)))
        }

        private func selectRoom(_ roomID: UUID?) {
            if let selectedRoomID, let entity = roomEntities[selectedRoomID] {
                entity.model?.materials = [
                    FloorplanMaterialCatalog.material(
                        for: .floor,
                        isSelected: false,
                        floorKind: roomFloorKinds[selectedRoomID],
                        tint: flags.first { $0.roomID == selectedRoomID }?.accent
                    )
                ]
            }

            selectedRoomID = roomID

            if let roomID, let entity = roomEntities[roomID] {
                // Il `floorKind` va passato anche da selezionata, o evidenziare
                // una stanza le spegne il parquet e la lascia a tinta piatta.
                entity.model?.materials = [
                    FloorplanMaterialCatalog.material(
                        for: .floor,
                        isSelected: true,
                        floorKind: roomFloorKinds[roomID]
                    )
                ]
                onRoomSelected(roomNames[roomID])
            } else {
                onRoomSelected(nil)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - RealityFloorplanRenderer

private enum RealityFloorplanRenderer {
    struct RenderedFloorplan {
        var root: Entity
        var roomEntities: [UUID: ModelEntity]
        var roomNames: [UUID: String]
        var roomFloorKinds: [UUID: FloorKind]
    }

    static func entity(for scene: FloorplanScene) -> RenderedFloorplan {
        let root = Entity()
        let center = scene.bounds.center
        let grouped = Dictionary(grouping: scene.faces, by: \.role)
        var roomEntities: [UUID: ModelEntity] = [:]
        var roomNames: [UUID: String] = [:]
        var roomFloorKinds: [UUID: FloorKind] = [:]

        // Un piano sotto la casa. Un'ombra vera ha bisogno di qualcosa su cui
        // cadere, e lo sfondo è un colore, non geometria: senza questo la casa
        // proietterebbe l'ombra nel vuoto e resterebbe a galleggiare.
        let groundSize = max(scene.bounds.radius, 1) * 12
        let ground = ModelEntity(mesh: .generatePlane(width: groundSize, depth: groundSize),
                                 materials: [FloorplanMaterialCatalog.groundMaterial()])
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

            guard let mesh = mesh(for: faces, role: role, center: center) else { continue }

            let model = ModelEntity(mesh: mesh, materials: [FloorplanMaterialCatalog.material(for: role)])
            root.addChild(model)
        }

        return RenderedFloorplan(root: root,
                                 roomEntities: roomEntities,
                                 roomNames: roomNames,
                                 roomFloorKinds: roomFloorKinds)
    }

    // MARK: - Bandierine di stanza

    struct Flag {
        var root: Entity
        /// Solo l'etichetta si gira verso la telecamera: lo stelo è verticale e
        /// non ha un davanti.
        var label: Entity
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
            guard let material = FloorplanMaterialCatalog.flagLabelMaterial(
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

            let label = ModelEntity(mesh: .generatePlane(width: 1.25, height: 0.32),
                                    materials: [material])
            label.position = SIMD3(x, topY - centre.y + 0.19, z)
            root.addChild(label)

            return Flag(root: root, label: label)
        }
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

        for face in scene.faces where face.role == .glass && face.points.count == 4 {
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
                             center: SIMD3<Float>) -> MeshResource? {
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
            uvs.append(contentsOf: textureCoordinates(for: points, role: role))
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
        var cursor = start + spacing

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
                                           role: FloorplanScene.MeshFace.MaterialRole) -> [SIMD2<Float>] {
        guard role == .floor else {
            return points.map { SIMD2($0.x, $0.y) }
        }
        return points.map { SIMD2($0.x, $0.z) }
    }

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

    private static func faceNormal(for points: [SIMD3<Float>]) -> SIMD3<Float> {
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

private extension FloorplanScene.MeshFace.MaterialRole {
    static let renderOrder: [Self] = [
        .floor,
        .furniture,
        .door,
        .doorTrim,
        .doorHandle,
        .doorEdge,
        .frame,
        .balcony,
        .wall,
        .balconyTop,
        .wallTop,
        .glass
    ]
}
