import SwiftUI
import SwiftData
import Combine
import RealityKit
import HomeKit
import UIKit

// MARK: - FloorplanRealityPreviewView


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
    private var northBearingDegrees: Double { current.readNorthBearing() }
    private var markers: [Preview3DMarker] { current.markers }
    private var exportRotation: DrawingExportRotation { current.exportRotation }
    private var background: UIColor { current.background }
    private func onNorthBearingChange(_ bearing: Double) { current.applyNorthBearing(bearing) }
    /// La scrittura resta fuori dalla vista, come per il nord e le lampade.
    private func applyCeilingHeight(_ metres: Double) {
        ceilingHeight = metres
        current.applyCeilingHeight(metres)
        selectedRoomName = nil
        rebuildScene()
    }

    private func applyLampSettings(_ uuid: UUID,
                                   _ height: Double,
                                   _ direction: LampDirection?,
                                   _ renderStyle: LampRenderStyle? = nil) {
        current.applyLampSettings(uuid, height, direction, renderStyle)
        // ⚠️ **Niente `rebuildScene()`.** Quota e direzionalita' di una lampada
        // non spostano un muro: qui c'era una riestrusione completa della casa —
        // muri, aperture, arredi, velature — per **ogni passo** del cursore, e il
        // cursore ne ha sessanta. Basta il segnale: `litLights` lo rilegge, e le
        // lampade si aggiornano in posto come gia' fanno per un interruttore.
        settingsRevision &+= 1
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    /// Copia locale per la reattivita' del passo: il modello e' la verita', ma
    /// il pulsante deve rispondere prima che SwiftData torni indietro.
    @State private var ceilingHeight: Double = 2.4
    @State private var floorplanScene: FloorplanScene?
    @State private var cameraCommand = CameraCommand(id: UUID(), preset: .angle)
    @State private var selectedRoomName: String?
    @State private var selectedRoomID: UUID?
    /// Cambia a ogni salvataggio, per rileggere il modello.
    ///
    /// Non contiene dati: e' un segnale. I valori restano in SwiftData, che e'
    /// l'unica fonte di verita'.
    @State private var settingsRevision = 0
    /// Quale accessorio si sta configurando. Non serve azzerarlo cambiando
    /// stanza: un UUID di un'altra stanza semplicemente non trova riscontro, e
    /// si ricade sul primo della lista.
    @State private var selectedLampUUID: UUID?
    @State private var showsPlacementSwitches = false
    /// L'accessorio di cui si sta guardando la scheda. E' la **stessa** del 2D:
    /// il 3D non gestisce l'accessorio, lo consegna.
    @State private var detailAccessory: HMAccessory?
    @State private var detailRoom: RoomSheetTarget?
    /// Cosa mostra il bordo basso per la stanza selezionata: prima il menu
    /// delle tre azioni, e il pannello di configurazione solo se scelto.
    private enum RoomPanelState { case actions, setup }
    @State private var roomPanelState: RoomPanelState = .actions

    private let presenceTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    /// Una segnalazione = una stanza + un sensore fuori norma. Il pannello
    /// le impila TUTTE come pagine — prima quelle di dove sei, poi le stanze
    /// cieche — così la seconda non resta nascosta dietro la prima.
    struct PresenceIssueItem: Identifiable {
        let id = UUID()
        var roomName: String
        var sensor: SensorData
    }
    struct PresenceIssueSheetTarget: Identifiable {
        let id = UUID()
        var items: [PresenceIssueItem]
    }
    @State private var presenceIssueSheet: PresenceIssueSheetTarget?
    /// Vero se l'escalation ha acceso lei il layer Ambiente: alla chiusura
    /// del pannello si ripristina Off. Se i layer erano già una scelta
    /// dell'utente (Security, o Ambiente con un filtro suo), non si toccano.
    @State private var autoActivatedEnvironment = false
    /// Cooldown dell'auto-apertura: (stanza|tipo sensore) → ultima
    /// presentazione. Chiudere lo sheet vale come «ho visto»: lo stesso
    /// problema non torna a bussare prima di 15 minuti.
    @State private var autoPresentedIssues: [String: Date] = [:]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCompact: Bool { horizontalSizeClass == .compact }
    /// Si e' dentro una stanza in prima persona: serve per il bottone d'uscita.
    @State private var isInsideRoom = false
    /// Muri trasparenti a richiesta: la casa vera resta il default.
    @State private var ghostWalls = false
    @State private var mode: PreviewMode = .off
    @State private var didLoadEnvironment = false
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
    @State private var showsPlacementLampEffects = true
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
    #if DEBUG
    /// La macchina del tempo di debug: anteprima dei tre atti del cielo
    /// senza aspettare l'ora vera (e senza tenere il 3D acceso a scaldare
    /// l'iPad fino al tramonto). Alba e sera CERCANO l'istante di oggi con
    /// l'elevazione giusta, cosi' l'anteprima e' fedele in ogni stagione.
    private enum SkyPreview: String, CaseIterable, Identifiable {
        case auto, dawn, noon, dusk, night
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Auto"
            case .dawn: "Alba"
            case .noon: "Giorno"
            case .dusk: "Sera"
            case .night: "Notte"
            }
        }
    }
    @State private var skyPreview: SkyPreview = .auto
    #endif
    #endif
    /// Il pannello delle impostazioni della planimetria: altezza soffitto,
    /// esposizione, anteprima notte. Sono configurazioni — si toccano una
    /// volta nella vita di una planimetria — e una configurazione non merita
    /// una pillola permanente sul bordo piu' prezioso dello schermo.
    @State private var isSettingsOpen = false
    @State private var arDiagnosticsSnapshot: ARDiagnosticsSnapshot?

    /// Al primo ingresso nel 3D di una planimetria il pannello si apre da
    /// solo: altezza dei muri ed esposizione **vanno chiesti, non scoperti** —
    /// un utente nuovo non apre l'ingranaggio, e senza esposizione il sole e'
    /// sbagliato in silenzio. Dalle volte dopo, il pannello sta dietro
    /// l'ingranaggio. Il segnavia e' locale al device (UserDefaults): e' stato
    /// di UX, non un fatto della casa, e non merita lo schema.
    private func presentSetupIfFirstVisit() {
        let key = "floorplan3D.setupShown.\(currentID.uuidString)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        withAnimation(.easeOut(duration: 0.3)) { isSettingsOpen = true }
    }

    private func presentRoomSetupPanel() {
        showsPlacementSwitches = setupItemsInSelectedRoom.isEmpty && !switchablesInSelectedRoom.isEmpty
        if isCompact {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                roomPanelState = .setup
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) {
                roomPanelState = .setup
            }
        }
    }

    private func dismissRoomSetupPanel() {
        if isCompact {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                roomPanelState = .actions
            }
        } else {
            withAnimation(.easeOut(duration: 0.22)) {
                roomPanelState = .actions
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Col cover AR aperto la casa NON deve continuare a renderizzare
            // sotto: ARView non ha una pausa pubblica, e toglierla dalla
            // gerarchia è l'unico stop garantito. Al ritorno la scena si
            // ricostruisce con l'inquadratura d'apertura — prezzo accettato
            // per non tenere tre motori accesi insieme (ARKit + fondale
            // camera + una casa che nessuno vede).
            if let floorplanScene, arDiagnosticsSnapshot == nil {
                RealityFloorplanView(scene: floorplanScene,
                                     background: background,
                                     sun: sun,
                                     lamps: previewLamps,
                                     lampEffects: mode == .off || (roomPanelState == .setup && showsPlacementLampEffects),
                                     climate: climateUnits,
                                     litRooms: litRoomIDs,
                                     occupiedRooms: occupiedRoomIDs,
                                     awnings: awnings,
                                     cameras: cameraCones,
                                     flags: roomFlags,
                                     cameraCommand: cameraCommand,
                                     onRoomSelected: { roomID, name in
                                         selectedRoomID = roomID
                                         selectedRoomName = name
                                         roomPanelState = .actions
                                         showsPlacementSwitches = false
                                     },
                                     onTargetTapped: handleTap,
                                     onTargetHeld: handleHold,
                                     onFirstPersonExit: {
                                         withAnimation(.easeOut(duration: 0.22)) {
                                             isInsideRoom = false
                                         }
                                     },
                                     ghostWalls: ghostWalls)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            controls
        }
        .overlay(alignment: .bottom) {
            if selectedRoomID != nil {
                switch roomPanelState {
                case .actions: roomActionBar
                case .setup:
                    // Su iPhone il Placement è uno sheet nativo coi detent:
                    // si adatta, scorre, rispetta le safe area. Il pannello
                    // flottante resta il formato da iPad.
                    if !isCompact { roomSetupPanel }
                }
            } else if isInsideRoom {
                // L'uscita esplicita: il doppio tocco funziona, ma un bottone
                // che dice «esci» non va scoperto.
                Button {
                    cameraCommand = CameraCommand(id: UUID(), preset: .angle)
                    withAnimation(.easeOut(duration: 0.22)) { isInsideRoom = false }
                } label: {
                    Label(String(localized: "room.exit", defaultValue: "Exit room"),
                          systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .glassChromeSurface(in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 104)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                topChrome
                if mode == .environment { filterRow }
                if mode == .security { securityStatusPill }
            }
        }
        .overlay(alignment: .topTrailing) {
            settingsPanel
                .padding(.top, 68)
                .padding(.trailing, 16)
        }
        .statusBarHidden()
        .sheet(isPresented: compactSetupSheetBinding) {
            NavigationStack {
                ScrollView {
                    setupPanelContent
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .navigationTitle(selectedRoomName ?? "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "common.done", defaultValue: "Done")) {
                            dismissRoomSetupPanel()
                        }
                    }
                }
            }
            .transaction { transaction in
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $detailAccessory) { accessory in
            AccessoryDetailView(accessory: accessory)
        }
        .sheet(item: $detailRoom) { target in
            RoomDetailSheet(room: target.room)
        }
        // Non uno .sheet: su iPad diventerebbe una card centrale. La
        // segnalazione è un PANNELLO ancorato in basso, largo quanto lo
        // schermo — il formato del tablet a muro.
        .overlay(alignment: .bottom) {
            if let target = presenceIssueSheet {
                PresenceIssuePanelView(
                    items: target.items,
                    urgencyColour: urgencyColour,
                    onPageChange: { item in
                        // Lo swipe pilota il layer: la casa si ritinge sul
                        // tipo che stai guardando — ma solo se i layer li ha
                        // accesi l'escalation, mai sopra una scelta tua.
                        if autoActivatedEnvironment {
                            withAnimation(.easeOut(duration: 0.25)) {
                                sensorFilter = item.sensor.serviceType
                            }
                        }
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            presenceIssueSheet = nil
                            if autoActivatedEnvironment {
                                mode = .off
                                sensorFilter = nil
                                autoActivatedEnvironment = false
                            }
                        }
                    },
                    onOpenRoom: { roomName in
                        presenceIssueSheet = nil
                        openRoomDetails(named: roomName)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $arDiagnosticsSnapshot) { snapshot in
            ARDiagnosticsView(snapshot: snapshot)
        }
        .onAppear {
            exposure = Exposure.nearest(to: northBearingDegrees)
            ceilingHeight = current.ceilingHeight
            // Senza questo i sensori non sono mai stati letti e risultano tutti
            // chiusi: `startObserving` fa il readValue iniziale e arma le
            // notifiche. La vista si apre dalla lista, che non osserva niente.
            observeCurrentFloorplan()
            rebuildScene()
            presentSetupIfFirstVisit()
            loadEnvironmentIfNeeded()
            homeKit.startObserving(accessoryUUIDs: RoomPresenceLocator.presenceAccessoryUUIDs(homeKit: homeKit))
        }
        .onReceive(presenceTick) { _ in
            refreshPresenceIssue()
        }
        // Lo stato non è più una fotografia: se apri una finestra mentre stai
        // guardando, l'anta si muove. `characteristicValues` è osservabile, e
        // ricalcolare l'insieme costa una manciata di confronti.
        .onChange(of: openOpeningIDs) { _, _ in rebuildScene() }
        // Una tapparella che scende cambia la geometria, quindi va ricostruita —
        // ma a scatti di un ventesimo, non a ogni millimetro riportato da
        // HomeKit: una corsa intera fa venti ricostruzioni in venti secondi,
        // non duecento.
        .onChange(of: closedShutters) { _, _ in rebuildScene() }
        // Cambiando piano cambiano gli accessori: quelli vecchi si lasciano
        // andare e si osservano i nuovi, o il piano appena aperto avrebbe luci
        // spente e porte chiuse per il solo motivo che nessuno le ha lette.
        .onChange(of: currentID) { _, _ in
            observeCurrentFloorplan()
            // L'altezza e' un fatto di **questo** piano: una mansarda non e' un
            // piano terra, e portarsi dietro la quota di prima disegnerebbe la
            // casa sbagliata.
            ceilingHeight = current.ceilingHeight
            rebuildScene()
            presentSetupIfFirstVisit()
        }
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
        case .off:         nameFlags
        case .environment: environmentFlags
        case .security:    securityFlags
        }
    }

    /// Fuori dagli strati tematici le bandierine sono libere, e una casa vista
    /// dall'alto senza nomi e' un labirinto: qui portano solo **come si chiama
    /// la stanza**, che e' anche quello che serve per sapere su cosa si sta per
    /// aprire il pannello luci.
    ///
    /// Nessun accento: non c'e' nessuno stato da raccontare, e fingerne uno
    /// svuoterebbe il colore negli strati dove invece significa qualcosa.
    private var nameFlags: [RoomFlag] {
        FloorplanRoomEnvironment.anchors(in: document).map { anchor in
            RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                     title: "", value: anchor.roomName,
                     accent: nil, needsAttention: false)
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
                                value: sensor.formattedValue
                                    + (filter == .temperature ? climateArrow(inRoomNamed: anchor.roomName) : ""),
                                accent: UIColor(urgencyColour(sensor.urgency)),
                                needsAttention: sensor.urgency != .normal)
            }

            // La bandierina porta il **giudizio** (il punteggio, col suo
            // colore di scala); la velatura su pavimento e muri parla solo la
            // lingua degli **avvisi** — arancio, rosso — e si accende solo se
            // un sensore sfora davvero. Il giallo «Discreta» steso a terra si
            // confondeva con la luce delle lampade e non diceva una gravita'.
            let worst = worstUrgency(in: data)
            return RoomFlag(roomID: anchor.roomID, anchor: anchor.point,
                            title: anchor.roomName,
                            value: "\(Int(data.qualityScore * 100))% \(data.qualityLabel)",
                            accent: worst == .normal
                                ? UIColor(data.qualityColor)
                                : UIColor(urgencyColour(worst)),
                            needsAttention: worst != .normal)
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
    /// L'escalation da pannello a muro: il BOLLETTINO della casa. Le pagine
    /// sono i problemi di TUTTE le stanze, a prescindere — la presenza non
    /// filtra più, decide solo la priorità: se i sensori ti riconoscono in
    /// una stanza, i suoi problemi aprono il giornale; le altre seguono
    /// dalla peggiore. Sempre: solo su problemi, mai sopra qualcos'altro,
    /// col cooldown per (stanza, tipo).
    private func refreshPresenceIssue() {
        let isFreeOfModals = detailRoom == nil && detailAccessory == nil
            && selectedRoomID == nil && !isInsideRoom
            && presenceIssueSheet == nil
        guard isFreeOfModals else { return }

        // Ordine: dove sei (se riconosciuto), poi tutte le altre dalla peggiore.
        var orderedRooms: [String] = []
        if let local = RoomPresenceLocator.activeDetections(homeKit: homeKit).first?.roomName,
           document.roomAreas.contains(where: { $0.name == local }) {
            orderedRooms.append(local)
        }
        let others = document.roomAreas
            .filter { !orderedRooms.contains($0.name) }
            .compactMap { area -> (name: String, urgency: SensorUrgency)? in
                guard let data = envVM.rooms.first(where: { $0.roomName == area.name }),
                      data.worstUrgency != .normal else { return nil }
                return (area.name, data.worstUrgency)
            }
            .sorted { $0.urgency.rawValue > $1.urgency.rawValue }
        orderedRooms.append(contentsOf: others.map(\.name))

        // Le pagine: ogni sensore fuori norma, filtrato dal cooldown.
        let cooldown: TimeInterval = 15 * 60
        var items: [PresenceIssueItem] = []
        for roomName in orderedRooms {
            guard let data = envVM.rooms.first(where: { $0.roomName == roomName }) else { continue }
            let anomalous = data.sensors
                .filter { $0.urgency != .normal }
                .sorted { $0.urgency.rawValue > $1.urgency.rawValue }
            for sensor in anomalous {
                let key = "\(roomName)|\(sensor.serviceType.rawValue)"
                if let lastShown = autoPresentedIssues[key],
                   Date.now.timeIntervalSince(lastShown) <= cooldown { continue }
                items.append(PresenceIssueItem(roomName: roomName, sensor: sensor))
            }
        }
        guard let first = items.first else { return }

        for item in items {
            autoPresentedIssues["\(item.roomName)|\(item.sensor.serviceType.rawValue)"] = .now
        }
        withAnimation(.easeOut(duration: 0.3)) {
            presenceIssueSheet = PresenceIssueSheetTarget(items: items)
            // Il contesto dietro l'avviso: la casa si accende sul layer
            // Ambiente, filtrata sulla prima pagina. SOLO da Off: una
            // modalità scelta dall'utente non si ruba.
            if mode == .off {
                mode = .environment
                sensorFilter = first.sensor.serviceType
                autoActivatedEnvironment = true
            }
        }
    }

    /// La stessa scheda stanza del menu Details, per nome.
    private func openRoomDetails(named name: String) {
        guard let room = RoomSecurityEvaluator
            .accessories(inRoomNamed: name, homeKit: homeKit)
            .first?.room
        else { return }
        detailRoom = RoomSheetTarget(room: room)
    }

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

    /// Il campo visivo delle telecamere posate, solo nello strato Sicurezza.
    ///
    /// Lo strato dice **che** una telecamera c'è; il cono dice **cosa vede**,
    /// che è la domanda vera quando si guarda una casa dall'alto.
    ///
    /// ⚠️ Il verso non è nel modello — nessuno ha mai detto dove guarda quella
    /// telecamera. Il default non è però un tiro a caso come per le porte: una
    /// telecamera sta su una parete e guarda **dentro** la stanza, quindi punta
    /// verso il punto più interno — lo stesso che regge la bandierina. Sbaglia
    /// solo su chi inquadra di sbieco, e resta correggibile il giorno che ci
    /// sarà un ispettore.
    private var cameraCones: [FloorplanCameraCone] {
        guard mode == .security,
              let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        let anchors = FloorplanRoomEnvironment.anchors(in: document)

        return markers.compactMap { marker -> FloorplanCameraCone? in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  isCamera(accessory)
            else { return nil }

            let position = transform.metres(from: marker.position)
            let room = document.roomAreas.first { area in
                FloorplanRoomEnvironment.contains(position, area.effectivePoints.map {
                    SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
                })
            }
            guard let room,
                  let anchor = anchors.first(where: { $0.roomID == room.id })
            else { return nil }

            let delta = anchor.point - position
            let distance = simd_length(delta)
            // Una telecamera piazzata proprio sul punto d'ancoraggio non ha un
            // verso: meglio nessun cono che uno inventato.
            guard distance > 0.35 else { return nil }

            return FloorplanCameraCone(accessoryUUID: marker.uuid,
                                       position: position,
                                       direction: delta / distance)
        }
    }

    /// Sposta un punto contro la parete più vicina e restituisce l'angolo per
    /// starci in piano.
    ///
    /// Il muro più vicino si sceglie sulla **proiezione** e non sugli estremi:
    /// un termosifone a metà di una parete lunga sarebbe altrimenti più vicino
    /// allo spigolo di un muretto corto lì accanto.
    private func againstNearestWall(_ point: SIMD2<Double>,
                                    depth: Double) -> (position: SIMD2<Double>, bearing: Double) {
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        var best: (foot: SIMD2<Double>, axis: SIMD2<Double>, thickness: Double, distance: Double)?

        for wall in document.walls where wall.kind.rendersAsPhysicalWall {
            let a = SIMD2(Double(wall.start.x) * metresPerPoint, Double(wall.start.y) * metresPerPoint)
            let b = SIMD2(Double(wall.end.x) * metresPerPoint, Double(wall.end.y) * metresPerPoint)
            let span = b - a
            let length = simd_length(span)
            guard length > 0.01 else { continue }

            let axis = span / length
            let t = max(0, min(length, simd_dot(point - a, axis)))
            let foot = a + axis * t
            let distance = simd_distance(point, foot)
            if best == nil || distance < best!.distance {
                best = (foot, axis,
                        Double(DrawingDocument.wallWidth(for: wall.kind)) * metresPerPoint,
                        distance)
            }
        }

        guard let best else { return (point, 0) }
        // Dal piede della perpendicolare si torna **verso la stanza** di mezzo
        // spessore più mezza profondità: così l'apparecchio tocca la parete
        // invece di entrarci dentro.
        let away = point - best.foot
        let length = simd_length(away)
        let outward = length > 0.001 ? away / length : SIMD2(-best.axis.y, best.axis.x)
        let position = best.foot + outward * (best.thickness / 2 + depth / 2)

        // ⚠️ La rotazione si calcola dal verso **fuori dal muro**, non
        // dall'asse del muro: l'asse lascia il fronte ambiguo di 180 gradi, e
        // su meta' dei muri il pallino di modalita' finiva nell'intercapedine
        // fra corpo e parete — invisibile finche' i muri erano pieni, svelato
        // dalla trasparenza. Con atan2(outward) il +z locale guarda sempre la
        // stanza, e cio' che sta sul fronte sta davvero davanti.
        return (position, atan2(outward.x, outward.y))
    }

    private func isCamera(_ accessory: HMAccessory) -> Bool {
        if accessory.cameraProfiles?.isEmpty == false { return true }
        return accessory.category.categoryType == HMAccessoryCategoryTypeIPCamera
            || accessory.category.categoryType == HMAccessoryCategoryTypeVideoDoorbell
    }

    /// Le stanze **abitate adesso**, dai sensori di movimento e presenza.
    ///
    /// Il segnale e' quello pubblico di `SensorAdapter`
    /// (`markerRuntimeState == .sensorTriggered`): nessuna lettura riscritta.
    /// Si filtra prima per caratteristica, o un sensore di fumo in allarme
    /// conterebbe come qualcuno in casa.
    private var occupiedRoomIDs: Set<UUID> {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)

        var result: Set<UUID> = []
        for marker in markers {
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  accessory.services.contains(where: { service in
                      service.characteristics.contains {
                          $0.characteristicType == HMCharacteristicTypeMotionDetected
                              || $0.characteristicType == HMCharacteristicTypeOccupancyDetected
                      }
                  })
            else { continue }

            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            guard (adapter as? MarkerRuntimeStateProviding)?.markerRuntimeState == .sensorTriggered
            else { continue }

            let position = transform.metres(from: marker.position)
            if let area = document.roomAreas.first(where: { area in
                FloorplanRoomEnvironment.contains(position, area.effectivePoints.map {
                    SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
                })
            }) {
                result.insert(area.id)
            }
        }
        return result
    }

    /// Le stanze illuminate, quando fuori è buio.
    ///
    /// Di giorno resta vuoto di proposito: una finestra accesa in pieno sole non
    /// si vede nemmeno nella realtà, e disegnarla sarebbe una luce che non c'è.
    private var litRoomIDs: Set<UUID> {
        guard !sun.isAboveHorizon else { return [] }

        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        let lit = litLights.filter(\.isOn)
        guard !lit.isEmpty else { return [] }

        return Set(document.roomAreas.compactMap { area -> UUID? in
            let polygon = area.effectivePoints.map {
                SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
            }
            return lit.contains { FloorplanRoomEnvironment.contains($0.position, polygon) }
                ? area.id
                : nil
        })
    }

    /// La freccia accanto ai gradi: dice che qualcosa **sta lavorando**, e in
    /// che verso.
    ///
    /// Sulla bandierina e non sulla tinta della stanza: quel canale è già preso
    /// da ambiente e sicurezza, e un colore che vuol dire due cose non ne vuol
    /// dire nessuna — è l'errore già fatto e corretto con l'ambra della
    /// selezione. Solo accanto a una temperatura: «45% ↑» non vorrebbe dire
    /// niente.
    ///
    /// Le stanze si accoppiano **per nome**, come tutto il resto delle
    /// bandierine: così la freccia c'è anche su una planimetria appena
    /// disegnata, dove non è stato posato ancora nessun marker.
    private func climateArrow(inRoomNamed name: String) -> String {
        for accessory in RoomSecurityEvaluator.accessories(inRoomNamed: name, homeKit: homeKit) {
            guard let unit = FloorplanClimateReader.unit(for: accessory, homeKit: homeKit),
                  let arrow = unit.activity.arrow
            else { continue }
            return " " + arrow
        }
        return ""
    }

    /// Le unità di clima **posate sulla planimetria**.
    ///
    /// Come le lampade e a differenza delle bandierine: un termosifone lo devi
    /// aver messo da qualche parte, o non c'è niente da mostrare né da toccare.
    /// La quota vive su `mountHeight`, lo stesso campo delle lampade — è la
    /// stessa domanda, «a che altezza sta».
    private var climateUnits: [FloorplanClimateUnit] {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        return markers.compactMap { marker in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  let unit = FloorplanClimateReader.unit(for: accessory, homeKit: homeKit)
            else { return nil }

            _ = settingsRevision
            // Uno split appeso in mezzo alla stanza non esiste: si appoggia al
            // muro più vicino, e ne prende anche l'inclinazione. La posa in 2D
            // dice **quale parete**, non il centimetro — quello lo fa la
            // geometria, che il disegno ce l'ha.
            let dropped = transform.metres(from: current.lampSettings(marker.uuid).position
                                           ?? marker.position)
            let placed = againstNearestWall(dropped, depth: Double(unit.form.size.z))

            return FloorplanClimateUnit(accessoryUUID: marker.uuid,
                                        name: accessory.name,
                                        form: unit.form,
                                        tint: unit.activity.bodyTint,
                                        modeTint: unit.modeTint,
                                        position: placed.position,
                                        height: current.lampSettings(marker.uuid).height
                                            ?? unit.form.defaultHeight,
                                        bearing: placed.bearing)
        } + securityPanels + televisions
    }

    /// Gli schermi TV posati: il corpo e' il pannello, la spia e' il pallino —
    /// verde da accesa, niente da spenta — e da accesa lo schermo si schiarisce
    /// di grigio-blu: una TV accesa in una stanza si vede. Lettura da
    /// `TelevisionAdapter`, che il servizio Television lo conosce gia'.
    private var televisions: [FloorplanClimateUnit] {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        return markers.compactMap { marker in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  let tv = TelevisionAdapter(accessory: accessory, homeKit: homeKit)
            else { return nil }

            _ = settingsRevision
            let form = FloorplanClimateReader.Form.television
            let placed = againstNearestWall(
                transform.metres(from: current.lampSettings(marker.uuid).position ?? marker.position),
                depth: Double(form.size.z))
            return FloorplanClimateUnit(accessoryUUID: marker.uuid,
                                        name: accessory.name,
                                        form: form,
                                        tint: tv.isOn
                                            ? UIColor(red: 0.36, green: 0.41, blue: 0.50, alpha: 1)
                                            : UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1),
                                        modeTint: tv.isOn ? .systemGreen : nil,
                                        position: placed.position,
                                        height: current.lampSettings(marker.uuid).height
                                            ?? form.defaultHeight,
                                        bearing: placed.bearing)
        }
    }

    /// La centralina dell'antifurto, se e' stata posata: un pannello a muro
    /// nella stessa famiglia dei corpi clima. Il colore e' lo stato — viola
    /// inserito, rosso allarme, bianco a riposo. Nessun tocco rapido: quattro
    /// stati non sono un interruttore, e per quelli c'e' la scheda.
    private var securityPanels: [FloorplanClimateUnit] {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        return markers.compactMap { marker in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  let service = accessory.services.first(where: {
                      $0.serviceType == HMServiceTypeSecuritySystem
                  }),
                  let characteristic = service.characteristics.first(where: {
                      $0.characteristicType == HMCharacteristicTypeCurrentSecuritySystemState
                  })
            else { return nil }

            let raw = RoomSecurityEvaluator.intValue(
                homeKit.value(for: characteristic) ?? characteristic.value
            ) ?? 3
            let tint: UIColor = switch raw {
            case 4:  .systemRed
            case 3:  UIColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
            default: .systemPurple
            }

            _ = settingsRevision
            let form = FloorplanClimateReader.Form.securityPanel
            let placed = againstNearestWall(
                transform.metres(from: current.lampSettings(marker.uuid).position ?? marker.position),
                depth: Double(form.size.z))
            return FloorplanClimateUnit(accessoryUUID: marker.uuid,
                                        name: accessory.name,
                                        form: form,
                                        tint: tint,
                                        modeTint: nil,
                                        position: placed.position,
                                        height: current.lampSettings(marker.uuid).height
                                            ?? form.defaultHeight,
                                        bearing: placed.bearing)
        }
    }


    /// Quanto è stesa la tenda di ogni balcone.
    ///
    /// ⚠️ HomeKit espone una tenda **identica** a una tapparella: stesso
    /// servizio, stessa caratteristica, nessun modo di distinguerle. Si
    /// distinguono da **dove sono state posate**: `nearestOpening` aggancia un
    /// marker a un vano solo entro 80 cm, quindi una copertura messa in mezzo a
    /// un balcone resta senza `linkedOpeningID` — e quella è una tenda. È anche
    /// il gesto naturale: la tenda non sta sulla porta, sta sopra il balcone.
    ///
    /// Il verso invece è l'opposto della tapparella: chiudere una tapparella
    /// vuol dire calarla, chiudere una tenda vuol dire **ritirarla**. Quindi
    /// stesa = aperta.
    private var balconyAwnings: [(areaID: UUID, accessoryUUID: UUID, extended: Double)] {
        let balconies = FloorplanExtruder.balconyAreaIDs(in: document)
        guard !balconies.isEmpty,
              let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }

        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        var result: [(areaID: UUID, accessoryUUID: UUID, extended: Double)] = []

        for marker in markers where marker.openingID == nil {
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  let open = FloorplanOpeningMatcher.coveringPosition(accessory, using: homeKit)
            else { continue }

            let position = transform.metres(from: marker.position)
            guard let area = document.roomAreas.first(where: { area in
                balconies.contains(area.id)
                    && FloorplanRoomEnvironment.contains(position, area.effectivePoints.map {
                        SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
                    })
            }), !result.contains(where: { $0.areaID == area.id }) else { continue }

            // **Chiusa = copre**, la stessa convenzione della tapparella: una
            // tenda chiusa è quella stesa a fare ombra. Il verso opposto
            // disegnava il cassonetto quando il telo era fuori, e viceversa.
            result.append((area.id, marker.uuid,
                           (max(0, min(1, 1 - open / 100)) * 20).rounded() / 20))
        }
        return result
    }

    private var awnings: [FloorplanAwning] {
        balconyAwnings.compactMap { item in
            guard let area = document.roomAreas.first(where: { $0.id == item.areaID }),
                  let geometry = FloorplanExtruder.awningGeometry(over: area, in: document,
                                                                  heights: .init(ceiling: ceilingHeight))
            else { return nil }
            return FloorplanAwning(roomID: item.areaID,
                                   accessoryUUID: item.accessoryUUID,
                                   extended: item.extended,
                                   geometry: geometry)
        }
    }

    /// Da cosa si tocca all'accessorio da comandare.
    private func accessoryUUID(for target: FloorplanTapTarget) -> UUID? {
        switch target {
        case .accessory(let uuid):
            return uuid
        case .awning(let roomID):
            return balconyAwnings.first { $0.areaID == roomID }?.accessoryUUID
        case .shutter(let openingID):
            return markers.first { marker in
                marker.openingID == openingID
                    && homeKit.accessory(for: marker.uuid)
                        .flatMap { FloorplanOpeningMatcher.coveringPosition($0, using: homeKit) } != nil
            }?.uuid
        case .room:
            return nil
        }
    }

    /// **Il tocco vale dove ci sono due stati**, la pressione lunga dove c'è una
    /// scala. Una lampada e una tapparella sono acceso/spento e su/giù: un tocco
    /// li risolve. Un termostato no — «toccare» un condizionatore non vuol dire
    /// niente, e per quello c'è la scheda.
    private func handleTap(_ target: FloorplanTapTarget) {
        guard let uuid = accessoryUUID(for: target) else { return }
        if case .accessory = target,
           let accessory = homeKit.accessory(for: uuid),
           !FloorplanLampReader.isLight(accessory) {
            return
        }
        toggleAccessory(uuid)
    }

    private func handleHold(_ target: FloorplanTapTarget) {
        if case .room(let roomID) = target {
            // La stessa scheda stanza del 2D: la stanza si accoppia per nome,
            // e l'`HMRoom` lo si prende dal primo accessorio che ci abita —
            // nessuna API nuova per una cosa che la security sa gia' fare.
            guard let name = document.roomAreas.first(where: { $0.id == roomID })?.name,
                  let room = RoomSecurityEvaluator
                      .accessories(inRoomNamed: name, homeKit: homeKit)
                      .first?.room
            else { return }
            detailRoom = RoomSheetTarget(room: room)
            return
        }
        guard let uuid = accessoryUUID(for: target) else { return }
        detailAccessory = homeKit.accessory(for: uuid)
    }

    /// `HMRoom` non e' `Identifiable`: il foglio ha bisogno di un involucro.
    private struct RoomSheetTarget: Identifiable {
        let room: HMRoom
        var id: UUID { room.uniqueIdentifier }
    }

    /// Quanto è calata ogni tapparella, contro lo stato corrente di HomeKit.
    private var closedShutters: [UUID: Double] {
        FloorplanOpeningMatcher.closedShutters(
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
        let instant = skyPreviewInstant(coordinate: coordinate) ?? now
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

    #if DEBUG
    private func skyPreviewInstant(coordinate: (latitude: Double, longitude: Double)) -> Date? {
        guard skyPreview != .auto else { return nil }
        let start = Calendar.current.startOfDay(for: now)
        switch skyPreview {
        case .noon:
            return start.addingTimeInterval(13 * 3_600)
        case .night:
            return start.addingTimeInterval(1 * 3_600)
        case .dawn, .dusk:
            // Il minuto di oggi con il sole a ~+2°: dentro la fascia del
            // crepuscolo qualunque sia la stagione.
            let window = skyPreview == .dawn
                ? stride(from: 0.0, to: 12 * 3_600, by: 300)
                : stride(from: 12 * 3_600, to: 24 * 3_600, by: 300)
            var best: (date: Date, distance: Double)?
            for offset in window {
                let candidate = start.addingTimeInterval(offset)
                let elevation = SolarPosition.position(at: candidate,
                                                       latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude).elevationDegrees
                let distance = abs(elevation - 2)
                if best == nil || distance < best!.distance {
                    best = (candidate, distance)
                }
            }
            return best?.date
        case .auto:
            return nil
        }
    }
    #endif

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
                            exposure = Exposure.nearest(to: plan.readNorthBearing())
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
                    // ⚠️ `Color.primary` esplicito, non lo stile gerarchico:
                    // dentro Button e Menu quello gerarchico perde contro la
                    // tinta di sistema, e le scritte diventavano blu.
                    .foregroundStyle(Color.primary)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 38)
                    .glassChromeSurface(in: Capsule())
                }

                Spacer(minLength: 12)

                Button {
                    withAnimation(.easeOut(duration: 0.22)) { isSettingsOpen.toggle() }
                } label: {
                    chrome("gearshape")
                }

                // Tre inquadrature pronte invece di un solo reset: ognuna fa
                // un mestiere diverso — controllare (alto), guardare (angolo),
                // mostrare (fronte).
                Menu {
                    Button {
                        cameraCommand = CameraCommand(id: UUID(), preset: .plan)
                    } label: {
                        Label(String(localized: "camera.plan", defaultValue: "Plan"),
                              systemImage: "map")
                    }
                    Button {
                        cameraCommand = CameraCommand(id: UUID(), preset: .top)
                    } label: {
                        Label(String(localized: "camera.top", defaultValue: "From above"),
                              systemImage: "square.grid.2x2")
                    }
                    Button {
                        cameraCommand = CameraCommand(id: UUID(), preset: .angle)
                    } label: {
                        Label(String(localized: "camera.angle", defaultValue: "Three-quarter"),
                              systemImage: "cube")
                    }
                    Button {
                        cameraCommand = CameraCommand(id: UUID(), preset: .front)
                    } label: {
                        Label(String(localized: "camera.front", defaultValue: "Eye level"),
                              systemImage: "eye")
                    }

                    Divider()

                    // L'AR resta in casa ma fuori vetrina: l'esperimento ha
                    // dato il suo verdetto (la localizzazione la fa la
                    // presenza, il valore quotidiano dell'overlay è basso) e
                    // la voce di menù vive solo nelle build di sviluppo. Il
                    // codice sotto — aligner, calibrazione, vista — resta
                    // pronto per il giorno del commissioning-puntando.
                    #if DEBUG
                    Button {
                        presentARDiagnostics()
                    } label: {
                        Label(String(localized: "ar.diagnostics.title",
                                     defaultValue: "AR Diagnostics"),
                              systemImage: "arkit")
                    }
                    #endif

                    // La trasparenza e' una **scelta**, non un default: la casa
                    // vera resta vera, e quando serve sbirciare dalle
                    // inquadrature basse si accende — l'utilita' del
                    // concorrente senza pagarne il costo fisso.
                    Button {
                        ghostWalls.toggle()
                    } label: {
                        Label(String(localized: "camera.ghostWalls",
                                     defaultValue: "See-through walls"),
                              systemImage: ghostWalls ? "checkmark.square" : "square")
                    }
                } label: {
                    // Un mirino, non una freccia: e' il bottone delle
                    // inquadrature, e la freccia all'indietro non invitava
                    // nessuno a premerla.
                    chrome("viewfinder")
                }
            }

            modeRow
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// La superficie e' `glassChromeSurface`, come tutta la chrome dell'app:
    /// vetro vero col toggle attivo, esattamente il materiale di oggi
    /// altrimenti. Il 3D l'aveva bypassata con `.regularMaterial` crudo — la
    /// base grigia che si vedeva.
    private func chrome(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.headline)
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
            .glassChromeSurface(in: Circle())
    }

    private var controls: some View {
        VStack(spacing: 10) {
            // Solo il nome della lampada toccata: quello della stanza lo porta
            // gia' il menu delle azioni, e scritto due volte era un doppione.
            if let caption = lampCaption {
                Text(caption)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassChromeSurface(in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.bottom, 28)
    }

    /// Le impostazioni della planimetria, raccolte dietro l'ingranaggio.
    ///
    /// Stile del pannello di stanza: piu' denso della cornice perche' **si
    /// usa**, traslucido perche' il modello deve reagire mentre regoli.
    @ViewBuilder
    private var settingsPanel: some View {
        if isSettingsOpen {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 15))
                    Text(title).font(.title3.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(.primary)

                Divider().overlay(Color.primary.opacity(0.2))

                HStack(spacing: 12) {
                    Text(String(localized: "floorplan.ceilingHeight", defaultValue: "Ceiling height"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        applyCeilingHeight(max(2.0, ceilingHeight - 0.1))
                    } label: {
                        Image(systemName: "minus").frame(width: 38, height: 34)
                    }
                    Text(ceilingHeight.formatted(.number.precision(.fractionLength(1))) + " m")
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 58)
                    Button {
                        applyCeilingHeight(min(4.0, ceilingHeight + 0.1))
                    } label: {
                        Image(systemName: "plus").frame(width: 38, height: 34)
                    }
                }
                .foregroundStyle(Color.primary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 12) {
                        Text(String(localized: "floorplan.exposure", defaultValue: "Top of the plan faces"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        exposureMenu
                    }
                    // Trappola provata sul campo: «casa mia guarda a sud-ovest»
                    // parla del balcone, il menù parla del bordo alto del
                    // DISEGNO — e i due possono differire di 90°. Da qui
                    // dipendono il sole e la bussola AR: l'equivoco va
                    // disinnescato nel punto esatto in cui nasce.
                    Text(String(localized: "floorplan.exposure.hint",
                                defaultValue: "The top edge of the drawing — not where the balcony or façade faces."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                #if DEBUG
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "Anteprima cielo (debug)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(selection: $skyPreview) {
                        ForEach(SkyPreview.allCases) { preview in
                            Text(verbatim: preview.label).tag(preview)
                        }
                    } label: { EmptyView() }
                    .pickerStyle(.segmented)
                }
                #endif
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(width: 370)
            .modifier(PanelChrome())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
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
            HStack(spacing: 5) {
                Image(systemName: "location.north.line").font(.caption)
                Text(exposure.shortLabel).font(.headline)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Color.primary.opacity(0.12), in: Capsule())
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
        HStack(spacing: 3) {
            ForEach(PreviewMode.allCases) { value in
                let isSelected = mode == value
                Button {
                    if value == .environment { loadEnvironmentIfNeeded() }
                    withAnimation(.easeOut(duration: 0.22)) {
                        mode = value
                        if value != .environment { sensorFilter = nil }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: value.symbol).font(.system(size: 13, weight: .semibold))
                        // La parola solo sull'attivo: le tre scritte insieme
                        // farebbero una barra lunga quanto lo schermo, e le due
                        // spente non hanno niente da dire.
                        if isSelected {
                            Text(value.label).font(.subheadline.weight(.semibold))
                        }
                    }
                    // Sul colore dello strato il testo resta bianco; sul
                    // materiale i colori sono semantici.
                    // 0.55 su vetro chiaro leggeva «disabilitato», non
                    // «non selezionato»: la gerarchia resta, il grigiore no.
                    .foregroundStyle(isSelected
                                     ? (value.accent != nil ? Color.white : Color.primary)
                                     : Color.primary.opacity(0.78))
                    .padding(.horizontal, isSelected ? 14 : 13)
                    .frame(minWidth: isSelected ? 0 : 44, minHeight: 38)
                    .background(isSelected ? (value.accent ?? Color.primary.opacity(0.14)) : .clear,
                                in: Capsule())
                    // ⚠️ Senza questa riga i segmenti spenti si toccavano solo
                    // sull'icona: lo sfondo e' trasparente, e SwiftUI non
                    // considera tappabili i pixel trasparenti. La forma di
                    // hit-test va dichiarata, non dedotta dal colore.
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(value.label))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .glassChromeSurface(in: Capsule())
    }

    /// I tipi sono un livello **sotto** la modalità, e devono sembrarlo: gruppo
    /// separato, più smorzato, sotto la barra alta — come nella 2D, dove i
    /// filtri stanno in una barra loro sotto le modalità.
    private var filterRow: some View {
        // Una sintesi che nasconde meta' dei tipi non sintetizza: se la riga ci
        // sta, si mostra **intera** e la capsula abbraccia il contenuto; lo
        // scorrimento resta solo come rete per gli schermi stretti. E' il
        // lavoro di `ViewThatFits` — niente `fixedSize`, che qui e' gia'
        // costato una volta i chip fuori dal proprio sfondo.
        // Capsule **separate**, non una pillola unica: la capsula segmentata e'
        // da controllo a poche scelte fisse (la pillola delle modalita'); una
        // fila di filtri scorrevoli in iOS e' fatta di capsule singole — le
        // categorie di Mappe, i chip dell'App Store.
        ViewThatFits(in: .horizontal) {
            summaryRowContent
            ScrollView(.horizontal, showsIndicators: false) { summaryRowContent }
        }
        .transition(.opacity)
    }

    private var summaryRowContent: some View {
        HStack(spacing: 13) {
            summaryItem(label: String(localized: "filter.all", defaultValue: "All"),
                        icon: "leaf.fill",
                        tint: sensorFilter == nil ? .white : .primary, value: nil,
                        isSelected: sensorFilter == nil) { sensorFilter = nil }
            ForEach(envVM.availableSensorTypes) { type in
                summaryItem(label: type.displayName,
                            icon: type.sfSymbol,
                            tint: urgencyColour(worstUrgency(for: type)),
                            value: summaryText(for: type),
                            isSelected: sensorFilter == type) { sensorFilter = type }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
            // `settingsRevision` si legge apposta: e' cio' che fa rileggere il
            // modello dopo un salvataggio.
            _ = settingsRevision
            let settings = current.lampSettings(marker.uuid)
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  let lamp = FloorplanLampReader.lamp(for: accessory, homeKit: homeKit,
                                                      treatAsLight: settings.isDeclaredLight)
            else { return nil }

            let direction = settings.direction ?? .down
            return FloorplanLamp(accessoryUUID: marker.uuid,
                                 name: accessory.name,
                                 isOn: lamp.isOn,
                                 height: settings.height
                                     ?? direction.defaultHeight(ceiling: ceilingHeight),
                                 direction: direction,
                                 position: transform.metres(from: settings.position ?? marker.position),
                                 brightness: lamp.brightness,
                                 colour: lamp.colour,
                                 renderStyle: settings.renderStyle)
        }
    }

    /// Lampade da passare alla scena. Nel Placement il toggle "Light effects" è
    /// una preview locale: mostra fascio e pozza anche se HomeKit riporta la
    /// luce spenta, così altezza e direzione si capiscono mentre le regoli.
    private var previewLamps: [FloorplanLamp] {
        let lamps = litLights
        guard roomPanelState == .setup,
              showsPlacementLampEffects
        else { return lamps }

        let previewIDs = Set(setupItemsInSelectedRoom.compactMap { item in
            item.direction == nil ? nil : item.id
        })
        guard !previewIDs.isEmpty else { return lamps }

        return lamps.map { lamp in
            guard previewIDs.contains(lamp.accessoryUUID) else { return lamp }
            var preview = lamp
            preview.isOn = true
            preview.brightness = max(preview.brightness, 0.75)
            return preview
        }
    }

    /// Un accessorio configurabile, qualunque famiglia sia.
    ///
    /// Il pannello raccoglie i **fatti che la pianta non può contenere**, e a
    /// che quota sta una cosa è la stessa domanda per un faretto e per uno
    /// split. Il verso invece no: uno split non punta da nessuna parte, e
    /// `direction` a `nil` è ciò che lo dice — non un default finto.
    private struct SetupItem: Identifiable {
        var id: UUID
        var name: String
        var height: Double
        var direction: LampDirection?
        var renderStyle: LampRenderStyle?
        var range: ClosedRange<Double>
        var symbol: String
    }

    private var setupItemsInSelectedRoom: [SetupItem] {
        guard let selectedRoomID,
              let area = document.roomAreas.first(where: { $0.id == selectedRoomID })
        else { return [] }

        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        let polygon = area.effectivePoints.map {
            SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
        }

        let lamps = litLights
            .filter { FloorplanRoomEnvironment.contains($0.position, polygon) }
            .map { SetupItem(id: $0.accessoryUUID, name: $0.name, height: $0.height,
                             direction: $0.direction, renderStyle: $0.renderStyle,
                             range: 0.2...3.2,
                             symbol: "lightbulb.fill") }

        // ⚠️ Il clima si confronta sulla posa **originale**, non su quella
        // appoggiata al muro: quella e' gia' stata spostata, e potrebbe essere
        // finita appena oltre il poligono della stanza.
        let climate = climateUnits.compactMap { unit -> SetupItem? in
            guard let marker = markers.first(where: { $0.uuid == unit.accessoryUUID }),
                  let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                    exportRotation: exportRotation),
                  FloorplanRoomEnvironment.contains(transform.metres(from: marker.position), polygon)
            else { return nil }
            let symbol = switch unit.form {
            case .split:         "wind"
            case .radiator:      "heater.vertical"
            case .securityPanel: "shield.lefthalf.filled"
            case .television:    "tv"
            }
            return SetupItem(id: unit.accessoryUUID, name: unit.name, height: unit.height,
                             direction: nil, renderStyle: nil, range: 0.1...2.6, symbol: symbol)
        }

        return lamps + climate
    }

    /// Il vestito comune dei pannelli che **si usano**: vetro scuro vero al
    /// posto del nero piatto, un bordo che raccoglie e un'ombra che stacca
    /// dalla scena. Il modello resta visibile sotto — e' il motivo per cui non
    /// sono sheet: si regola guardando la casa reagire.
    private struct PanelChrome: ViewModifier {
        func body(content: Content) -> some View {
            // Vetro di casa: `glassChromeSurface` — Liquid Glass col toggle
            // attivo, e il ramo legacy porta bordo e ombra di oggi. Sul vetro
            // niente bordo/ombra a mano: il vetro ha i suoi.
            //
            // E sotto il vetro, lo scudo: l'ARView è una UIView a tutto
            // schermo e i suoi recognizer UIKit ricevono anche i tocchi dati
            // ai pannelli SwiftUI (stesso tap-through dell'editor 2D) — un
            // tocco sul pannello deselezionava la stanza e il pannello si
            // chiudeva da solo sotto le dita.
            content
                .shieldsCanvasTouches()
                .glassChromeSurface(
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous),
                    legacyBorder: Color.primary.opacity(0.12),
                    legacyShadow: GlassChromeShadow(color: .black.opacity(0.22),
                                                    radius: 22, y: 10))
        }
    }

    /// Il menu della stanza: tre azioni, una riga.
    ///
    /// Un tocco sulla stanza non decide piu' da solo cosa vuoi farci: apre il
    /// bivio — configurare, entrarci, o vederne la scheda. Il pannello di
    /// configurazione arriva solo se scelto.
    @ViewBuilder
    private var roomActionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(selectedRoomName ?? "")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Divider().frame(height: 30).overlay(Color.primary.opacity(0.25))

                if !setupItemsInSelectedRoom.isEmpty || !switchablesInSelectedRoom.isEmpty {
                    roomAction(String(localized: "room.action.setup", defaultValue: "Set up"),
                               icon: "slider.horizontal.3") {
                        presentRoomSetupPanel()
                    }
                }

                roomAction(String(localized: "room.action.enter", defaultValue: "Enter"),
                           icon: "person.fill.viewfinder") {
                    guard let roomID = selectedRoomID else { return }
                    cameraCommand = CameraCommand(id: UUID(), preset: .inside(roomID: roomID))
                    selectedRoomID = nil
                    selectedRoomName = nil
                    withAnimation(.easeOut(duration: 0.22)) { isInsideRoom = true }
                    // Il gesto per guardarsi intorno non si indovina: lo si
                    // dice, una volta, e la scritta se ne va da sola.
                    withAnimation(.easeOut(duration: 0.15)) {
                        lampCaption = String(localized: "room.enter.hint",
                                             defaultValue: "Drag to look around")
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(2.8))
                        withAnimation(.easeOut(duration: 0.3)) { lampCaption = nil }
                    }
                }

                roomAction(String(localized: "room.action.details", defaultValue: "Details"),
                           icon: "info.circle") {
                    guard let roomID = selectedRoomID else { return }
                    handleHold(.room(roomID: roomID))
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .modifier(PanelChrome())
        }
        .padding(.bottom, 104)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func roomAction(_ title: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption)
            }
            .foregroundStyle(Color.primary)
            .frame(minWidth: 68, minHeight: 56)
            .background(Color.primary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Il posto dove si impostano i fatti che la pianta **non può contenere**:
    /// a che altezza sta una luce e dove punta.
    ///
    /// Per stanza e non per singola lampada perché la configurazione è
    /// un'attività a lotti — «i quattro faretti della cucina, tutti a
    /// soffitto» — e cercarli uno a uno nel modello sarebbe una penitenza.
    ///
    /// Ma il lotto si **sfoglia**, non si impila: una stanza con otto faretti
    /// faceva un pannello alto quanto lo schermo, con il nome della stanza
    /// spinto fuori dal bordo di sopra. Una configurazione alla volta tiene
    /// l'altezza fissa qualunque sia il numero di accessori.
    /// Lo sheet compatto esiste solo quando c'è qualcosa da configurare e la
    /// modalità è quella giusta; chiuderlo (drag o Fatto) torna al menu stanza.
    private var compactSetupSheetBinding: Binding<Bool> {
        Binding(
            get: {
                isCompact && roomPanelState == .setup && selectedRoomID != nil
                    && (selectedItem(among: setupItemsInSelectedRoom) != nil
                        || !switchablesInSelectedRoom.isEmpty)
            },
            set: { if !$0 { dismissRoomSetupPanel() } }
        )
    }

    @ViewBuilder
    private var roomSetupPanel: some View {
        let items = setupItemsInSelectedRoom
        // Il pannello vive anche **senza** accessori configurabili: una stanza
        // con soli interruttori deve poter arrivare alla spunta «e' una luce»,
        // o quegli interruttori resterebbero irraggiungibili per sempre.
        if selectedItem(among: items) != nil || !switchablesInSelectedRoom.isEmpty {
            GeometryReader { proxy in
                let inset: CGFloat = 24
                let width = max(680, proxy.size.width - inset * 2)
                let listWidth = min(max(width * 0.30, 320), 460)
                HStack {
                    Spacer(minLength: 0)
                    iPadPlacementInspector(items: items, listWidth: listWidth)
                        .frame(width: width, height: 420)
                        .modifier(PanelChrome())
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 430)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func iPadPlacementInspector(items: [SetupItem], listWidth: CGFloat) -> some View {
        let switchables = switchablesInSelectedRoom
        let showsSwitches = (showsPlacementSwitches && !switchables.isEmpty)
            || (items.isEmpty && !switchables.isEmpty)
        let selected = showsSwitches ? nil : selectedItem(among: items)

        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedRoomName ?? "")
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(items.count == 1
                             ? String(localized: "setup.count.one", defaultValue: "1 device")
                             : String(localized: "setup.count.other", defaultValue: "\(items.count) devices"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.primary)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items) { item in
                            iPadPlacementAccessoryRow(item, isSelected: item.id == selected?.id)
                        }

                        if !switchables.isEmpty {
                            iPadPlacementSwitchesRow(
                                count: switchables.count,
                                isSelected: showsSwitches
                            )
                        }
                    }
                    .padding(.trailing, 2)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.leading, 20)
            .padding(.vertical, 18)
            .frame(width: listWidth, alignment: .topLeading)

            Divider()
                .overlay(Color.primary.opacity(0.18))
                .padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showsSwitches {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(String(localized: "placement.switches.title",
                                            defaultValue: "Switches"))
                                    .font(.title3.weight(.semibold))
                                Text(switchables.count == 1
                                     ? String(localized: "setup.count.one", defaultValue: "1 device")
                                     : String(localized: "setup.count.other", defaultValue: "\(switchables.count) devices"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "lightswitch.on")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(.primary)

                        ForEach(switchables, id: \.uuid) { candidate in
                            Toggle(isOn: declaredLightBinding(for: candidate.uuid)) {
                                Label {
                                    Text(candidate.name).font(.subheadline)
                                } icon: {
                                    Image(systemName: "lightswitch.on").font(.system(size: 13))
                                }
                                .foregroundStyle(Color.primary.opacity(0.9))
                            }
                            .tint(.yellow.opacity(0.7))
                        }
                    } else if let selected {
                        Label(selected.name, systemImage: selected.symbol)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        setupRow(selected)
                    }

                    if selected?.direction != nil {
                        Divider().overlay(Color.primary.opacity(0.18))
                        Toggle(isOn: $showsPlacementLampEffects) {
                            Label {
                                Text(String(localized: "placement.lightEffects",
                                            defaultValue: "Light effects"))
                                    .font(.caption)
                            } icon: {
                                Image(systemName: "lightbulb.max")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.primary.opacity(0.9))
                        }
                        .tint(.yellow.opacity(0.75))
                    }

                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func iPadPlacementAccessoryRow(_ item: SetupItem, isSelected: Bool) -> some View {
        Button {
            showsPlacementSwitches = false
            selectedLampUUID = item.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
                    .background(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(item.direction == nil
                         ? String(localized: "placement.device.generic", defaultValue: "Device")
                         : ((item.renderStyle ?? .spotlight).label))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(isSelected ? 0.15 : 0.055),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func iPadPlacementSwitchesRow(count: Int, isSelected: Bool) -> some View {
        Button {
            showsPlacementSwitches = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "lightswitch.on")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.82))
                    .background(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "placement.switches.title",
                                defaultValue: "Switches"))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(count == 1
                         ? String(localized: "setup.count.one", defaultValue: "1 device")
                         : String(localized: "setup.count.other", defaultValue: "\(count) devices"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(isSelected ? 0.15 : 0.055),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Il contenuto del Placement, condiviso fra pannello iPad e sheet iPhone.
    private var setupPanelContent: some View {
        let items = setupItemsInSelectedRoom
        return VStack(alignment: .leading, spacing: 12) {
                // Il recap della selezione: senza, il pannello compare e non si
                // sa a cosa si riferisce.
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 15))
                    Text(selectedRoomName ?? "")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(items.count == 1
                         ? String(localized: "setup.count.one", defaultValue: "1 device")
                         : String(localized: "setup.count.other", defaultValue: "\(items.count) devices"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
                .foregroundStyle(.primary)

                // Con un accessorio solo la fila sarebbe una pastiglia da
                // scegliere fra una: resta il nome, che serve comunque a sapere
                // cosa si sta configurando.
                if let item = selectedItem(among: items) {
                    if items.count > 1 {
                        setupPicker(items, selected: item)
                    } else {
                        Label(item.name, systemImage: item.symbol)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                    }

                    Divider().overlay(Color.primary.opacity(0.2))
                    setupRow(item)
                }

                if selectedItem(among: items)?.direction != nil {
                    Divider().overlay(Color.primary.opacity(0.2))
                    Toggle(isOn: $showsPlacementLampEffects) {
                        Label {
                            Text(String(localized: "placement.lightEffects",
                                        defaultValue: "Light effects"))
                                .font(.caption)
                        } icon: {
                            Image(systemName: "lightbulb.max")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.primary.opacity(0.9))
                    }
                    .tint(.yellow.opacity(0.75))
                }

                // Gli On/Off della stanza: molti comandano luci, ma HomeKit non
                // sa cosa c'e' attaccato a un rele'. La spunta e' la
                // dichiarazione dell'utente; appena attiva, l'interruttore
                // diventa una lampada a tutti gli effetti — corpo, fascio,
                // quota e direzione da configurare qui sopra.
                let switchables = switchablesInSelectedRoom
                if !switchables.isEmpty {
                    Divider().overlay(Color.primary.opacity(0.2))
                    ForEach(switchables, id: \.uuid) { candidate in
                        Toggle(isOn: declaredLightBinding(for: candidate.uuid)) {
                            Label {
                                Text(candidate.name).font(.caption)
                            } icon: {
                                Image(systemName: "lightswitch.on").font(.system(size: 12))
                            }
                            .foregroundStyle(Color.primary.opacity(0.9))
                        }
                        .tint(.yellow.opacity(0.7))
                    }
                }
            }
    }

    /// Gli interruttori e le prese della stanza: i candidati alla spunta.
    private var switchablesInSelectedRoom: [(uuid: UUID, name: String)] {
        guard let selectedRoomID,
              let area = document.roomAreas.first(where: { $0.id == selectedRoomID }),
              let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation)
        else { return [] }
        let metresPerPoint = 1.0 / Double(DrawingDocument.ptsPerMeter)
        let polygon = area.effectivePoints.map {
            SIMD2(Double($0.x) * metresPerPoint, Double($0.y) * metresPerPoint)
        }
        return markers.compactMap { marker in
            guard let accessory = homeKit.accessory(for: marker.uuid),
                  FloorplanLampReader.isSwitchable(accessory),
                  FloorplanRoomEnvironment.contains(
                      transform.metres(from: current.lampSettings(marker.uuid).position
                                       ?? marker.position),
                      polygon)
            else { return nil }
            return (marker.uuid, accessory.name)
        }
    }

    private func declaredLightBinding(for uuid: UUID) -> Binding<Bool> {
        Binding(
            get: { current.lampSettings(uuid).isDeclaredLight },
            set: { flag in
                current.applyDeclaredLight(uuid, flag)
                settingsRevision &+= 1
            }
        )
    }

    /// Quello scelto, o il primo se la scelta è di un'altra stanza.
    private func selectedItem(among items: [SetupItem]) -> SetupItem? {
        guard !items.isEmpty else { return nil }
        if let selectedLampUUID, let match = items.first(where: { $0.id == selectedLampUUID }) {
            return match
        }
        return items.first
    }

    /// La fila degli accessori della stanza.
    ///
    /// I margini negativi non sono un trucco: annullano il bordo del pannello
    /// **solo per lo scorrimento**, e il rientro torna dentro l'`HStack`. Così
    /// le pastiglie passano sotto gli angoli arrotondati invece di fermarsi a
    /// mezzo centimetro dal bordo, che è il segnale che dice «di qua ce n'è
    /// ancora».
    @ViewBuilder
    private func setupPicker(_ items: [SetupItem], selected: SetupItem) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let isSelected = item.id == selected.id
                    Button {
                        selectedLampUUID = item.id
                    } label: {
                        // L'icona distingue le famiglie senza una riga di
                        // intestazione per ciascuna: in una stanza con quattro
                        // faretti e uno split, «quale e' lo split» si vede.
                        Label(item.name, systemImage: item.symbol)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(.primary.opacity(isSelected ? 1 : 0.62))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(isSelected ? 0.16 : 0.06), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -16)
    }

    /// Ogni comando dice **cosa fa**, non solo che c'è.
    ///
    /// Tre icone senza didascalia sono un indovinello: una freccia in giù può
    /// voler dire «abbassa», «sposta sotto» o «punta in basso». La parola
    /// accanto alla scelta attiva toglie l'ambiguità senza occupare una riga in
    /// più per ciascuna.
    @ViewBuilder
    private func setupRow(_ item: SetupItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // La riga della direzionalità esiste solo per chi punta da qualche
            // parte. Mostrarla disattivata su uno split direbbe «qui si potrebbe
            // scegliere», che è falso.
            if let direction = item.direction {
                HStack(spacing: 8) {
                    Text(String(localized: "lamp.direction.title", defaultValue: "Points"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    // Su iPhone la fila intera sfora i ~350 pt utili e si
                    // tagliava: scorre. Su iPad ci sta e non scrolla mai.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(LampDirection.allCases) { value in
                                Button {
                                    applyLampSettings(item.id, item.height, value, item.renderStyle)
                                } label: {
                                    directionGlyph(value, isSelected: direction == value)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 3)
                                        .background(direction == value ? Color.primary.opacity(0.14) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text(value.label))
                            }
                        }
                    }

                    Text(direction.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.primary.opacity(0.9))
                }

                HStack(spacing: 8) {
                    Text(String(localized: "lamp.renderStyle.title", defaultValue: "Look"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .leading)

                    HStack(spacing: 4) {
                        ForEach(LampRenderStyle.allCases) { style in
                            let isSelected = (item.renderStyle ?? .spotlight) == style
                            Button {
                                applyLampSettings(item.id, item.height, direction, style)
                            } label: {
                                Label(style.label, systemImage: style.systemImage)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.06),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text(String(localized: "lamp.height.title", defaultValue: "Height"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                Slider(value: heightBinding(for: item), in: item.range, step: 0.05)
                    .tint(.primary.opacity(0.7))

                Text(item.height.formatted(.number.precision(.fractionLength(2))) + " m")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .frame(width: 62, alignment: .trailing)
            }

            // Il ritocco fine della posa: dieci centimetri a tocco, sugli assi
            // della pianta. La posa vera resta mestiere del 2D; qui si corregge
            // guardando il corpo spostarsi.
            HStack(spacing: 8) {
                Text(String(localized: "lamp.position.title", defaultValue: "Position"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)

                ForEach([("chevron.left", -0.1, 0.0), ("chevron.right", 0.1, 0.0),
                         ("chevron.up", 0.0, -0.1), ("chevron.down", 0.0, 0.1)],
                        id: \.0) { symbol, dx, dy in
                    Button {
                        nudgeMarker(item.id, dx: dx, dy: dy)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.primary.opacity(0.9))
                            .frame(width: 40, height: 34)
                            .background(Color.primary.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Dieci centimetri nella direzione chiesta: metri, somma, e ritorno in
    /// normalizzato con l'inversa esatta dell'inquadratura d'export.
    private func nudgeMarker(_ uuid: UUID, dx: Double, dy: Double) {
        guard let transform = FloorplanOpeningMatcher.transform(document: document,
                                                                exportRotation: exportRotation),
              let marker = markers.first(where: { $0.uuid == uuid })
        else { return }
        let position = current.lampSettings(uuid).position ?? marker.position
        let moved = transform.metres(from: position) + SIMD2(dx, dy)
        current.applyMarkerPosition(uuid, transform.normalized(from: moved))
        settingsRevision &+= 1
    }

    /// Il pallino con il suo fascio, disegnato.
    ///
    /// Una freccia dice «in giù», non dice **cosa ottieni**. Qui si vede la
    /// lampada e la luce che getta, che è esattamente ciò che comparirà nel
    /// modello: l'anteprima e il comando diventano la stessa cosa.
    private func directionGlyph(_ direction: LampDirection, isSelected: Bool) -> some View {
        Canvas { context, size in
            let bulb = Color.primary.opacity(isSelected ? 0.95 : 0.45)
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

    private func heightBinding(for item: SetupItem) -> Binding<Double> {
        Binding(
            get: { item.height },
            set: { applyLampSettings(item.id, $0, item.direction, item.renderStyle) }
        )
    }

    /// Accende o spegne toccando il bulbo.
    ///
    /// Passa da `performQuickToggle` dell'adapter, lo stesso che usano i marker
    /// della 2D: una sola strada per comandare, e le protezioni e i log stanno
    /// già lì.
    private func toggleAccessory(_ accessoryUUID: UUID) {
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
            HStack(spacing: 8) {
                Image(systemName: triggered ? "exclamationmark.shield.fill" : mode.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                Text(triggered
                     ? String(localized: "security.state.triggered", defaultValue: "Triggered")
                     : mode.displayName)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .glassChromeSurface(in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1.5))
            .transition(.opacity)
        } else {
            // Nessuna centralina: dirlo è meglio che lasciare uno spazio vuoto
            // che sembra un guasto.
            Text(String(localized: "security.noSystem", defaultValue: "No alarm system"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .glassChromeSurface(in: Capsule())
                .transition(.opacity)
        }
    }

    /// Una voce della sintesi: icona colorata + intervallo, niente pillola.
    ///
    /// Il colore dell'icona e' **lo stato peggiore** di quel tipo in casa, e il
    /// testo e' l'intervallo min–max: «23–35°» dice subito che una stanza sta
    /// cocendo, mentre una media lo nasconderebbe. E' la stessa voce che filtra
    /// le bandierine: sintesi e filtro sono un oggetto solo, non due righe.
    @ViewBuilder
    private func summaryItem(label: String, icon: String, tint: Color, value: String?,
                             isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(value ?? label)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            // La selezione e' la capsula piena col colore dello strato — lo
            // stesso verde che Ambiente ha nella pillola delle modalita': una
            // sola lingua per dire «attivo».
            .glassChromeSurface(
                in: Capsule(),
                tint: isSelected ? PreviewMode.environment.accent : nil,
                legacyFill: isSelected
                    ? AnyShapeStyle(PreviewMode.environment.accent ?? Color.primary.opacity(0.2))
                    : AnyShapeStyle(.regularMaterial))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value ?? ""))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// L'intervallo di un tipo su tutta la casa.
    ///
    /// Min–max e non media: la media fra il bagno e il soggiorno non significa
    /// niente. Per i tipi a scala (qualita' aria, fumo) si mostra **il
    /// peggiore**, perche' un intervallo di etichette non si legge.
    private func summaryText(for type: SensorServiceType) -> String? {
        let sensors = envVM.rooms.flatMap(\.sensors).filter { $0.serviceType == type }
        guard let lowest = sensors.min(by: { $0.currentValue < $1.currentValue }),
              let highest = sensors.max(by: { $0.currentValue < $1.currentValue })
        else { return nil }
        if type == .airQuality || type == .smoke { return highest.formattedValue }
        if lowest.formattedValue == highest.formattedValue { return highest.formattedValue }
        return "\(lowest.formattedValue)–\(highest.formattedValue)"
    }

    private func presentARDiagnostics() {
        loadEnvironmentIfNeeded()
        arDiagnosticsSnapshot = makeARDiagnosticsSnapshot()
    }

    private func makeARDiagnosticsSnapshot() -> ARDiagnosticsSnapshot {
        let roomName = selectedRoomName
        let planRooms = document.roomAreas.map { area in
            ARDiagnosticsPlanRoom(id: area.id,
                                  name: area.name,
                                  points: area.effectivePoints,
                                  anchor: area.centroid)
        }
        let planWalls = document.walls
            .filter { $0.kind.rendersAsPhysicalWall }
            .map { wall in
                ARDiagnosticsPlanWall(id: wall.id,
                start: wall.start,
                end: wall.end)
            }
        let commissioningMarkers = makeARCommissioningMarkers(planRooms: planRooms)
        let rooms = FloorplanRoomEnvironment.anchors(in: document)
            .map { anchor in
                let data = envVM.rooms.first { $0.roomName == anchor.roomName }
                return ARDiagnosticsRoom(
                    id: anchor.roomID,
                    name: anchor.roomName,
                    subtitle: String(localized: "ar.diagnostics.room.explicit.subtitle",
                                     defaultValue: "Room diagnostics from explicit AR calibration."),
                    metrics: data.map(arMetrics) ?? []
                )
            }
        let roomData = roomName.flatMap { name in
            envVM.rooms.first { $0.roomName == name }
        }

        if let roomName, let roomData {
            return ARDiagnosticsSnapshot(
                title: roomName,
                subtitle: String(localized: "ar.diagnostics.room.subtitle",
                                 defaultValue: "Live room diagnostics over the camera feed."),
                metrics: arMetrics(for: roomData),
                rooms: rooms,
                suggestedRoomID: selectedRoomID,
                planRooms: planRooms,
                planWalls: planWalls,
                pointsPerMeter: DrawingDocument.ptsPerMeter,
                northBearingDegrees: northBearingDegrees,
                savedCalibration: document.arCalibration,
                applyARCalibration: current.applyARCalibration,
                applyNorthBearing: { bearing in
                    current.applyNorthBearing(bearing)
                    exposure = Exposure.nearest(to: bearing)
                },
                commissioningMarkers: commissioningMarkers,
                performCommissioningAction: { toggleAccessory($0) }
            )
        }

        let lightsOn = litLights.filter(\.isOn).count
        let metrics = [
            ARDiagnosticsMetric(title: String(localized: "environment.rooms",
                                              defaultValue: "Rooms"),
                                value: "\(document.roomAreas.count)",
                                systemImage: "rectangle.3.group",
                                tint: .green),
            ARDiagnosticsMetric(title: "Marker",
                                value: "\(markers.count)",
                                systemImage: "sensor.tag.radiowaves.forward",
                                tint: .blue),
            ARDiagnosticsMetric(title: String(localized: "ar.diagnostics.lightsOn",
                                              defaultValue: "Lights on"),
                                value: "\(lightsOn)",
                                systemImage: "lightbulb.fill",
                                tint: lightsOn > 0 ? .yellow : .secondary),
            ARDiagnosticsMetric(title: String(localized: "ar.diagnostics.sensors",
                                              defaultValue: "Sensors"),
                                value: "\(envVM.rooms.flatMap(\.sensors).count)",
                                systemImage: "waveform.path.ecg",
                                tint: .orange)
        ]

        return ARDiagnosticsSnapshot(
            title: title,
            subtitle: String(localized: "ar.diagnostics.floor.subtitle",
                             defaultValue: "Point your iPhone or iPad around the room and keep the floorplan summary in view."),
            metrics: metrics,
            rooms: rooms,
            suggestedRoomID: selectedRoomID,
            planRooms: planRooms,
            planWalls: planWalls,
            pointsPerMeter: DrawingDocument.ptsPerMeter,
            northBearingDegrees: northBearingDegrees,
            savedCalibration: document.arCalibration,
            applyARCalibration: current.applyARCalibration,
            applyNorthBearing: { bearing in
                current.applyNorthBearing(bearing)
                exposure = Exposure.nearest(to: bearing)
            },
            commissioningMarkers: commissioningMarkers,
            performCommissioningAction: { toggleAccessory($0) }
        )
    }

    private func makeARCommissioningMarkers(planRooms: [ARDiagnosticsPlanRoom]) -> [ARDiagnosticsCommissioningMarker] {
        let transform = FloorplanOpeningMatcher.transform(document: document,
                                                          exportRotation: exportRotation)
        return markers.map { marker in
            let normalizedPoint = current.lampSettings(marker.uuid).position ?? marker.position
            let point = arCommissioningDrawingPoint(from: normalizedPoint, using: transform)
            let room = planRooms.first { $0.contains(point) }

            guard let accessory = homeKit.accessory(for: marker.uuid) else {
                return ARDiagnosticsCommissioningMarker(
                    accessoryUUID: marker.uuid,
                    name: String(localized: "ar.commissioning.unknownAccessory",
                                 defaultValue: "Unlinked accessory"),
                    category: "missing",
                    systemImage: "questionmark.circle",
                    point: point,
                    roomID: room?.id,
                    roomName: room?.name,
                    isReachable: false,
                    supportsQuickToggle: false,
                    statusText: nil
                )
            }

            let category = AccessoryCategorizer.categorize(accessory)
            let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
            return ARDiagnosticsCommissioningMarker(
                accessoryUUID: marker.uuid,
                name: accessory.name,
                category: category,
                systemImage: commissioningSystemImage(for: category),
                point: point,
                roomID: room?.id,
                roomName: room?.name,
                isReachable: homeKit.isReachable(accessory),
                supportsQuickToggle: adapter.supportsQuickToggle,
                statusText: adapter.primaryStatusText
            )
        }
    }

    private func arCommissioningDrawingPoint(from normalizedPoint: CGPoint,
                                             using transform: FloorplanOpeningMatcher.Transform?) -> CGPoint {
        guard let transform else { return normalizedPoint }
        let metres = transform.metres(from: normalizedPoint)
        return CGPoint(
            x: metres.x * Double(DrawingDocument.ptsPerMeter),
            y: metres.y * Double(DrawingDocument.ptsPerMeter)
        )
    }

    private func commissioningSystemImage(for category: String) -> String {
        switch category {
        case "colorLight", "dimmableLight":
            return "lightbulb.fill"
        case "switch":
            return "switch.2"
        case "outlet":
            return "powerplug.fill"
        case "camera":
            return "video.fill"
        case "television":
            return "tv.fill"
        case "airPurifier":
            return "wind"
        case "humidifier":
            return "humidity.fill"
        case "thermostat", "airConditioner":
            return "thermometer"
        case "fan":
            return "fan.fill"
        case "windowCovering":
            return "blinds.horizontal.closed"
        case "doorLock":
            return "lock.fill"
        case "garageDoor":
            return "door.garage.closed"
        case "valve":
            return "drop.fill"
        case "sceneController":
            return "button.programmable"
        case "sensor":
            return "sensor"
        default:
            return "sensor.tag.radiowaves.forward"
        }
    }

    private func arMetrics(for roomData: RoomEnvironmentData) -> [ARDiagnosticsMetric] {
        let sortedSensors = roomData.sensors.sorted { lhs, rhs in
            lhs.urgency.rawValue > rhs.urgency.rawValue
        }
        let sensorMetrics = sortedSensors.prefix(3).map { sensor in
            ARDiagnosticsMetric(title: sensor.serviceType.displayName,
                                value: sensor.formattedValue,
                                systemImage: sensor.serviceType.sfSymbol,
                                tint: urgencyColour(sensor.urgency))
        }
        return [
            ARDiagnosticsMetric(title: String(localized: "environment.quality",
                                              defaultValue: "Quality"),
                                value: "\(Int(roomData.qualityScore * 100))%",
                                systemImage: "leaf.fill",
                                tint: roomData.qualityColor)
        ] + sensorMetrics
    }

    private func worstUrgency(in data: RoomEnvironmentData) -> SensorUrgency {
        let urgencies = data.sensors.map(\.urgency)
        if urgencies.contains(.danger) { return .danger }
        if urgencies.contains(.warning) { return .warning }
        return .normal
    }

    private func worstUrgency(for type: SensorServiceType) -> SensorUrgency {
        let urgencies = envVM.rooms.flatMap(\.sensors)
            .filter { $0.serviceType == type }
            .map(\.urgency)
        if urgencies.contains(.danger) { return .danger }
        if urgencies.contains(.warning) { return .warning }
        return .normal
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
                                                     openOpeningIDs: openOpeningIDs,
                                                     closedShutters: closedShutters,
                                                     televisionSpots: televisions.map(\.position))
    }
}

// MARK: - PresenceIssuePanelView

/// La segnalazione da pannello a muro: ancorata in basso, larga, bassa. Le
/// pagine sono TUTTE le segnalazioni attive (stanza × sensore) — il titolo
/// cambia stanza mentre scorri, il contatore dice subito quante sono, e la
/// casa dietro si ritinge a ogni pagina. La scheda stanza completa sta
/// dietro il bottone: prima il problema, poi il catalogo.
private struct PresenceIssuePanelView: View {
    let items: [FloorplanRealityPreviewView.PresenceIssueItem]
    let urgencyColour: (SensorUrgency) -> Color
    let onPageChange: (FloorplanRealityPreviewView.PresenceIssueItem) -> Void
    let onDismiss: () -> Void
    let onOpenRoom: (String) -> Void

    @State private var page = 0

    private var current: FloorplanRealityPreviewView.PresenceIssueItem {
        items.indices.contains(page) ? items[page] : items[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(urgencyColour(current.sensor.urgency).opacity(0.18))
                        .frame(width: 48, height: 48)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(urgencyColour(current.sensor.urgency))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(current.roomName)
                        .font(.title.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .contentTransition(.opacity)
                    Text(items.count == 1
                         ? String(localized: "presence.issue.subtitle.one",
                                  defaultValue: "1 sensor out of range")
                         : String(localized: "presence.issue.counter",
                                  defaultValue: "Report \(page + 1) of \(items.count)"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(urgencyColour(current.sensor.urgency))
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .animation(.easeOut(duration: 0.2), value: page)

            // Una pagina per segnalazione: valore gigante, spazio pronto per
            // il testo delle anomalie Intelligence. Lo swipe ritinge la casa.
            TabView(selection: $page) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    // La pagina È il bottone: tocchi l'anomalia, si apre la
                    // stanza. Il bottone a parte nel header su iPhone si
                    // schiacciava male — e questo bersaglio è enorme.
                    Button {
                        onOpenRoom(item.roomName)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: item.sensor.serviceType.sfSymbol)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(urgencyColour(item.sensor.urgency))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.sensor.serviceType.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(item.sensor.formattedValue)
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(urgencyColour(item.sensor.urgency))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                            }
                            Spacer(minLength: 0)
                            VStack(alignment: .trailing, spacing: 6) {
                                Text(item.sensor.urgency == .danger
                                     ? String(localized: "presence.issue.critical", defaultValue: "Critical")
                                     : String(localized: "presence.issue.warning", defaultValue: "Warning"))
                                    .font(.caption.weight(.bold))
                                    .textCase(.uppercase)
                                    .foregroundStyle(urgencyColour(item.sensor.urgency))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(urgencyColour(item.sensor.urgency).opacity(0.10))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 2)
                    .tag(index)
                }
            }
            // Pallini nostri, non quelli di sistema: quelli finivano DENTRO
            // la cornice delle pagine (sovrapposti) ed erano grigio su
            // chiaro — invisibili. Qui stanno sotto, nel colore d'urgenza.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 82)
            .onChange(of: page) { _, newValue in
                guard items.indices.contains(newValue) else { return }
                onPageChange(items[newValue])
            }

            if items.count > 1 {
                HStack(spacing: 7) {
                    ForEach(items.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page
                                  ? urgencyColour(current.sensor.urgency)
                                  : Color.primary.opacity(0.18))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: page)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassChromeSurface(
            in: RoundedRectangle(cornerRadius: 28, style: .continuous),
            legacyBorder: Color.primary.opacity(0.12),
            legacyShadow: GlassChromeShadow(color: .black.opacity(0.22), radius: 22, y: 10)
        )
        // La banda d'urgenza: un DATO, sopra il vetro — segue la pagina.
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(urgencyColour(current.sensor.urgency).opacity(0.4), lineWidth: 1.5)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .shieldsCanvasTouches()
    }
}
