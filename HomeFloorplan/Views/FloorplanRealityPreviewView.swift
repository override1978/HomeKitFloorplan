import SwiftUI
import SwiftData
import RealityKit
import HomeKit
import UIKit

/// Una planimetria pronta da mostrare in volume.
///
/// Il documento viaggia per valore, così il foglio non tiene vivo il modello
/// SwiftData mentre è aperto.
/// Un accessorio piazzato, come lo vede la 3D.
struct Preview3DMarker {
    let uuid: UUID
    /// Normalizzata sull'immagine esportata.
    let position: CGPoint
    /// Per i contatti: quale apertura sorvegliano.
    let openingID: UUID?
}

/// Quota e direzione di una luce, come stanno **adesso** nel modello.
struct LampSettings {
    var height: Double?
    var direction: LampDirection?
}

struct Preview3DFloorplan: Identifiable {
    let id: UUID
    let name: String
    let document: DrawingDocument
    /// Verso dove guarda il lato alto della pianta, in gradi da nord.
    let northBearingDegrees: Double
    /// La scrittura su SwiftData resta in `FloorplanListView`: l'anteprima
    /// riceve una chiusura e non conosce né il modello né il contesto.
    let applyNorthBearing: (Double) -> Void
    /// Gli accessori piazzati.
    let markers: [Preview3DMarker]
    /// Legge quota e direzione di una luce **dal modello**, ogni volta.
    ///
    /// ⚠️ Non un valore ma una chiusura, e non e' un dettaglio: i marker sono
    /// una fotografia scattata all'apertura, quindi un valore copiato qui
    /// resterebbe indietro appena lo si modifica. Tenere una copia nella vista
    /// per rimediare sarebbe stata una **terza** fonte di verita' accanto a
    /// SwiftData e alla fotografia. Leggendo si resta disaccoppiati e allineati.
    let lampSettings: (UUID) -> LampSettings
    /// Salva quota e direzione. La scrittura su SwiftData resta fuori: qui si
    /// sa cosa, non dove metterlo.
    let applyLampSettings: (UUID, Double, LampDirection) -> Void
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

/// Una lampada accesa, pronta a illuminare.
struct FloorplanLamp: Equatable {
    /// Cambia solo quando il cono va rifatto davvero.
    var beamKey: String { "\(direction.rawValue)|\(Int(height * 20))" }
    /// La pozza dipende anche da quanto e' luminosa.
    var poolKey: String { "\(beamKey)|\(Int(brightness * 8))" }

