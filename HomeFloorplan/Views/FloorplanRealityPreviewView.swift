import SwiftUI
import SwiftData
import RealityKit
import UIKit

/// Una planimetria pronta da mostrare in volume.
///
/// Il documento viaggia per valore, così il foglio non tiene vivo il modello
/// SwiftData mentre è aperto.
struct Preview3DFloorplan: Identifiable {
    let id: UUID
    let name: String
    let document: DrawingDocument
    /// Verso dove guarda il lato alto della pianta, in gradi da nord.
    let northBearingDegrees: Double
    /// La scrittura su SwiftData resta in `FloorplanListView`: l'anteprima
    /// riceve una chiusura e non conosce né il modello né il contesto.
    let applyNorthBearing: (Double) -> Void
    /// I sensori con l'apertura che sorvegliano, già decisa al momento della posa.
    let markers: [(uuid: UUID, openingID: UUID?)]
    /// Rotazione con cui l'immagine è stata esportata: serve a rimettere i
    /// marker in coordinate del disegno.
    let exportRotation: DrawingExportRotation
    /// Lo sfondo scelto nell'editor 2D.
    let background: UIColor
}

/// Richiesta di anteprima: **tutte** le planimetrie disegnate, più quale
/// mostrare per prima.
///
/// Portarle tutte permette di cambiare piano senza uscire dalla vista, come
/// nell'editor 2D — e senza che il foglio si chiuda e riapra, cosa che
/// succederebbe se cambiasse l'identità della richiesta.
struct Preview3DRequest: Identifiable {
    let id = UUID()
    let floorplans: [Preview3DFloorplan]
    let initialID: UUID
}

/// Cosa mostra la bandierina di una stanza. Il contenuto arriva dal modello
/// condiviso con la 2D; qui resta solo come disegnarlo.
struct RoomFlag {
    var roomID: UUID
    var anchor: SIMD2<Double>
    var title: String
    var value: String
    var accent: UIColor
    /// Solo le stanze che chiedono attenzione prendono la velatura. Una tinta
    /// su una stanza che sta bene non dice niente: sporca il materiale e toglie
    /// forza all'unica che invece va vista.
    var needsAttention: Bool
}