    /// L'accessorio da comandare quando si tocca il bulbo.
    var accessoryUUID: UUID
    var name: String
    var isOn: Bool
    /// Quota da terra, in metri.
    var height: Double
    var direction: LampDirection
    /// In metri, nello spazio del disegno.
    var position: SIMD2<Double>
    /// 0…1, dalla luminosità impostata sull'accessorio.
    var brightness: Double
    var colour: UIColor
}

/// Cosa mostra la bandierina di una stanza. Il contenuto arriva dal modello
/// condiviso con la 2D; qui resta solo come disegnarlo.
struct RoomFlag {
    /// Serve solo alla firma della mappa di calore: la macchia dipende dalla
    /// stanza e dal colore, non dal numero scritto sulla bandierina.
    var brightnessKey: Double { needsAttention ? 1 : 0 }
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
    private var markers: [Preview3DMarker] { current.markers }
    private var exportRotation: DrawingExportRotation { current.exportRotation }
    private var background: UIColor { current.background }
    private func onNorthBearingChange(_ bearing: Double) { current.applyNorthBearing(bearing) }
    private func applyLampSettings(_ uuid: UUID, _ height: Double, _ direction: LampDirection) {
        current.applyLampSettings(uuid, height, direction)
        settingsRevision &+= 1
        rebuildScene()
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var ceilingHeight: Double = 2.4
    @State private var floorplanScene: FloorplanScene?
    @State private var cameraResetID = UUID()
    @State private var selectedRoomName: String?
    @State private var selectedRoomID: UUID?
    /// Cambia a ogni salvataggio, per rileggere il modello.
    ///
    /// Non contiene dati: e' un segnale. I valori restano in SwiftData, che e'
    /// l'unica fonte di verita'.
    @State private var settingsRevision = 0
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
    @State private var lampCaption: String?
    /// Quali accessori stiamo osservando, per poterli lasciare andare.
    ///
    /// Solo quelli di **questa** planimetria più la centralina: osservare tutta
    /// la casa vorrebbe dire notifiche e batteria per accessori che non si
    /// stanno nemmeno guardando.
    @State private var observedUUIDs: Set<UUID> = []
    #if DEBUG
    /// Anteprima notte, **solo in debug**: il sole resta reale in produzione,
    /// ma di giorno non c'è modo di verificare le luci — e una funzione che si
    /// può provare solo dopo cena non si sviluppa.
    @State private var forcesNight = false
    #endif

    var body: some View {
        ZStack(alignment: .bottom) {
            if let floorplanScene {
                RealityFloorplanView(scene: floorplanScene,
                                     background: background,
                                     sun: sun,
                                     lamps: litLights,
                                     flags: roomFlags,
                                     cameraResetID: cameraResetID,
                                     onRoomSelected: { roomID, name in
                                         selectedRoomID = roomID
                                         selectedRoomName = name
                                     },
                                     onSceneTouched: {
                                         guard isLayerTrayOpen else { return }
                                         withAnimation(.easeOut(duration: 0.22)) { isLayerTrayOpen = false }
                                     },
                                     onLampTapped: toggleLamp)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            controls
        }
        .overlay(alignment: .bottom) { roomSetupPanel }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                topChrome
                if isLayerTrayOpen, mode == .environment { filterRow }
                if mode == .security { securityStatusPill }
            }
        }
        .statusBarHidden()
        .onAppear {
            exposure = Exposure.nearest(to: northBearingDegrees)
            // Senza questo i sensori non sono mai stati letti e risultano tutti
            // chiusi: `startObserving` fa il readValue iniziale e arma le
            // notifiche. La vista si apre dalla lista, che non osserva niente.
            observeCurrentFloorplan()
            rebuildScene()
        }
        // Lo stato non è più una fotografia: se apri una finestra mentre stai
        // guardando, l'anta si muove. `characteristicValues` è osservabile, e
        // ricalcolare l'insieme costa una manciata di confronti.
        .onChange(of: openOpeningIDs) { _, _ in rebuildScene() }
        // Cambiando piano cambiano gli accessori: quelli vecchi si lasciano
        // andare e si osservano i nuovi, o il piano appena aperto avrebbe luci
        // spente e porte chiuse per il solo motivo che nessuno le ha lette.
        .onChange(of: currentID) { _, _ in observeCurrentFloorplan() }
        .onDisappear { homeKit.stopObserving(accessoryUUIDs: observedUUIDs) }
        .task {
            // ⚠️ La cadenza non la detta la percezione, la detta il **costo**:
            // ogni aggiornamento rifà la geometria delle macchie di sole. In un
            // quarto d'ora il sole si sposta di quasi quattro gradi — abbastanza
            // da vedersi — mentre in quattro minuti si spostava di uno solo, e
            // lo si pagava quindici volte tanto.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(900))
                now = Date()
            }
        }
        // Il ritorno in primo piano copre il caso che la cadenza non copre:
        // l'app rimasta in background due ore, e una casa illuminata come non è.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { now = Date() }
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
        FloorplanOpeningMatcher.openOpenings(
            markers: markers.map { (uuid: $0.uuid, openingID: $0.openingID) },
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
        #if DEBUG
        let instant = forcesNight
            ? Calendar.current.startOfDay(for: now).addingTimeInterval(23 * 3_600)
            : now
        #else
        let instant = now
        #endif
        let solar = SolarPosition.position(at: instant,
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

                #if DEBUG
                Button {
                    forcesNight.toggle()
                } label: {
                    chrome(forcesNight ? "moon.fill" : "sun.max")
                }
                #endif

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
            if let caption = lampCaption ?? selectedRoomName {
                Text(caption)
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

    /// Le lampade accese, con dove stanno e di che colore sono.
    ///
    /// **Non è uno strato**: è la casa che si racconta, come una porta aperta
    /// che si vede aperta. Quindi non dipende dalla modalità — una luce accesa
    /// è accesa qualunque cosa tu stia guardando.
    private var litLights: [FloorplanLamp] {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        return markers.compactMap { marker in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  let lamp = FloorplanLampReader.lamp(for: accessory, homeKit: homeKit)
            else { return nil }

            // `settingsRevision` si legge apposta: e' cio' che fa rileggere il
            // modello dopo un salvataggio.
            _ = settingsRevision
            let settings = current.lampSettings(marker.uuid)
            let direction = settings.direction ?? .down
            return FloorplanLamp(accessoryUUID: marker.uuid,
                                 name: accessory.name,
                                 isOn: lamp.isOn,
                                 height: settings.height
                                     ?? direction.defaultHeight(ceiling: ceilingHeight),
                                 direction: direction,
                                 position: transform.metres(from: marker.position),
                                 brightness: lamp.brightness,
                                 colour: lamp.colour)
        }
    }

    /// Le lampade della stanza selezionata.
    ///
    /// Si ricavano dalla **posizione**, non da un elenco: una lampada sta in
    /// una stanza se il suo punto cade nel poligono di quella stanza. Nessun
    /// accoppiamento per nome da sbagliare.
    private var lampsInSelectedRoom: [FloorplanLamp] {
        guard let selectedRoomID,
              let area = document.roomAreas.first(where: { $0.id == selectedRoomID })
        else { return [] }

        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        let polygon = area.effectivePoints.map {
            SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
        }
        return litLights.filter { FloorplanRoomEnvironment.contains($0.position, polygon) }
    }

    /// Il posto dove si impostano i fatti che la pianta **non può contenere**:
    /// a che altezza sta una luce e dove punta.
    ///
    /// Per stanza e non per singola lampada perché la configurazione è
    /// un'attività a lotti — «i quattro faretti della cucina, tutti a
    /// soffitto» — e cercarli uno a uno nel modello sarebbe una penitenza.
    @ViewBuilder
    private var roomSetupPanel: some View {
        let lamps = lampsInSelectedRoom
        if !lamps.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                // Il recap della selezione: senza, il pannello compare e non si
                // sa a cosa si riferisce.
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.2.fill").font(.system(size: 13))
                    Text(selectedRoomName ?? "")
                        .font(.headline)
                    Text(lamps.count == 1
                         ? String(localized: "lamp.count.one", defaultValue: "1 light")
                         : String(localized: "lamp.count.other", defaultValue: "\(lamps.count) lights"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .foregroundStyle(.white)

                ForEach(lamps, id: \.accessoryUUID) { lamp in
                    Divider().overlay(Color.white.opacity(0.18))
                    lampSetupRow(lamp)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: 560)
            // Più denso del resto della cornice, di proposito: le altre capsule
            // mostrano stato, questa **si usa**. Un pannello dove ci si ferma ad
            // agire si merita più peso di uno che si legge di sfuggita — ma
            // resta traslucido, o si perderebbe il motivo di configurare qui:
            // vedere il modello reagire mentre si muove il cursore.
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(.bottom, 104)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Ogni comando dice **cosa fa**, non solo che c'è.
    ///
    /// Tre icone senza didascalia sono un indovinello: una freccia in giù può
    /// voler dire «abbassa», «sposta sotto» o «punta in basso». La parola
    /// accanto alla scelta attiva toglie l'ambiguità senza occupare una riga in
    /// più per ciascuna.
    @ViewBuilder
    private func lampSetupRow(_ lamp: FloorplanLamp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lamp.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                Text(String(localized: "lamp.direction.title", defaultValue: "Points"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 58, alignment: .leading)

                HStack(spacing: 4) {
                    ForEach(LampDirection.allCases) { value in
                        Button {
                            applyLampSettings(lamp.accessoryUUID, lamp.height, value)
                        } label: {
                            directionGlyph(value, isSelected: lamp.direction == value)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 3)
                                .background(lamp.direction == value ? Color.white.opacity(0.20) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(value.label))
                    }
                }

                Text(lamp.direction.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

            HStack(spacing: 8) {
                Text(String(localized: "lamp.height.title", defaultValue: "Height"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 58, alignment: .leading)

                Slider(value: heightBinding(for: lamp), in: 0.2...3.2, step: 0.05)
                    .tint(.white.opacity(0.8))

                Text(lamp.height.formatted(.number.precision(.fractionLength(2))) + " m")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }

    /// Il pallino con il suo fascio, disegnato.
    ///
    /// Una freccia dice «in giù», non dice **cosa ottieni**. Qui si vede la
    /// lampada e la luce che getta, che è esattamente ciò che comparirà nel
    /// modello: l'anteprima e il comando diventano la stessa cosa.
    private func directionGlyph(_ direction: LampDirection, isSelected: Bool) -> some View {
        Canvas { context, size in
            let bulb = Color.white.opacity(isSelected ? 0.95 : 0.45)
            let beam = Color(red: 1.0, green: 0.86, blue: 0.45)
                .opacity(isSelected ? 0.55 : 0.20)
            let centreX = size.width / 2
            let spread = size.width * 0.36

            func dot(at y: CGFloat) {
                context.fill(Path(ellipseIn: CGRect(x: centreX - 3.5, y: y - 3.5, width: 7, height: 7)),
                             with: .color(bulb))
            }
            func cone(apex: CGFloat, base: CGFloat) {
                var path = Path()
                path.move(to: CGPoint(x: centreX, y: apex))
                path.addLine(to: CGPoint(x: centreX - spread, y: base))
                path.addLine(to: CGPoint(x: centreX + spread, y: base))
                path.closeSubpath()
                context.fill(path, with: .color(beam))
            }

            switch direction {
            case .down:
                cone(apex: 7, base: size.height - 3)
                dot(at: 7)
            case .around:
                for factor in [0.42, 0.28] {
                    let radius = size.width * factor
                    context.fill(Path(ellipseIn: CGRect(x: centreX - radius,
                                                        y: size.height / 2 - radius,
                                                        width: radius * 2,
                                                        height: radius * 2)),
                                 with: .color(beam.opacity(isSelected ? 0.30 : 0.14)))
                }
                dot(at: size.height / 2)
            case .up:
                cone(apex: size.height - 7, base: 3)
                dot(at: size.height - 7)
            }
        }
        .frame(width: 42, height: 34)
    }

    private func heightBinding(for lamp: FloorplanLamp) -> Binding<Double> {
        Binding(
            get: { lamp.height },
            set: { applyLampSettings(lamp.accessoryUUID, $0, lamp.direction) }
        )
    }

    /// Accende o spegne toccando il bulbo.
    ///
    /// Passa da `performQuickToggle` dell'adapter, lo stesso che usano i marker
    /// della 2D: una sola strada per comandare, e le protezioni e i log stanno
    /// già lì.
    private func toggleLamp(_ accessoryUUID: UUID) {
        guard let accessory = homeKit.accessory(for: accessoryUUID) else { return }
        let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        guard adapter.supportsQuickToggle else { return }

        // Il nome compare toccando, non prima: un'etichetta fissa su ogni
        // lampada sarebbe l'elenco di segnaposti che stiamo evitando. E serve
        // anche da conferma — senza, un tocco che non ha effetto immediato
        // sembra un tocco andato a vuoto.
        withAnimation(.easeOut(duration: 0.15)) { lampCaption = accessory.name }
        Task {
            try? await adapter.performQuickToggle(via: homeKit)
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.3)) { lampCaption = nil }
        }
    }

    /// La centralina della casa, se ce n'è una.
    ///
    /// L'adapter si costruisce al volo: legge da `homeKit.characteristicValues`,
    /// che è osservabile, quindi la vista si aggiorna quando l'antifurto cambia
    /// stato senza doverlo tenere da parte.
    private var securitySystem: SecuritySystemAdapter? {
        homeKit.allAccessories
            .lazy
            .compactMap { SecuritySystemAdapter(accessory: $0, homeKit: homeKit) }
            .first
    }

    /// Lo stato dell'antifurto è **l'unica cosa globale** della vista: non
    /// appartiene a una stanza, quindi non entra in una bandierina.
    ///
    /// È di sola lettura, per scelta: la 3D è la vista d'insieme, i comandi
    /// stanno in 2D. Qui si vede com'è la casa, non la si governa.
    @ViewBuilder
    private var securityStatusPill: some View {
        if let system = securitySystem {
            let triggered = system.currentState == .triggered
            let mode = system.currentMode
            let tint = triggered ? Color.red : mode.tintColor
            HStack(spacing: 7) {
                Image(systemName: triggered ? "exclamationmark.shield.fill" : mode.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(triggered
                     ? String(localized: "security.state.triggered", defaultValue: "Alarm")
                     : mode.displayName)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(.black.opacity(0.34), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1.5))
            .transition(.opacity)
        } else {
            // Nessuna centralina: dirlo è meglio che lasciare uno spazio vuoto
            // che sembra un guasto.
            Text(String(localized: "security.noSystem", defaultValue: "No alarm system"))
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(.black.opacity(0.22), in: Capsule())
                .transition(.opacity)
        }
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

    /// Osserva gli accessori del piano corrente, lasciando andare i precedenti.
    ///
    /// ⚠️ Serve anche la centralina, non solo i marker: `homeKit.value(for:)`
    /// resta nil finché nessuno ha fatto `readValue`, ed è lo stesso inciampo
    /// che ha tenuto chiuse tutte le porte per mezza giornata.
    private func observeCurrentFloorplan() {
        var wanted = Set(markers.map(\.uuid))
        if let system = securitySystem { wanted.insert(system.accessory.uniqueIdentifier) }
        guard wanted != observedUUIDs else { return }

        let released = observedUUIDs.subtracting(wanted)
        if !released.isEmpty { homeKit.stopObserving(accessoryUUIDs: released) }
        homeKit.startObserving(accessoryUUIDs: wanted)
        observedUUIDs = wanted
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
    let lamps: [FloorplanLamp]
    let flags: [RoomFlag]
    let cameraResetID: UUID
    let onRoomSelected: (UUID?, String?) -> Void
    /// Toccare o ruotare il modello vuol dire «ho finito di scegliere»: il
    /// cassetto si richiude da solo e restituisce lo spazio.
    let onSceneTouched: () -> Void
    /// Toccare un bulbo lo accende o lo spegne: l'oggetto che mostra lo stato
    /// è anche quello che lo cambia, senza un segnaposto in mezzo.
    let onLampTapped: (UUID) -> Void

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
        context.coordinator.onLampTapped = onLampTapped
        if context.coordinator.background != background {
            context.coordinator.background = background
            view.environment.background = .color(background)
        }
        context.coordinator.updateSceneIfNeeded(scene)
        context.coordinator.updateSun(sun)
        context.coordinator.updateLamps(lamps)
        context.coordinator.updateFlags(flags)
        context.coordinator.resetCameraIfNeeded(cameraResetID)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scene: scene, sun: sun, cameraResetID: cameraResetID,
                    onRoomSelected: onRoomSelected, onSceneTouched: onSceneTouched,
                    onLampTapped: onLampTapped)
            .prepared(withLamps: lamps)
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
        private var lamps: [FloorplanLamp] = []
        /// Gli oggetti di ogni lampada, tenuti in vita fra un aggiornamento e
        /// l'altro: e' quello che permette di cambiare stato senza ricostruire.
        private struct LampNode {
            var bulb: ModelEntity
            var spot: SpotLight
            var halo: ModelEntity
            var pool: Entity?
            /// Firme di cio' che richiede geometria nuova: senza, ogni tocco
            /// rifarebbe mesh identiche.
            var beamKey: String = ""
            var poolKey: String = ""
        }
        private var lampNodes: [UUID: LampNode] = [:]
        /// Serve per regolare la luce d'ambiente, che di notte va abbassata:
        /// quella non appartiene a nessuna delle tre direzionali.
        private weak var view: ARView?
        private var flagLabels: [Entity] = []
        /// L'etichetta di ogni stanza, tenuta in vita fra un aggiornamento e
        /// l'altro: cambia il testo, non l'oggetto.
        private struct FlagNode {
            var label: ModelEntity
            var signature: String
        }
        private var flagNodes: [UUID: FlagNode] = [:]
        private var builtHeatSignature = "\u{0}"
        private var flags: [RoomFlag] = []
        private var flagsSignature = ""
        private var installedSignature: String?
        private var handledResetID: UUID
        private var gestureStart: (azimuth: Double, elevation: Double)?
        private var roomNames: [UUID: String] = [:]
        private var roomWallEntities: [UUID: ModelEntity] = [:]
        private var selectedRoomID: UUID?
        var onRoomSelected: (UUID?, String?) -> Void
        var onSceneTouched: () -> Void
        var onLampTapped: (UUID) -> Void

        init(scene: FloorplanScene,
             sun: FloorplanSunLight,
             cameraResetID: UUID,
             onRoomSelected: @escaping (UUID?, String?) -> Void,
             onSceneTouched: @escaping () -> Void,
             onLampTapped: @escaping (UUID) -> Void) {
            self.scene = scene
            self.sun = sun
            self.handledResetID = cameraResetID
            self.onRoomSelected = onRoomSelected
            self.onSceneTouched = onSceneTouched
            self.onLampTapped = onLampTapped
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
                .map { "\($0.roomID)|\($0.accent.description)|\(Int($0.brightnessKey * 8))" }
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

        /// Costruisce gli steli **una volta per insieme di stanze**.
        ///
        /// Cambiare filtro o aggiornare un sensore non sposta nessuna
        /// bandierina: cambia cosa c'è scritto sopra. Ricostruirle tutte voleva
        /// dire ridisegnare undici texture per una temperatura che si muove di
        /// un decimo di grado.
        private func rebuildFlags() {
            flagRoot.children.removeAll()
            flagLabels = []
            flagNodes = [:]
            for flag in RealityFloorplanRenderer.flagEntities(for: flags, scene: scene) {
                flagRoot.addChild(flag.root)
                flagLabels.append(flag.label)
                flagNodes[flag.roomID] = FlagNode(label: flag.label, signature: signature(of: flag.roomID))
            }
            orientFlags()
        }

        /// Aggiorna solo le etichette il cui **testo è cambiato davvero**.
        private func applyFlagStates() {
            for flag in flags {
                guard var node = flagNodes[flag.roomID] else { continue }
                let current = "\(flag.title)|\(flag.value)|\(flag.accent.description)"
                guard node.signature != current else { continue }
                if let material = FloorplanMaterialCatalog.flagLabelMaterial(title: flag.title,
                                                                            value: flag.value,
                                                                            accent: flag.accent) {
                    node.label.model?.materials = [material]
                }
                node.signature = current
                flagNodes[flag.roomID] = node
            }
        }

        private func signature(of roomID: UUID) -> String {
            guard let flag = flags.first(where: { $0.roomID == roomID }) else { return "" }
            return "\(flag.title)|\(flag.value)|\(flag.accent.description)"
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

                // **Faretto, non lampadina nuda.** Una `PointLight` irradia in
                // tutte le direzioni e su un modello senza soffitto si perde:
                // nessun fascio, nessuna pozza netta. Un faretto puntato in basso
                // è anche ciò che c'è davvero — spot nel cartongesso,
                // sospensione sul tavolo.
                let light = SpotLight()
                light.light.innerAngleInDegrees = 32
                light.light.outerAngleInDegrees = 72
                light.position = place
                light.look(at: SIMD3(place.x, floorY - centre.y, place.z),
                           from: place,
                           relativeTo: nil)
                lampRoot.addChild(light)

                // Il fascio, non un alone: una palla luminosa attorno alla
                // lampada sembra un pianeta e non dice da che parte va la luce.
                let beamHeight = place.y - (floorY - centre.y) - 0.02
                let aura = ModelEntity(
                    mesh: RealityFloorplanRenderer.lampBeamMesh(height: beamHeight,
                                                                outerAngleDegrees: 72)
                        ?? .generateSphere(radius: 0.2),
                    materials: [FloorplanMaterialCatalog.lampBeamMaterial(colour: lamp.colour,
                                                                          brightness: 1)
                                ?? UnlitMaterial(color: .clear)]
                )
                aura.position = place
                lampRoot.addChild(aura)

                var node = LampNode(bulb: bulb, spot: light, halo: aura, pool: nil)
                lampNodes[lamp.accessoryUUID] = node
                apply(lamp, to: &node)
                lampNodes[lamp.accessoryUUID] = node
            }
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
            node.spot.position = place
            node.halo.position = place

            node.bulb.model?.materials = [
                FloorplanMaterialCatalog.bulbMaterial(colour: lamp.colour, isOn: lamp.isOn)
            ]

            node.spot.isEnabled = lamp.isOn
            node.spot.light.color = lamp.colour
            node.spot.light.intensity = Float(600 + 2_400 * lamp.brightness)
            node.spot.light.attenuationRadius = Float(3.0 + 2.4 * lamp.brightness)
            node.spot.light.outerAngleInDegrees = lamp.direction == .around ? 160 : 72
            // Il faretto guarda dove punta la luce. `look` orienta l'entità, e
            // basta cambiare il bersaglio per rovesciare il fascio.
            let target = lamp.direction == .up
                ? SIMD3(place.x, place.y + 2, place.z)
                : SIMD3(place.x, floorY - centre.y, place.z)
            node.spot.look(at: target, from: place, relativeTo: nil)

            // Il cono si vede solo quando ha una direzione: «intorno» non e' un
            // fascio, e disegnarlo comunque darebbe di nuovo l'effetto pianeta.
            let showsBeam = lamp.isOn && lamp.direction != .around
            node.halo.isEnabled = showsBeam
            if showsBeam, node.beamKey != lamp.beamKey {
                let height = lamp.direction == .up
                    ? Float(0.9)
                    : max(0.2, place.y - (floorY - centre.y) - 0.02)
                if let mesh = RealityFloorplanRenderer.lampBeamMesh(height: height,
                                                                    outerAngleDegrees: 72) {
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
            let wantsPool = lamp.isOn && lamp.direction != .up
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
            rebuildLamps()
            // ⚠️ Fuori dal giro di aggiornamento. `updateSceneIfNeeded` viene
            // chiamata da `updateUIView`, cioè **durante** l'update della vista:
            // scrivere lì uno `@State` è il «Modifying state during view update»
            // che compariva in console, e SwiftUI lo dichiara comportamento
            // indefinito.
            let notify = onRoomSelected
            DispatchQueue.main.async { notify(nil, nil) }
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
            guard let entity = view.entity(at: location) else {
                selectRoom(nil)
                return
            }
            if let lampID = accessoryID(from: entity) {
                onLampTapped(lampID)
                return
            }
            guard let roomID = roomID(from: entity) else {
                selectRoom(nil)
                return
            }
            selectRoom(roomID)
        }

        private func roomID(from entity: Entity) -> UUID? {
            if let id = parseRoomID(entity.name) { return id }
            return entity.parent.flatMap(roomID(from:))
        }

        private func accessoryID(from entity: Entity) -> UUID? {
            if entity.name.hasPrefix("lamp:") {
                return UUID(uuidString: String(entity.name.dropFirst(5)))
            }
            return entity.parent.flatMap(accessoryID(from:))
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
        var roomID: UUID
        var root: Entity
        /// Solo l'etichetta si gira verso la telecamera: lo stelo è verticale e
        /// non ha un davanti.
        var label: ModelEntity
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

            return Flag(roomID: flag.roomID, root: root, label: label)
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

    /// Il cono di luce di un faretto: apice sul bulbo, base sul pavimento.
    ///
    /// Costruito a mano invece che con una primitiva perché servono le UV: la
    /// **v** va da 0 all'apice a 1 alla base, così la sfumatura verticale lo
    /// spegne scendendo. Emesso da entrambi i lati, o entrandoci dentro con la
    /// telecamera sparirebbe.
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