/// Di cosa parla la vista in questo momento.
///
/// Sono **le stesse modalità della 2D**, non un vocabolario nuovo: se la casa
/// si racconta in due lingue diverse a seconda di dove la guardi, l'utente deve
/// imparare due volte.
enum PreviewMode: String, CaseIterable, Identifiable {
    case off, environment, security

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .off:         "eye.slash"
        case .environment: "leaf.fill"
        case .security:    "lock.shield.fill"
        }
    }

    var label: String {
        switch self {
        case .off:         String(localized: "overlay.off", defaultValue: "Off")
        case .environment: String(localized: "overlay.environment", defaultValue: "Environment")
        case .security:    String(localized: "overlay.security", defaultValue: "Security")
        }
    }
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
    let floorplans: [Preview3DFloorplan]
    @State private var currentID: UUID

    init(floorplans: [Preview3DFloorplan], initialID: UUID) {
        self.floorplans = floorplans
        _currentID = State(initialValue: initialID)
    }

    private var current: Preview3DFloorplan {
        floorplans.first { $0.id == currentID } ?? floorplans[0]
    }

    private var document: DrawingDocument { current.document }
    private var title: String { current.name }
    private var northBearingDegrees: Double { current.northBearingDegrees }
    private var markers: [(uuid: UUID, openingID: UUID?)] { current.markers }
    private var exportRotation: DrawingExportRotation { current.exportRotation }
    private var background: UIColor { current.background }
    private func onNorthBearingChange(_ bearing: Double) { current.applyNorthBearing(bearing) }

    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext
    @State private var ceilingHeight: Double = 2.4
    @State private var floorplanScene: FloorplanScene?
    @State private var cameraResetID = UUID()
    @State private var selectedRoomName: String?
    @State private var mode: PreviewMode = .off
    @State private var didLoadEnvironment = false
    @State private var isLayerTrayOpen = false
    @AppStorage("securityMonitoredUUIDs") private var monitoredUUIDsRaw: String = ""
    @State private var sensorFilter: SensorServiceType?
    /// Il modello ambientale è **lo stesso della 2D**: punteggi, giudizi,
    /// soglie e tipi disponibili vengono da qui. Riscriverli darebbe una casa
    /// che dice due cose diverse a seconda di dove la guardi.
    @State private var envVM = EnvironmentViewModel()
    /// L'istante con cui si calcola il sole: **adesso**, aggiornato ogni pochi
    /// minuti.
    @State private var now = Date()
    @State private var exposure: Exposure = .north

    var body: some View {
        ZStack(alignment: .bottom) {
            if let floorplanScene {
                RealityFloorplanView(scene: floorplanScene,
                                     background: background,
                                     sun: sun,
                                     flags: roomFlags,
                                     cameraResetID: cameraResetID,
                                     onRoomSelected: { selectedRoomName = $0 },
                                     onSceneTouched: {
                                         guard isLayerTrayOpen else { return }
                                         withAnimation(.easeOut(duration: 0.22)) { isLayerTrayOpen = false }
                                     })
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            controls
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                topChrome
                if isLayerTrayOpen, mode == .environment { filterRow }
            }
        }
        .statusBarHidden()
        .onAppear {
            exposure = Exposure.nearest(to: northBearingDegrees)
            // Senza questo i sensori non sono mai stati letti e risultano tutti
            // chiusi: `startObserving` fa il readValue iniziale e arma le
            // notifiche. La vista si apre dalla lista, che non osserva niente.
            homeKit.startObserving(accessoryUUIDs: Set(markers.map(\.uuid)))
            rebuildScene()
        }
        // Lo stato non è più una fotografia: se apri una finestra mentre stai
        // guardando, l'anta si muove. `characteristicValues` è osservabile, e
        // ricalcolare l'insieme costa una manciata di confronti.
        .onChange(of: openOpeningIDs) { _, _ in rebuildScene() }
        .task {
            // Il sole si sposta di un grado ogni quattro minuti: più spesso di
            // così non cambierebbe niente di visibile.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(240))
                now = Date()
            }
        }
    }

    /// Una bandierina per stanza. Le stanze senza dati restano **senza**: un
    /// valore neutro su una stanza che non misura niente sembra una misura.
    ///
    /// Le stanze si accoppiano per **nome**, come fa la 2D — non per UUID, che
    /// fra device non è stabile.
    private var roomFlags: [RoomFlag] {
        switch mode {
        case .off:         []
        case .environment: environmentFlags
        case .security:    securityFlags
        }
    }

    /// Una bandierina per stanza. Le stanze senza dati restano **senza**: un
    /// valore neutro su una stanza che non misura niente sembra una misura.
    ///
    /// Le stanze si accoppiano per **nome**, come fa la 2D — non per UUID, che
    /// fra device non è stabile.
    private var environmentFlags: [RoomFlag] {
        FloorplanRoomEnvironment.anchors(in: document).compactMap { anchor in
            guard let data = envVM.rooms.first(where: { $0.roomName == anchor.roomName })
            else { return nil }

            if let filter = sensorFilter {
                guard let sensor = data.sensors.first(where: { $0.serviceType == filter })
                else { return nil }
                return RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                                title: anchor.roomName,
                                value: sensor.formattedValue,
                                accent: UIColor(urgencyColour(sensor.urgency)),
                                needsAttention: sensor.urgency != .normal)
            }

            return RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                            title: anchor.roomName,
                            value: "\(Int(data.qualityScore * 100))% \(data.qualityLabel)",
                            accent: UIColor(data.qualityColor),
                            // Stessa soglia con cui `qualityLabel` smette di
                            // dire «Ottima»: una sola definizione di «sta bene».
                            needsAttention: data.qualityScore < 0.85)
        }
    }

    /// Lo stato di sicurezza per stanza, dallo **stesso** valutatore della 2D.
    private var securityFlags: [RoomFlag] {
        let monitored = RoomSecurityEvaluator.monitoredIDs(from: monitoredUUIDsRaw)
        return FloorplanRoomEnvironment.anchors(in: document).compactMap { anchor in
            let accessories = RoomSecurityEvaluator.accessories(inRoomNamed: anchor.roomName,
                                                                homeKit: homeKit)
            let status = RoomSecurityEvaluator.status(of: accessories,
                                                      monitoredIDs: monitored,
                                                      homeKit: homeKit)
            guard status.deservesFlag else { return nil }
            return RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                            title: anchor.roomName,
                            value: status.shortLabel,
                            accent: status.accentColor,
                            needsAttention: status.needsAttention)
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
        FloorplanOpeningMatcher.openOpenings(markers: markers, homeKit: homeKit)
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
        let solar = SolarPosition.position(at: now,
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

    /// Titolo a sinistra, selettore al centro, ripristino a destra.
    ///
    /// Il titolo non è interattivo: tenerlo su una riga tutta sua sprecava lo
    /// spazio migliore dello schermo. Spostandolo accanto alla chiusura — che è
    /// poi l'azione che lo riguarda — la riga centrale si libera per il
    /// selettore, e si guadagna una riga intera.
    ///
    /// Il selettore sta in un livello sopra, non nella stessa `HStack`: così è
    /// centrato sullo **schermo** e non su ciò che avanza fra titolo e
    /// pulsante, che con un nome lungo lo sposterebbe.
    private var topChrome: some View {
        ZStack {
            HStack(spacing: 10) {
                Button { dismiss() } label: { chrome("xmark") }

                // Stessa altezza dei chip e un solo gradino di scala sopra —
                // `subheadline` invece di `headline`. Da 17 a 12 nella stessa
                // riga non si leggeva come gerarchia ma come due componenti
                // scritti in momenti diversi.
                //
                // Il fondo resta, perché lo sfondo della vista può essere
                // bianco, ma più leggero di quello dei controlli: la capsula è
                // uguale e senza quella differenza il titolo sembrerebbe
                // toccabile pur non essendolo.
                // Non un'etichetta: è il selettore di planimetria, come in 2D.
                // Per questo porta la capsula **e** il chevron — senza, un menu
                // travestito da titolo non lo apre nessuno.
                Menu {
                    ForEach(floorplans) { plan in
                        Button {
                            guard plan.id != currentID else { return }
                            currentID = plan.id
                            // L'esposizione è di quella planimetria, non della
                            // vista: senza questo il menu resterebbe a dire il
                            // punto cardinale del piano precedente.
                            exposure = Exposure.nearest(to: plan.northBearingDegrees)
                            selectedRoomName = nil
                            rebuildScene()
                        } label: {
                            if plan.id == currentID {
                                Label(plan.name, systemImage: "checkmark")
                            } else {
                                Text(plan.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(title).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .background(.black.opacity(0.34), in: Capsule())
                }

                Spacer(minLength: 12)

                Button {
                    withAnimation(.easeOut(duration: 0.2)) { cameraResetID = UUID() }
                } label: {
                    chrome("arrow.counterclockwise")
                }
            }

            modeRow
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
                .frame(minWidth: 130)

                Button {
                    ceilingHeight = min(4.0, ceilingHeight + 0.1)
                    selectedRoomName = nil
                    rebuildScene()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                }

                Divider().frame(height: 26).overlay(Color.white.opacity(0.25))

                exposureMenu
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
    ///
    /// Era una scheda a tutta larghezza con la riga dei punti cardinali e il
    /// cursore dell'ora. Ma l'esposizione **si imposta una volta sola** — è un
    /// fatto dell'edificio, non un comando — e un comando che si usa una volta
    /// non merita il posto più grande dello schermo.
    private var exposureMenu: some View {
        Menu {
            ForEach(Exposure.allCases) { value in
                Button {
                    exposure = value
                    onNorthBearingChange(value.bearingDegrees)
                } label: {
                    if exposure == value {
                        Label(value.shortLabel, systemImage: "checkmark")
                    } else {
                        Text(value.shortLabel)
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(String(localized: "floorplan.exposure", defaultValue: "Top of the plan faces"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: 4) {
                    Image(systemName: "location.north.line").font(.caption2)
                    Text(exposure.shortLabel).font(.headline)
                }
                .foregroundStyle(.white)
            }
            .frame(minWidth: 96)
        }
    }

    /// Un cassetto, non un menu.
    ///
    /// La regola implicita del sistema è: **menu quando scegli una volta,
    /// controllo visibile quando confronti**. L'esposizione si imposta una volta
    /// nella vita di una planimetria — menu. Gli strati ambientali si sfogliano:
    /// guardi la CO₂, poi la temperatura, e ogni volta guardi cosa fa la casa.
    /// Per questo il cassetto **resta aperto** dopo una scelta: se si richiudesse
    /// ogni volta sarebbe un `Menu` riscritto a mano, con più codice e senza
    /// l'accessibilità che il `Menu` porta con sé.
    ///
    /// Chiuso mostra lo strato attivo, non «Off»: in quello spazio il valore
    /// corrente è l'informazione più utile.
    ///
    /// I filtri **non sono un elenco mio**: sono `envVM.availableSensorTypes`,
    /// cioè i tipi per cui esistono dati veri, gli stessi che la 2D mostra nella
    /// sua barra. Un secondo elenco scritto a mano sarebbe rimasto indietro al
    /// primo sensore nuovo.
    private var modeRow: some View {
        HStack(spacing: 6) {
            Button {
                if !isLayerTrayOpen { loadEnvironmentIfNeeded() }
                withAnimation(.easeOut(duration: 0.22)) { isLayerTrayOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: mode.symbol).font(.system(size: 14))
                    // Da aperto il valore lo dice già il chip selezionato: qui
                    // sarebbe scritto due volte nella stessa riga.
                    if !isLayerTrayOpen {
                        Text(activeLayerLabel).font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, isLayerTrayOpen ? 12 : 16)
                .frame(minHeight: 38)
                .background(.black.opacity(0.34), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String(localized: "floorplan.layers", defaultValue: "Overlay")))
            .accessibilityValue(Text(activeLayerLabel))
            .accessibilityHint(Text(isLayerTrayOpen
                                    ? String(localized: "floorplan.layers.close",
                                             defaultValue: "Closes the list")
                                    : String(localized: "floorplan.layers.open",
                                             defaultValue: "Opens the list")))

            if isLayerTrayOpen {
                HStack(spacing: 4) {
                    ForEach(PreviewMode.allCases) { value in
                        chip(label: value.label, icon: value.symbol, isSelected: mode == value) {
                            mode = value
                            if value != .environment { sensorFilter = nil }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(.black.opacity(0.34), in: Capsule())
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    /// I tipi sono un livello **sotto** la modalità, e devono sembrarlo: gruppo
    /// separato, più smorzato, sotto la barra alta — come nella 2D, dove i
    /// filtri stanno in una barra loro sotto le modalità.
    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(label: String(localized: "filter.all", defaultValue: "Tutto"),
                     icon: "leaf.fill",
                     isSelected: sensorFilter == nil) { sensorFilter = nil }
                ForEach(envVM.availableSensorTypes) { type in
                    chip(label: type.displayName, icon: type.sfSymbol,
                         isSelected: sensorFilter == type) { sensorFilter = type }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        // ⚠️ Niente `fixedSize`: faceva prendere alla riga la larghezza di tutto
        // il contenuto mentre la capsula restava al limite, e i chip finivano
        // fuori dal proprio sfondo. Il limite serve a farla scorrere **dentro**
        // la capsula, non a tagliarla.
        .frame(maxWidth: 640)
        .background(.black.opacity(0.22), in: Capsule())
        .transition(.opacity)
    }

    /// Lo strato attivo in due parole, per l'etichetta chiusa.
    private var activeLayerLabel: String {
        guard mode == .environment else { return mode.label }
        return sensorFilter?.displayName ?? mode.label
    }

    private func chip(label: String, icon: String, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2), action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.subheadline.weight(isSelected ? .semibold : .regular))
            }
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.62))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(isSelected ? Color.white.opacity(0.22) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Il modello ambientale costa **oltre un secondo sul main actor**, e la
    /// vista si apre con lo strato spento: caricarlo all'apparire voleva dire
    /// pagarlo sempre, anche per chi guarda solo la casa. Si carica alla prima
    /// accensione di uno strato.
    private func loadEnvironmentIfNeeded() {
        guard !didLoadEnvironment else { return }
        didLoadEnvironment = true
        envVM.configure(modelContainer: modelContext.container)
        envVM.loadFromCoreData()
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
    let background: UIColor
    let sun: FloorplanSunLight
    let flags: [RoomFlag]
    let cameraResetID: UUID
    let onRoomSelected: (String?) -> Void
    /// Toccare o ruotare il modello vuol dire «ho finito di scegliere»: il
    /// cassetto si richiude da solo e restituisce lo spazio.
    let onSceneTouched: () -> Void

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

        context.coordinator.background = background
        context.coordinator.install(in: view)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.onRoomSelected = onRoomSelected
        context.coordinator.onSceneTouched = onSceneTouched
        if context.coordinator.background != background {
            context.coordinator.background = background
            view.environment.background = .color(background)
        }
        context.coordinator.updateSceneIfNeeded(scene)
        context.coordinator.updateSun(sun)
        context.coordinator.updateFlags(flags)
        context.coordinator.resetCameraIfNeeded(cameraResetID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scene: scene, sun: sun, cameraResetID: cameraResetID,
                    onRoomSelected: onRoomSelected, onSceneTouched: onSceneTouched)
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
        /// Serve per regolare la luce d'ambiente, che di notte va abbassata:
        /// quella non appartiene a nessuna delle tre direzionali.
        private weak var view: ARView?
        private var flagLabels: [Entity] = []
        private var flags: [RoomFlag] = []
        private var flagsSignature = ""
        private var installedSignature: String?
        private var handledResetID: UUID
        private var gestureStart: (azimuth: Double, elevation: Double)?
        private var roomNames: [UUID: String] = [:]
        private var roomWallEntities: [UUID: ModelEntity] = [:]
        private var selectedRoomID: UUID?
        var onRoomSelected: (String?) -> Void
        var onSceneTouched: () -> Void

        init(scene: FloorplanScene,
             sun: FloorplanSunLight,
             cameraResetID: UUID,
             onRoomSelected: @escaping (String?) -> Void,
             onSceneTouched: @escaping () -> Void) {
            self.scene = scene
            self.sun = sun
            self.handledResetID = cameraResetID
            self.onRoomSelected = onRoomSelected
            self.onSceneTouched = onSceneTouched
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
            applyRoomAccents()
            rebuildHeat()
        }

        /// I muri interni della stanza prendono il colore del suo stato.
        ///
        /// Solo quelle che chiedono attenzione: accendere anche le stanze a
        /// posto vuol dire non accendere niente, perche' l'occhio non sa piu'
        /// dove andare.
        private func rebuildHeat() {
            heatRoot.children.removeAll()
            for entity in RealityFloorplanRenderer.roomHeatEntities(for: flags, scene: scene) {
                heatRoot.addChild(entity)
            }
        }

        private func applyRoomAccents() {
            let accents = Dictionary(
                uniqueKeysWithValues: flags.filter(\.needsAttention).map { ($0.roomID, $0.accent) }
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

            fillLight.light.intensity = isDay ? 300 : 110
            fillLight.light.color = UIColor(red: 0.84, green: 0.90, blue: 1.0, alpha: 1)
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
            // ⚠️ Fuori dal giro di aggiornamento. `updateSceneIfNeeded` viene
            // chiamata da `updateUIView`, cioè **durante** l'update della vista:
            // scrivere lì uno `@State` è il «Modifying state during view update»
            // che compariva in console, e SwiftUI lo dichiara comportamento
            // indefinito.
            let notify = onRoomSelected
            DispatchQueue.main.async { notify(nil) }
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
                onSceneTouched()
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
            onSceneTouched()
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
            selectedRoomID = roomID
            selectionRoot.children.removeAll()

            guard let roomID else {
                onRoomSelected(nil)
                return
            }
            if let outline = RealityFloorplanRenderer.selectionOutlineEntity(for: roomID, scene: scene) {
                selectionRoot.addChild(outline)
            }
            onRoomSelected(roomNames[roomID])
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
        /// I muri **interni** di ogni stanza, spezzati in fasce di altezza per
        /// poterli accendere con un colore che sfuma invece che piatto.
        var roomWallEntities: [UUID: ModelEntity] = [:]
        var roomNames: [UUID: String]
        var roomFloorKinds: [UUID: FloorKind]
    }

    static func entity(for scene: FloorplanScene, background: UIColor) -> RenderedFloorplan {
        let root = Entity()
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

            guard let mesh = mesh(for: faces, role: role, center: center) else { continue }

            let model = ModelEntity(mesh: mesh, materials: [FloorplanMaterialCatalog.material(for: role)])
            root.addChild(model)
        }

        return RenderedFloorplan(root: root,
                                 roomEntities: roomEntities,
                                 roomWallEntities: roomWallEntities,
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
                  let material = FloorplanMaterialCatalog.roomHeatMaterial(flag.accent)
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
        .wallGlow,
        .balconyTop,
        .wallTop,
        .glass
    ]
}
