import SwiftUI
import SwiftData
import HomeKit

struct FloorplanEditorView: View {
    @Bindable var floorplan: Floorplan
    @Binding var columnVisibility: NavigationSplitViewVisibility
    var onSelectFloorplan: ((UUID) -> Void)? = nil
    
    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue
    @AppStorage("ai.isEnabled")
    private var isAIEnabled: Bool = false
    
    private var size: MarkerSize {
        MarkerSize(rawValue: markerSizeRaw) ?? .regular
    }
    
    /// Come è stato presentato l'editor. Cambia il bottone in alto a sinistra:
    /// - .splitView: bottone "sidebar" per riaprire la sidebar (quando è nascosta)
    /// - .pushed: bottone X per tornare alla vista precedente
    var presentationStyle: PresentationStyle = .splitView

    enum PresentationStyle {
        case splitView    // detail di NavigationSplitView (dalla sidebar)
        case pushed       // pushed su NavigationStack (dalla galleria)
    }

    /// When true, the editor enters edit mode automatically on first appear.
    var startInEditMode: Bool = false
    
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(SmartLightingEngine.self) private var smartLightingEngine
    @Environment(CloudKitSyncService.self) private var cloudKitSync
    
    /// Stato UI raggruppato: editing/selezione marker, picker, presentazioni.
    @State private var ui = FloorplanEditorUIState()

    /// La 3D aperta da qui: secondo ingresso alla stessa vista della lista,
    /// costruita dalla stessa factory — mai una copia del cablaggio.
    @State private var preview3D: Preview3DRequest?

    @AppStorage("floorplan.help.hasSeen.v1")
    private var hasSeenFloorplanHelp = false
    
    @State private var viewport = FloorplanViewportState()
    
    // Auto-hide controls
    @State private var controlsVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    
    @Environment(HomeKitScenesService.self) private var scenesService

    @Query(sort: \Floorplan.createdAt, order: .reverse) private var allFloorplans: [Floorplan]

    @AppStorage("primaryFloorplanID") private var primaryFloorplanID: String = ""
    @AppStorage("pinnedFloorplanIDs") private var pinnedFloorplanIDsRaw: String = "[]"

    /// Overlay layer view model — scoped to this editor instance, keyed to the floorplan UUID.
    @State private var overlayVM: FloorplanOverlayViewModel?
    /// Shared environment view model used by both the overlay layer and the context panel.
    @State private var overlayEnvVM = EnvironmentViewModel()

    @State private var imageCache = FloorplanImageCacheState()

    /// Cached overlay context — recomputed only when HomeKit accessories change.
    @State private var cachedOverlayContext: FloorplanOverlayContext = .none

    /// Timestamp (seconds since epoch) when the security mode was last observed to change.
    @AppStorage("securityModeActivationDate") private var securityModeActivationDate: Double = 0

    /// Last known security mode raw value — used to detect mode changes.
    @State private var lastKnownSecurityModeRaw: Int = -1

    /// Adapter del sistema di sicurezza corrente, ricalcolato solo quando gli
    /// accessori cambiano. Il `currentMode` resta live (letto dalla caratteristica
    /// HomeKit), quindi cachare il riferimento evita di riscansionare l'intera
    /// casa e ricostruire adapter ad ogni valutazione del `body`.
    @State private var cachedSecurityAdapter: SecuritySystemAdapter?

    /// Mappa accessorio → adapter condivisa dai marker, ricalcolata solo sugli
    /// stessi eventi discreti di `cachedSecurityAdapter` (appear, HomeKit pronto,
    /// cambio elenco accessori). Gli adapter sono @Observable e leggono lo stato
    /// live dalle caratteristiche, quindi cachare i riferimenti è sicuro; prima
    /// venivano ricostruiti per ogni marker a ogni valutazione del `body`.
    @State private var cachedAdapterMap: [UUID: any AccessoryAdapter] = [:]

    /// Cache memoizzante degli offset anti-collisione dei marker (O(n²) nel
    /// resolver). Classe tenuta in @State: la mutazione interna non re-invalida
    /// la view; il ricalcolo avviene solo quando cambiano gli input effettivi.
    @State private var collisionOffsetCache = FloorplanMarkerCollisionOffsetCache()

    /// Bitmap ruotata di 90° per la rotazione planimetria (v3-B), memoizzata
    /// sull'immagine corrente.
    @State private var rotatedImageCache = FloorplanRotatedImageCache()

    // MARK: Barra di stato unificata (redesign, novità A+B)

    /// Meteo per la temperatura esterna della barra di stato. @Observable:
    /// la pill si aggiorna da sola quando arriva un refresh.
    @Environment(WeatherKitService.self) private var weatherKit

    /// Stessa sorgente e semantica di SecurityOverlayView: solo i sensori
    /// contatto monitorati contano come "aperture".
    @AppStorage("securityMonitoredUUIDs") private var securityMonitoredUUIDsRaw: String = ""

    @AppStorage(TemperatureUnit.appStorageKey)
    private var temperatureUnitRaw: String = TemperatureUnit.celsius.rawValue

    /// Situazioni attive, stessa query dell'overlay Intelligenza: reattiva via
    /// SwiftData, il conteggio della barra si aggiorna quando un'azione risolve
    /// un insight.
    @Query(
        filter: #Predicate<PersistedHomeInsight> { $0.statusRaw == "active" },
        sort: \PersistedHomeInsight.updatedAt,
        order: .reverse
    )
    private var activeStripInsights: [PersistedHomeInsight]

    /// Salute casa (media pesata per stanza): costa una scansione con adapter
    /// per accessorio, quindi si ricalcola solo sugli stessi eventi discreti
    /// degli altri cache (appear, HomeKit pronto, accessori, reachability).
    @State private var cachedHealthScore: Int?

    private func marker(withID markerID: UUID) -> PlacedAccessory? {
        floorplan.accessories.first { $0.id == markerID }
    }

    private var duplicatedMarkerAccessoryIDs: Set<UUID> {
        let counts = Dictionary(grouping: floorplan.accessories, by: \.homeKitAccessoryUUID)
        return Set(counts.compactMap { accessoryID, markers in
            markers.count > 1 ? accessoryID : nil
        })
    }

    private var accessoryPickerTitle: String {
        guard let pickerRoomFilter = ui.pickerRoomFilter,
              let room = floorplan.linkedRooms.first(where: { $0.hmRoomUUID == pickerRoomFilter }) else {
            return String(localized: "floorplan.accessoryPicker.title", defaultValue: "Add accessories")
        }
        return String(localized: "floorplan.accessoryPicker.title.room", defaultValue: "Add in \(room.name)")
    }

    private var availableFloorplans: [Floorplan] {
        allFloorplans.filter { homeKit.matchesActiveHome($0.homeUUID) }
    }

    private var pinnedFloorplans: [Floorplan] {
        let ids = decodePinnedFloorplanIDs()
        let matched = ids.compactMap { idString -> Floorplan? in
            guard let id = UUID(uuidString: idString) else { return nil }
            return availableFloorplans.first { $0.id == id }
        }
        let primary = matched.first { $0.id.uuidString == primaryFloorplanID }
        let rest = matched.filter { $0.id.uuidString != primaryFloorplanID }
        return (primary.map { [$0] } ?? []) + rest
    }

    private func decodePinnedFloorplanIDs() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(pinnedFloorplanIDsRaw.utf8))) ?? []
    }

    private func refreshOverlayContext() {
        let context = runtimeContextController.overlayContext()
        cachedOverlayContext = context

        if let vm = overlayVM,
           !vm.activeMode.isAvailable(in: context) {
            vm.activeMode = .controls
        }
    }
    
    private var effectiveScale: CGFloat {
        viewportController.effectiveScale
    }
    
    private var effectiveOffset: CGSize {
        viewportController.effectiveOffset
    }
    
    private var shouldShowControls: Bool {
        chromeController.shouldShowControls(isEditing: ui.isEditing)
    }


    private var floorplanBackgroundColor: Color {
        let visualStyle = DrawingVisualExportStyle(rawValue: floorplan.drawingVisualExportStyleRaw) ?? .standard
        if visualStyle == .architecturalDark {
            return DrawingVisualExportStyle.architecturalDarkBackgroundColor
        }
        return ExteriorFillPalette(rawValue: floorplan.exteriorFillColorIndex).map { $0.swiftUIColor } ?? Color.white
    }

    /// Tema della chrome flottante, dedotto dalla **planimetria** e non da iOS.
    ///
    /// Le due cose sono indipendenti: una planimetria può essere bianca o scura
    /// con qualunque tema di sistema, e lo stile "architectural dark" la rende
    /// scura anche a iOS chiaro. Finora la chrome seguiva il sistema, quindi
    /// capitava regolarmente di avere una lastra chiara sopra un disegno scuro,
    /// o vetro scuro sopra un foglio bianco — nel secondo caso il vetro degrada
    /// a macchia grigia opaca, che è il modo più diretto per far sembrare
    /// l'effetto un materiale qualunque.
    ///
    /// Il colore di fondo del canvas è il riferimento giusto perché è ciò su cui
    /// la chrome galleggia davvero: è il fondo del disegno e la cornice attorno
    /// a un'immagine importata.
    private var chromeColorScheme: ColorScheme {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(floorplanBackgroundColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // Luminanza relativa: il verde pesa quasi tre volte il rosso e dieci
        // volte il blu nella percezione, quindi una media semplice sbaglierebbe
        // proprio sui fondi colorati della palette esterni.
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance < 0.5 ? .dark : .light
    }

    /// Pannello docked (novità E): su larghezza regular il pannello contestuale
    /// sta AFFIANCATO alla mappa, non sopra — la colonna mappa si restringe e
    /// nessuna stanza viene coperta. Su compact resta l'overlay di sempre
    /// (diventerà bottom sheet in fase 4).
    private var isDockedPanelVisible: Bool {
        !isCompactScreen && !ui.isEditing && (overlayVM?.isPanelVisible ?? false)
    }

    /// Contenuto canvas: colonna mappa + eventuale pannello docked. La mappa
    /// vive nel proprio GeometryReader, quindi quando il pannello entra la
    /// geometria (imageRect, marker, tap, collisioni) si ricalcola da sola
    /// dalla larghezza ridotta — nessun caso speciale.
    private var canvasContent: some View {
        HStack(spacing: 0) {
            mapColumn

            if isDockedPanelVisible, let vm = overlayVM {
                FloorplanDockedContextPanel(
                    overlayVM: vm,
                    floorplan: floorplan,
                    environmentViewModel: overlayEnvVM,
                    background: floorplanBackgroundColor,
                    adapterMap: currentAdapterMap()
                )
                .frame(width: FloorplanDockedContextPanel.width)
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .environment(\.colorScheme, chromeColorScheme)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isDockedPanelVisible)
    }

    /// Colonna mappa (l'intero canvas pre-redesign). Separata dalla catena di
    /// lifecycle: un'unica espressione col GeometryReader + 15 modifier
    /// superava il limite del type-checker.
    private var mapColumn: some View {
        GeometryReader { proxy in
            ZStack {
                floorplanBackgroundColor
                    .ignoresSafeArea()

                if let image = imageCache.image {
                    imageWithMarkers(image: image, container: proxy.size)
                        .scaleEffect(effectiveScale, anchor: .center)
                        // La planimetria è centrata nel canvas INTERO, non nello
                        // spazio libero sotto la barra. La chrome è sovrapposta
                        // in questo stesso ZStack, non impilata sopra: nessun
                        // layout obbliga l'immagine a scansarsi, e trattare la
                        // barra come opaca — spostando l'immagine di metà della
                        // sua altezza — impediva al disegno di scorrere sotto il
                        // vetro, che è esattamente ciò per cui il vetro esiste.
                        .offset(effectiveOffset)
                        .gesture(viewportController.zoomPanGesture(in: proxy.size))
                        .transition(.opacity)
                } else if imageCache.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        String(localized: "floorplan.image.unavailable", defaultValue: "Image not available"),
                        systemImage: "photo.badge.exclamationmark"
                    )
                }

                // Top bar: sempre visibile — TRANNE con una stanza zoomata su
                // iPhone: lì restano solo planimetria e "‹ indietro", perché
                // la mappa zoomata finiva sotto le trasparenze della chrome e
                // generava solo rumore (feedback 26/08).
                if !(isCompactScreen && !ui.isEditing && overlayVM?.zoomedRoomID != nil) {
                    topBar(in: proxy.size)
                        .environment(\.colorScheme, chromeColorScheme)
                        .transition(.opacity)
                }

                // Controlli secondari (zoom, toolbar marker): soggetti ad auto-hide
                secondaryControls(in: proxy.size)
                    .opacity(shouldShowControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: shouldShowControls)
                    .environment(\.colorScheme, chromeColorScheme)

                // iPhone stile Dov'è: pannello a trascinamento dal basso e
                // isola dei tab che gli flotta sopra. Spariscono con una
                // stanza zoomata (lì solo planimetria + indietro) e in editing.
                compactBottomPane(container: proxy.size)
                    .environment(\.colorScheme, chromeColorScheme)

                compactTabIsland
                    .environment(\.colorScheme, chromeColorScheme)

                // Azione bulk del filtro categoria (novità C): capsule scura
                // in basso al centro, solo con filtro attivo e dispositivi accesi.
                bulkOffButton
                    .environment(\.colorScheme, chromeColorScheme)

                // L'invito a ruotare resta solo in modifica: fuori, il posto
                // del grumo di marker l'ha preso lo zoom semantico (fase 4).
                if ui.isEditing, hidesMarkersInPortrait(container: proxy.size) {
                    rotateForMarkersHint
                        .environment(\.colorScheme, chromeColorScheme)
                }

                // "‹ nome piano" per uscire dallo zoom semantico (iPhone)
                zoomedRoomBackButton(container: proxy.size)
                    .environment(\.colorScheme, chromeColorScheme)

                // Right-side scenes panel overlay
                if ui.showScenesPanel {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                ui.showScenesPanel = false
                            }
                        }
                        .transition(.opacity)
                }

                // Su iPhone il pannello non si costruisce affatto: non è
                // apribile (il bottone Scene non c'è) e da chiuso restava
                // comunque nella gerarchia, spinto fuori da un `offset` — e un
                // bordo continuava a sporgere. Ciò che non esiste non sporge.
                if !isCompactScreen {
                    HStack(spacing: 0) {
                        Spacer()
                        ScenesSidePanel(isPresented: $ui.showScenesPanel)
                            .frame(width: min(proxy.size.width * 0.72, 320))
                            .offset(x: ui.showScenesPanel ? 0 : min(proxy.size.width * 0.72, 320) + 20)
                            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: ui.showScenesPanel)
                    }
                    .ignoresSafeArea(edges: .vertical)
                    .environment(\.colorScheme, chromeColorScheme)
                }

                // Il pannello su compact non è più un overlay laterale: è il
                // bottom sheet a 2 detent presentato da `observedCanvas`
                // (fase 4). Su regular resta il docked in canvasContent.
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleBackgroundTap(at: location, in: proxy.size)
            }
            // Zoom semantico: la messa a fuoco segue lo stato, qualunque sia
            // la sorgente del cambio (badge, stanza, drawer, cambio tab).
            .onChange(of: overlayVM?.zoomedRoomID) { _, newID in
                handleZoomedRoomChange(newID, container: proxy.size)
            }
        }
    }

    private var observedCanvas: some View {
        canvasContent
        .toolbar(.hidden, for: .navigationBar)
        .modifier(editorPresentationModifier)
        .suppressesIdleScreensaver(.floorplanInteraction, when: ui.shouldSuppressIdleScreensaver)
        .onAppear(perform: handleAppear)
        .onChange(of: homeKit.isReady) { _, isReady in
            if isReady {
                measureMain("isReady.subscribe") {
                    accessoryObservationCoordinator.subscribe(to: floorplan)
                }
                measureMain("isReady.overlayContext") {
                    refreshOverlayContext()
                }
                measureMain("isReady.adapterCaches") {
                    refreshAdapterCaches()
                }
            }
        }
        .onChange(of: homeKit.allAccessories.count) { _, _ in
            refreshOverlayContext()
        }
        .onChange(of: floorplan.linkedRooms.count) { _, _ in
            // Ricalcola il contesto quando le stanze linkate cambiano,
            // così la pill "Ambiente" appare non appena si collega la prima stanza.
            refreshOverlayContext()
        }
        .onChange(of: isAIEnabled) { _, _ in
            refreshOverlayContext()
        }
        .onChange(of: floorplan.updatedAt) { _, _ in
            imageLoader.refresh(for: floorplan)
        }
    }

    var body: some View {
        observedCanvas
        .onReceive(
            NotificationCenter.default.publisher(for: .floorplansDidApplyRemoteChanges),
            perform: handleFloorplanRemoteChanges
        )
        .onDisappear(perform: handleDisappear)
        .onChange(of: floorplan.accessories.count) { _, _ in
            accessoryObservationCoordinator.subscribe(to: floorplan)
        }
        .onChange(of: ui.isEditing) { _, newValue in
            if newValue {
                chromeController.enterEditingMode()
            } else {
                chromeController.scheduleAutoHide(isEditing: newValue)
            }
        }
        .onChange(of: homeKit.allAccessories) { _, _ in
            refreshAdapterCaches()
            trackSecurityModeChange()
        }
        .task(id: overlayVM?.activeMode, refreshEnvironmentOverlayWhileActive)
        // Su iPhone il cambio tab azzera lo zoom semantico anche nel
        // viewport: lo stato (`zoomedRoomID`) lo pulisce già il didSet del
        // modo, ma la mappa resterebbe inquadrata sulla stanza.
        .onChange(of: overlayVM?.activeMode) { _, _ in
            if isCompactScreen, viewport.zoomScale > 1.01 {
                viewportController.reset()
            }
        }
        // Meteo per la pill temperatura: si auto-limita a un refresh ogni 30'.
        .task { await weatherKit.refreshIfNeeded() }
        // La salute casa dipende dalla raggiungibilità: ricalcolo su evento
        // discreto, come per gli adapter.
        .onChange(of: homeKit.reachabilityVersion) { _, _ in
            refreshAdapterCaches()
        }
        .fullScreenCover(item: $preview3D) { request in
            FloorplanRealityPreviewView(floorplans: request.floorplans,
                                        initialID: request.initialID)
        }
    }

    /// Tutte le planimetrie, non solo questa: il menu del titolo nella 3D
    /// permette di cambiare piano, e da un solo piano sembrerebbe rotto.
    private func openPreview3D() {
        let descriptor = FetchDescriptor<Floorplan>(sortBy: [SortDescriptor(\.name)])
        let all = (try? modelContext.fetch(descriptor)) ?? [floorplan]
        preview3D = Preview3DFactory.request(initialID: floorplan.id,
                                             floorplans: all,
                                             modelContext: modelContext,
                                             cloudKitSync: cloudKitSync,
                                             homeKit: homeKit)
    }

    /// Installazioni "a muro": il loop foreground campiona ogni ~5 min, ma
    /// `overlayEnvVM` veniva caricato solo all'appear dell'editor e l'overlay
    /// Ambiente restava congelato per ore. Il loop gira in TUTTI i tab, non
    /// più solo in Ambiente: la barra di stato unificata mostra la temperatura
    /// interna ovunque, e senza ricarica resterebbe alla fotografia
    /// dell'appear. L'id sul task lo riavvia al cambio modalità, così
    /// entrare in Ambiente ricarica subito.
    @Sendable
    private func refreshEnvironmentOverlayWhileActive() async {
        while !Task.isCancelled {
            await overlayEnvVM.reloadFromCoreData()
            try? await Task.sleep(for: .seconds(5 * 60))
        }
    }

    private func handleAppear() {
        measureMain("appear.total") {
            if overlayVM == nil {
                overlayVM = FloorplanOverlayViewModel(floorplanID: floorplan.id)
            }
            measureMain("appear.envConfigure") {
                overlayEnvVM.configure(modelContainer: modelContext.container)
                overlayEnvVM.loadFromCoreData()
            }
            measureMain("appear.subscribe") {
                accessoryObservationCoordinator.subscribe(to: floorplan)
            }
            measureMain("appear.viewportRestore") {
                viewportController.restore()
            }

            if startInEditMode {
                ui.isEditing = true
                chromeController.enterEditingMode()
            } else {
                chromeController.scheduleAutoHide(isEditing: ui.isEditing)
            }

            measureMain("appear.imageRefresh") {
                imageLoader.refresh(for: floorplan)
            }
            measureMain("appear.backfillRoomLinks") {
                backfillMarkerRoomLinksIfNeeded()
            }
            measureMain("appear.overlayContext") {
                refreshOverlayContext()
            }
            measureMain("appear.adapterCaches") {
                refreshAdapterCaches()
            }
            measureMain("appear.help+security") {
                presentHelpIfNeeded()
                trackSecurityModeChange()
            }
        }
    }

    /// Checks if the security system mode has changed and records the activation timestamp.
    private func trackSecurityModeChange() {
        guard let update = runtimeContextController.updatedSecurityActivationDate(
            previousRawMode: lastKnownSecurityModeRaw,
            currentActivationDate: securityModeActivationDate
        ) else { return }

        lastKnownSecurityModeRaw = update.rawMode
        securityModeActivationDate = update.activationDate
    }

    /// Returns the cached SecuritySystemAdapter for the current home, if any.
    /// Il valore è aggiornato da `refreshAdapterCaches()` sui cambi di accessori;
    /// non riscansiona la casa ad ogni render.
    private func findSecurityAdapter() -> SecuritySystemAdapter? {
        cachedSecurityAdapter
    }

    /// Ricalcola gli adapter cache-ati (sicurezza + mappa marker) e la salute
    /// casa. Chiamato solo su eventi discreti (appear, HomeKit pronto, cambio
    /// elenco accessori, reachability), mai per-frame.
    private func refreshAdapterCaches() {
        cachedSecurityAdapter = runtimeContextController.securityAdapter()
        cachedAdapterMap = AccessoryAdapterFactory.adapterMap(homeKit: homeKit)
        cachedHealthScore = FloorplanStatusStripBuilder.weightedHealthScore(homeKit: homeKit)
    }

    /// Stato corrente dei quattro segnali della barra. I pezzi reattivi
    /// (contatti via adapter, situazioni via @Query, meteo) si leggono qui in
    /// body e invalidano da soli; la salute è cache-ata perché costosa.
    private var statusStripState: FloorplanStatusStripState {
        var state = FloorplanStatusStripState()

        state.controlsActiveCount = FloorplanStatusStripBuilder.activeDeviceCount(
            floorplan: floorplan,
            adapterMap: currentAdapterMap()
        )

        if let score = cachedHealthScore {
            state.healthScore = score
            state.healthLabel = AccessoryHealthLevel.from(score: score).label
        }

        if cachedOverlayContext.hasSecurityDevices {
            state.openingsCount = FloorplanStatusStripBuilder.openOpeningsCount(
                floorplan: floorplan,
                adapterMap: currentAdapterMap(),
                monitoredIDs: RoomSecurityEvaluator.monitoredIDs(from: securityMonitoredUUIDsRaw)
            )
            if let adapter = findSecurityAdapter() {
                state.alarmShortText = adapter.currentMode.displayName
            }
        }

        if !floorplan.linkedRooms.isEmpty {
            let counts = FloorplanStatusStripBuilder.situationCounts(
                insights: activeStripInsights,
                rooms: floorplan.linkedRooms
            )
            state.situationsCount = counts.total
            state.criticalCount = counts.critical
            state.criticalRoomName = counts.criticalRoomName
        }

        let unit = TemperatureUnit(rawValue: temperatureUnitRaw) ?? .celsius
        state.indoorText = FloorplanStatusStripBuilder.indoorTemperatureText(
            envVM: overlayEnvVM, unit: unit
        )
        if let outdoor = weatherKit.currentWeather?.outdoorTemperature {
            state.outdoorText = unit.format(outdoor)
        }

        return state
    }

    /// Mappa adapter corrente, con fallback di costruzione inline per la
    /// primissima valutazione del `body` (che precede `onAppear`): evita un
    /// frame iniziale con marker senza adapter.
    private func currentAdapterMap() -> [UUID: any AccessoryAdapter] {
        if cachedAdapterMap.isEmpty {
            return AccessoryAdapterFactory.adapterMap(homeKit: homeKit)
        }
        return cachedAdapterMap
    }

    private func openSidebar() {
        withAnimation(.spring(response: 0.4)) {
            columnVisibility = .all
        }
    }

    private func showAccessoryPicker() {
        ui.resetAccessoryPickerContext()
        ui.showingPicker = true
    }

    // MARK: - Top bar (sempre visibile)

    @ViewBuilder
    private func topBar(in size: CGSize) -> some View {
        FloorplanTopBarView(
            size: size,
            floorplan: floorplan,
            presentationStyle: presentationStyle,
            columnVisibility: columnVisibility,
            pinnedFloorplans: pinnedFloorplans,
            primaryFloorplanID: primaryFloorplanID,
            isEditing: ui.isEditing,
            overlayVM: overlayVM,
            overlayContext: cachedOverlayContext,
            statusStrip: statusStripState,
            categoryCounts: (!isCompactScreen && !ui.isEditing && overlayVM?.activeMode == .controls)
                ? FloorplanControlsClusterBuilder.floorCategoryCounts(floorplan: floorplan,
                                                                      adapterMap: currentAdapterMap())
                : [],
            environmentSensorTypes: overlayEnvVM.availableSensorTypes,
            isCloudKitMaster: cloudKitSync.isMaster,
            smartLightingStatus: smartLightingEngine.floorplanStatus,
            securityAdapter: findSecurityAdapter(),
            securityActivationDate: securityModeActivationDate > 0
                ? Date(timeIntervalSince1970: securityModeActivationDate)
                : nil,
            onOpenSidebar: openSidebar,
            onDismiss: dismiss.callAsFunction,
            onSelectFloorplan: onSelectFloorplan,
            onAddAccessory: showAccessoryPicker,
            onShowHelp: chromeController.showHelpManually,
            onShowDiagnostics: { ui.showFloorplanDiagnostics = true },
            onEditDrawing: { ui.drawingEditFloorplan = floorplan },
            onView3D: openPreview3D,
            onShowScenes: { ui.showScenesPanel = true },
            onToggleEditing: ui.toggleEditing,
            onPauseSmartLighting: smartLightingEngine.pauseFromFloorplan,
            onResumeSmartLighting: smartLightingEngine.resumeFromFloorplan
        )
    }

    // MARK: - Controlli secondari (auto-hide)

    @ViewBuilder
    private func secondaryControls(in size: CGSize) -> some View {
        FloorplanSecondaryControlsLayer(
            effectiveScale: effectiveScale,
            isEditing: ui.isEditing,
            isOverlayPanelVisible: overlayVM?.isPanelVisible,
            activeOverlayMode: overlayVM?.activeMode,
            selectedMarkerID: ui.selectedMarkerID,
            selectedMarker: selectedMarkerToolbarState,
            onResetZoom: resetZoom,
            onRenameMarker: { markerID, newLabel in
                applyRename(to: markerID, newLabel: newLabel)
            },
            onResetMarkerName: { markerID in
                applyRename(to: markerID, newLabel: "")
            },
            onRecenterMarker: recenterMarker,
            onDeleteMarker: { markerID in
                ui.pendingDeleteMarkerID = markerID
            },
            onDismissMarker: ui.dismissSelectedMarker,
            onChangeMarkerIcon: { markerID in
                ui.iconPickerTargetID = markerID
            },
            onResolveMarkerAudit: resolveMarkerAudit
        )
    }

    private var selectedMarkerToolbarState: FloorplanSelectedMarkerToolbarState? {
        guard ui.isEditing, let markerID = ui.selectedMarkerID else { return nil }
        guard let placed = marker(withID: markerID) else { return nil }
        return selectedMarkerToolbarStateBuilder.state(for: placed)
    }

    // MARK: - Invito a girare il telefono

    /// Sostituisce i marker su iPhone in verticale. Sta in basso e non al
    /// centro: la planimetria resta visibile e riconoscibile, che è metà del
    /// motivo per cui si è arrivati qui.
    private var rotateForMarkersHint: some View {
        VStack {
            Spacer()
            GlassTitlePill {
                HStack(spacing: 10) {
                    Image(systemName: "rotate.right")
                        .font(.subheadline.weight(.semibold))
                    Text(String(localized: "floorplan.rotateForMarkers",
                                defaultValue: "Rotate iPhone to see the devices"))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .transition(.opacity)
    }

    // MARK: - Azione bulk (filtro categoria, novità C)

    /// Categorie per cui il "Spegni tutto" ha senso (da design: luci, prese,
    /// media, clima). Le altre — sensori, camere — non si "spengono".
    private static let bulkTogglableCategories: Set<AccessoryCategory> =
        [.lights, .outlets, .television, .climate]

    /// Adapter attivi della categoria fra i marker posati (un accessorio con
    /// più marker conta una volta).
    private func activeBulkAdapters(for category: AccessoryCategory) -> [any AccessoryAdapter] {
        var seen = Set<UUID>()
        var result: [any AccessoryAdapter] = []
        let map = currentAdapterMap()
        for placed in floorplan.accessories {
            guard !seen.contains(placed.homeKitAccessoryUUID) else { continue }
            seen.insert(placed.homeKitAccessoryUUID)
            guard let adapter = map[placed.homeKitAccessoryUUID],
                  FloorplanControlsClusterBuilder.classify(adapter) == category,
                  adapter.isOn else { continue }
            result.append(adapter)
        }
        return result
    }

    @ViewBuilder
    private var bulkOffButton: some View {
        if !ui.isEditing,
           let vm = overlayVM, vm.activeMode == .controls,
           let filter = vm.categoryFilter,
           Self.bulkTogglableCategories.contains(filter) {
            let active = activeBulkAdapters(for: filter)
            if !active.isEmpty {
                VStack {
                    Spacer()
                    Button {
                        performBulkOff(category: filter)
                    } label: {
                        Text(String(localized: "floorplan.bulk.off",
                                    defaultValue: "Turn off all: \(filter.displayName) (\(active.count) on)"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FloorplanTokens.Surface.filterChipActiveText)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(FloorplanTokens.Surface.filterChipActive, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    // Su iPhone sale sopra pannello (peek) e isola.
                    .padding(.bottom, isCompactScreen
                             ? Self.compactIslandClearance + 68
                             : 28)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    /// Spegne tutti gli attivi della categoria. `performQuickToggle` è un
    /// toggle, ma la lista contiene solo `isOn == true`: l'esito è "off".
    /// Sequenziale di proposito, per non inondare HomeKit di scritture.
    private func performBulkOff(category: AccessoryCategory) {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        let adapters = activeBulkAdapters(for: category)
        Task {
            for adapter in adapters {
                try? await adapter.performQuickToggle(via: homeKit)
            }
        }
    }

    // MARK: - iPhone stile Dov'è (pannello + isola)

    /// Spazio verticale occupato dall'isola dei tab (pill due righe + margini).
    private static let compactIslandClearance: CGFloat = 72

    private var showsCompactPaneAndIsland: Bool {
        isCompactScreen && !ui.isEditing
            && overlayVM != nil
            && overlayVM?.zoomedRoomID == nil
    }

    @ViewBuilder
    private func compactBottomPane(container: CGSize) -> some View {
        if showsCompactPaneAndIsland, let vm = overlayVM {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                FloorplanBottomPane(
                    isExpanded: Binding(
                        get: { vm.isPanelVisible },
                        set: { expanded in
                            vm.isPanelVisible = expanded
                            if !expanded { vm.highlightedRoomID = nil }
                        }
                    ),
                    container: container,
                    islandClearance: Self.compactIslandClearance,
                    background: floorplanBackgroundColor,
                    title: vm.activeMode == .controls ? floorplan.name : vm.activeMode.label,
                    accent: vm.activeMode.accentColor
                ) {
                    FloorplanCompactPaneContent(
                        overlayVM: vm,
                        floorplan: floorplan,
                        environmentViewModel: overlayEnvVM,
                        adapterMap: currentAdapterMap(),
                        clusters: currentClusters(rooms: floorplan.linkedRooms),
                        categoryCounts: FloorplanControlsClusterBuilder.floorCategoryCounts(
                            floorplan: floorplan,
                            adapterMap: currentAdapterMap()
                        )
                    )
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(50)
        }
    }

    @ViewBuilder
    private var compactTabIsland: some View {
        if showsCompactPaneAndIsland, let vm = overlayVM {
            VStack {
                Spacer()
                FloorplanModePill(overlayVM: vm,
                                  context: cachedOverlayContext,
                                  status: statusStripState,
                                  isCompact: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .zIndex(60)
        }
    }

    private func drawingEditor(for floorplan: Floorplan) -> some View {
        DrawingFloorplanSheet(
            initialDocument: floorplan.drawingDocument,
            initialExteriorFillColorIndex: floorplan.exteriorFillColorIndex,
            initialVisualExportStyle: DrawingVisualExportStyle(rawValue: floorplan.drawingVisualExportStyleRaw) ?? .standard,
            initialExportRotation: floorplan.drawingExportRotation
        ) { image, rooms, doc, colorIndex, visualStyle, exportRotation in
            applyDrawingUpdate(
                FloorplanDrawingUpdate(
                    image: image,
                    rooms: rooms,
                    document: doc,
                    exteriorFillColorIndex: colorIndex,
                    visualStyle: visualStyle,
                    exportRotation: exportRotation
                )
            )
        }
    }

    private func applyDrawingUpdate(_ update: FloorplanDrawingUpdate) {
        drawingUpdateCoordinator.apply(update)
        imageLoader.refresh(for: floorplan)
        refreshOverlayContext()
    }
    
    // MARK: - Chrome lifecycle

    private func presentHelpIfNeeded() {
        chromeController.presentHelpIfNeeded {
            !ui.hasBlockingModalPresentation
        }
    }
    
    private func handleBackgroundTap(at tapLocation: CGPoint, in containerSize: CGSize) {
        // 1. Deselect marker in edit mode
        if ui.isEditing && ui.selectedMarkerID != nil {
            withAnimation(.spring(response: 0.35)) {
                ui.selectedMarkerID = nil
            }
            return
        }

        // 2. Not editing: show controls. Su iPhone in vista intera (Controlli)
        //    il tap su una stanza fa anche zoom semantico — il design lo
        //    prevede sia sul badge che sulla stanza stessa.
        if !ui.isEditing {
            chromeController.showControlsAndScheduleAutoHide(isEditing: ui.isEditing)
            if isCompactScreen, controlsClusterModeActive, let image = imageCache.image {
                // Con la rotazione attiva il tap va risolto nello spazio di
                // visualizzazione: immagine e stanze già trasposte.
                let isRotated = displayRotationActive(image: image, container: containerSize)
                let displaySize = isRotated
                    ? rotatedImageCache.rotated(for: image).size
                    : image.size
                let rooms = displayRooms(rotated: isRotated)
                if let resolution = resolveRoomTap(at: tapLocation,
                                                   imageSize: displaySize,
                                                   containerSize: containerSize,
                                                   rooms: rooms),
                   let roomID = resolution.roomID {
                    overlayVM?.zoomedRoomID = roomID
                }
            }
            return
        }

        // 3. Editing + has linked room areas: detect which area was tapped
        guard !floorplan.linkedRooms.isEmpty else { return }
        guard let image = imageCache.image,
              let tapResolution = resolveRoomTap(
                at: tapLocation,
                imageSize: image.size,
                containerSize: containerSize
              ) else {
            ui.resetAccessoryPickerContext()
            return
        }

        ui.pendingMarkerPosition = tapResolution.markerPosition

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            ui.editHighlightedRoomID = tapResolution.roomID
        }
        ui.pickerRoomFilter = tapResolution.roomID

        ui.showingPicker = true
    }

    private func resolveRoomTap(at tapLocation: CGPoint,
                                imageSize: CGSize,
                                containerSize: CGSize,
                                rooms: [LinkedRoom]? = nil) -> FloorplanRoomTapResolution? {
        FloorplanRoomTapResolver(
            linkedRooms: rooms ?? floorplan.linkedRooms,
            imageSize: imageSize,
            containerSize: containerSize,
            effectiveScale: effectiveScale,
            effectiveOffset: effectiveOffset,
            topInset: chromeLayout(for: containerSize).topInset
        ).resolve(tapLocation: tapLocation)
    }
    
    private func resetZoom() {
        viewportController.reset()
    }

    private func handleFloorplanRemoteChanges(_ notification: Notification) {
        SyncDiagnosticsLogger.log(
            "Editor observed floorplan remote-change floorplan=\(floorplan.id.uuidString) markers=\(floorplan.accessories.count)"
        )
        imageLoader.refresh(for: floorplan)
        refreshOverlayContext()
        accessoryObservationCoordinator.subscribe(to: floorplan)
    }

    private func handleDisappear() {
        accessoryObservationCoordinator.unsubscribe(from: floorplan)
        chromeController.cancelAutoHide()
    }

    private func handleDrawingDismiss() {
        imageLoader.refresh(for: floorplan)
        refreshOverlayContext()
        accessoryObservationCoordinator.subscribe(to: floorplan)
    }

    // MARK: - Image rect

    /// Layout della chrome per questa sessione: dalla fase 1 la barra di stato
    /// unificata esiste sempre, quindi il margine la include sempre — anche in
    /// editing, dove il banner di modifica ne prende visivamente il posto. Il
    /// valore resta costante per tutta la sessione (mai per-modo, mai misurato)
    /// e canvas + tap resolver lo ereditano da qui senza poter divergere.
    /// Layout chrome per il contenitore dato. Dipende dalla size class E
    /// dall'orientamento (la riga tab compatta esiste solo in verticale —
    /// in landscape la mappa si prende tutto): l'orientamento arriva dal
    /// contenitore, quindi il layout si calcola per-contenitore, sempre da
    /// costanti, mai da misure.
    private func chromeLayout(for container: CGSize) -> FloorplanChromeLayout {
        // Su compact i tab vivono nell'isola in basso (stile Dov'è): in alto
        // resta la barra minima, quindi basta il margine base.
        FloorplanChromeLayout(hasTwoRowTabBar: !isCompactScreen)
    }

    private func imageRect(imageSize: CGSize, container: CGSize) -> CGRect {
        FloorplanCanvasGeometry.imageRect(
            imageSize: imageSize,
            container: container,
            topInset: chromeLayout(for: container).topInset
        )
    }
    
    /// Su iPhone in verticale la planimetria si riduce a una fascia larga ~354
    /// punti. I marker però sono dimensionati in punti e non rimpiccioliscono
    /// con lei: si ammucchiano fino a coprire il disegno che dovrebbero
    /// annotare. Meglio dire all'utente di girare il telefono che mostrargli un
    /// grumo. La misura è quella del contenitore, non l'orientamento del
    /// dispositivo: è la larghezza reale che conta.
    private func hidesMarkersInPortrait(container: CGSize) -> Bool {
        isCompactScreen && container.height > container.width
    }

    private var isCompactScreen: Bool { horizontalSizeClass == .compact }

    // MARK: - Cluster (tab Controlli, novità C)

    /// Vero quando il tab Controlli mostra il riassunto per stanza al posto
    /// dei marker: card cluster su iPad, badge su iPhone. Niente filtro,
    /// niente stanza espansa/zoomata, e servono stanze con marker — senza
    /// stanze collegate si resta ai marker classici.
    private var controlsClusterModeActive: Bool {
        guard !ui.isEditing,
              let vm = overlayVM, vm.activeMode == .controls,
              vm.categoryFilter == nil,
              !vm.areAllRoomsExpanded,
              !floorplan.linkedRooms.isEmpty, !floorplan.accessories.isEmpty
        else { return false }
        if isCompactScreen {
            return vm.zoomedRoomID == nil
        }
        return vm.expandedRoomID == nil
    }

    private func currentClusters(rooms: [LinkedRoom]) -> [FloorplanRoomCluster] {
        FloorplanControlsClusterBuilder.clusters(floorplan: floorplan,
                                                 rooms: rooms,
                                                 adapterMap: currentAdapterMap())
    }

    // MARK: - Rotazione planimetria (v3-B, regola mobile 3)

    /// Vero quando la planimetria si mostra ruotata di 90°: solo in
    /// visualizzazione, solo compact, solo se la sproporzione supera 1.5× e
    /// girarla aiuta. In modifica MAI: le scritture restano nell'orientamento
    /// originale e non serve alcuna trasformazione inversa.
    private func displayRotationActive(image: UIImage, container: CGSize) -> Bool {
        !ui.isEditing && isCompactScreen
            && FloorplanRotation.shouldRotate(imageSize: image.size, container: container)
    }

    /// Stanze nell'orientamento di visualizzazione corrente.
    private func displayRooms(rotated: Bool) -> [LinkedRoom] {
        rotated ? FloorplanRotation.rooms(floorplan.linkedRooms) : floorplan.linkedRooms
    }

    private func imageWithMarkers(image: UIImage, container: CGSize) -> some View {
        // Rotazione (v3-B): da qui in giù lavora TUTTO su immagine e
        // coordinate già trasposte — geometria, marker, tap, overlay.
        let isRotated = displayRotationActive(image: image, container: container)
        let displayImage = isRotated ? rotatedImageCache.rotated(for: image) : image
        let rooms = displayRooms(rotated: isRotated)

        let rect = imageRect(imageSize: displayImage.size, container: container)
        // In modifica vale ancora il vecchio riparo del portrait iPhone; fuori
        // dalla modifica ci pensa la vista a riassunto (cluster/badge + zoom
        // semantico) a non ammucchiare marker sullo schermo stretto.
        let showMarkers = ui.isEditing
            ? !hidesMarkersInPortrait(container: container)
            : (overlayVM?.activeMode == .controls && !controlsClusterModeActive)
        return FloorplanCanvasView(
            image: displayImage,
            containerSize: container,
            chrome: chromeLayout(for: container),
            showOverlayLayer: overlayVM != nil && !ui.isEditing,
            showEditLayer: ui.isEditing && !floorplan.linkedRooms.isEmpty,
            showMarkers: showMarkers,
            markerItems: showMarkers ? markerRenderItems(rotated: isRotated) : [],
            collisionOffsets: showMarkers ? markerCollisionOffsets(in: rect) : [:]
        ) { container, imageRect in
            if let vm = overlayVM, !ui.isEditing {
                overlayLayer(vm: vm, container: container, imageRect: imageRect,
                             rooms: rooms, isRotated: isRotated)
            } else {
                EmptyView()
            }
        } editLayer: { container, imageRect in
            editRoomInteractionLayer(container: container, imageRect: imageRect)
        } markerContent: { item, imageRect, collisionOffset in
            markerView(
                item: item,
                in: imageRect,
                collisionOffset: collisionOffset
            )
        } emptyContent: {
            FloorplanEmptyMarkersHint(
                hasAreas: !floorplan.linkedRooms.isEmpty,
                onAddAccessory: {
                    ui.pickerRoomFilter = nil
                    ui.pendingMarkerPosition = nil
                    ui.showingPicker = true
                }
            )
        } overMarkerLayer: { _, imageRect in
            expandedRoomChrome(imageRect: imageRect)
        }
    }

    /// Chrome della stanza espansa (pill di compressione), SOPRA i marker
    /// così resta tappabile anche dove i dispositivi si addensano. Segue lo
    /// schema colori della planimetria come il resto della chrome.
    @ViewBuilder
    private func expandedRoomChrome(imageRect: CGRect) -> some View {
        if !isCompactScreen, !ui.isEditing,
           let vm = overlayVM, vm.activeMode == .controls,
           let expandedID = vm.expandedRoomID,
           let room = floorplan.linkedRooms.first(where: { $0.hmRoomUUID == expandedID }) {
            ExpandedRoomCollapsePill(
                room: room,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                onCollapse: { vm.collapseRoom() }
            )
            .environment(\.colorScheme, chromeColorScheme)
        }
    }

    private func editRoomInteractionLayer(container: CGSize, imageRect: CGRect) -> some View {
        FloorplanEditRoomLayer(
            rooms: floorplan.linkedRooms,
            containerSize: container,
            imageRect: imageRect,
            highlightedRoomID: ui.editHighlightedRoomID
        )
    }

    @ViewBuilder
    private func overlayLayer(vm: FloorplanOverlayViewModel,
                              container: CGSize,
                              imageRect: CGRect,
                              rooms: [LinkedRoom],
                              isRotated: Bool) -> some View {
        switch vm.activeMode {
        case .controls:
            if !rooms.isEmpty, !floorplan.accessories.isEmpty {
                ControlsClusterOverlayView(
                    floorplan: floorplan,
                    overlayVM: vm,
                    containerSize: container,
                    imageRect: imageRect,
                    effectiveScale: effectiveScale,
                    clusters: currentClusters(rooms: rooms),
                    isCompact: isCompactScreen,
                    onZoomRoom: { cluster in
                        vm.zoomedRoomID = cluster.room.hmRoomUUID
                    }
                )
                // Le card seguono la luminanza della PLANIMETRIA, non il tema
                // iOS: i token si risolvono sul trait iniettato, e senza
                // questo un iPad in dark metteva card scure su disegno chiaro.
                .environment(\.colorScheme, chromeColorScheme)
            } else {
                EmptyView()
            }
        case .environment:
            EnvironmentOverlayView(
                floorplan: floorplan,
                overlayVM: vm,
                containerSize: container,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                effectiveOffset: effectiveOffset,
                envVM: overlayEnvVM,
                displayRooms: isRotated ? rooms : nil
            )
        case .security:
            SecurityOverlayView(
                floorplan: floorplan,
                overlayVM: vm,
                containerSize: container,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                effectiveOffset: effectiveOffset,
                displayRooms: isRotated ? rooms : nil
            )
        case .intelligence:
            IntelligenceOverlayView(
                floorplan: floorplan,
                overlayVM: vm,
                containerSize: container,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                effectiveOffset: effectiveOffset,
                displayRooms: isRotated ? rooms : nil
            )
        }
    }

    // MARK: - Marker

    @ViewBuilder
    private func markerView(item: FloorplanMarkerRenderItem,
                            in imageRect: CGRect,
                            collisionOffset: CGSize) -> some View {
        let basePoint = CGPoint(
            x: imageRect.origin.x + item.position.x * imageRect.width,
            y: imageRect.origin.y + item.position.y * imageRect.height
        )
        let delta = ui.dragDeltas[item.id] ?? .zero
        let livePoint = CGPoint(x: basePoint.x + delta.width,
                                y: basePoint.y + delta.height)
        let displayPoint = CGPoint(
            x: livePoint.x + collisionOffset.width,
            y: livePoint.y + collisionOffset.height
        )
        
        let inverseScale = 1.0 / effectiveScale
        
        AccessoryMarkerView(
            adapter: item.adapter,
            isEditing: ui.isEditing,
            isSelected: ui.isEditing && item.isSelected,
            isExecuting: item.isExecuting,
            editIssue: item.editIssue,
            label: item.displayLabel,
            hasCustomLabel: item.hasCustomLabel,
            allowsCameraSnapshot: item.allowsCameraSnapshot,
            labelOverride: controlsLabelOverride(for: item)
        )
        .scaleEffect(inverseScale)
        .position(displayPoint)
        .offset(x: item.isShaking ? 6 : 0)
        .animation(item.isShaking ? .default.repeatCount(3, autoreverses: true).speed(8) : .default,
                   value: item.isShaking)
        .animation(.spring(response: 0.3), value: item.isSelected)
        .gesture(
            ui.isEditing
            ? nil
            : markerInteractionGesture(for: item.id, accessory: item.accessory, adapter: item.adapter)
        )
        .simultaneousGesture(
            ui.isEditing
            ? TapGesture()
                .onEnded {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        ui.selectedMarkerID = (ui.selectedMarkerID == item.id) ? nil : item.id
                    }
                }
            : nil
        )
        .gesture(
            ui.isEditing ? dragGesture(for: item.id, position: item.position, imageRect: imageRect) : nil
        )
    }

    private func markerRenderItems(rotated: Bool = false) -> [FloorplanMarkerRenderItem] {
        var items = FloorplanMarkerRenderItemBuilder(
            adaptersByUUID: currentAdapterMap(),
            isEditing: ui.isEditing,
            allowsCameraSnapshot: !ui.isEditing && overlayVM?.activeMode == .security,
            selectedMarkerID: ui.selectedMarkerID,
            executingMarkerID: ui.executingMarkerID,
            shakeMarkerID: ui.shakeMarkerID,
            duplicatedMarkerAccessoryIDs: duplicatedMarkerAccessoryIDs,
            linkedRooms: floorplan.linkedRooms
        ).makeItems(from: floorplan.accessories)
        if rotated {
            items = items.map { item in
                var transposed = item
                transposed.position = FloorplanRotation.point(item.position)
                return transposed
            }
        }
        return filteredControlsItems(items)
    }

    /// Filtro del redesign sul tab Controlli (regular, fuori dalla modifica):
    /// col filtro categoria restano solo i marker della categoria su tutto il
    /// piano; con la stanza espansa solo i suoi. Altrove la lista passa intera.
    private func filteredControlsItems(_ items: [FloorplanMarkerRenderItem]) -> [FloorplanMarkerRenderItem] {
        guard !ui.isEditing,
              let vm = overlayVM, vm.activeMode == .controls else { return items }

        // Vista esplosa: tutti i marker, regola etichette storica.
        if vm.areAllRoomsExpanded { return items }

        if let filter = vm.categoryFilter {
            return items.filter { FloorplanControlsClusterBuilder.classify($0.adapter) == filter }
        }
        let focusedRoomID = isCompactScreen ? vm.zoomedRoomID : vm.expandedRoomID
        if let focusedRoomID {
            return items.filter { item in
                FloorplanControlsClusterBuilder.roomID(
                    adapter: item.adapter,
                    linkedRoomUUID: item.linkedRoomUUID,
                    rooms: floorplan.linkedRooms
                ) == focusedRoomID
            }
        }
        return items
    }

    /// Regola etichette del redesign (novità C): stanza espansa/zoomata →
    /// tutte visibili; filtro categoria → solo attivi o in allarme.
    private func controlsLabelOverride(for item: FloorplanMarkerRenderItem) -> Bool? {
        guard !ui.isEditing,
              let vm = overlayVM, vm.activeMode == .controls else { return nil }
        if vm.areAllRoomsExpanded { return nil }
        if vm.categoryFilter != nil {
            let urgency = item.adapter?.visualUrgency
            return item.adapter?.isOn == true || urgency == .alarm || urgency == .warning
        }
        if isCompactScreen {
            return vm.zoomedRoomID != nil ? true : nil
        }
        if vm.expandedRoomID != nil { return true }
        return nil
    }

    // MARK: - Zoom semantico (iPhone, fase 4)

    /// Reazione al cambio di stanza zoomata (v3-B): la messa a fuoco del
    /// viewport vive QUI, agganciata al cambio di stato, così qualunque
    /// sorgente — badge sulla mappa, tap sulla stanza, riga del drawer —
    /// deve solo scrivere `zoomedRoomID` e non ha bisogno del contenitore.
    private func handleZoomedRoomChange(_ roomID: UUID?, container: CGSize) {
        guard isCompactScreen else { return }
        guard let roomID else {
            if viewport.zoomScale > 1.01 { viewportController.reset() }
            return
        }
        guard let image = imageCache.image else { return }
        let isRotated = displayRotationActive(image: image, container: container)
        let displaySize = isRotated
            ? rotatedImageCache.rotated(for: image).size
            : image.size
        let rooms = displayRooms(rotated: isRotated)
        guard let room = rooms.first(where: { $0.hmRoomUUID == roomID }) else { return }
        let rect = imageRect(imageSize: displaySize, container: container)
        let roomRect = FloorplanCoordinateHelper(imageRect: rect)
            .screenRect(from: room.normalizedRect)
        viewportController.focus(on: roomRect, in: container)
    }

    private func zoomOutToFullPlan() {
        overlayVM?.zoomedRoomID = nil
    }

    /// Bottone "‹ nome piano" per uscire dallo zoom semantico. Fisso in alto
    /// a sinistra sotto la chrome, fuori dal subtree scalato.
    @ViewBuilder
    private func zoomedRoomBackButton(container: CGSize) -> some View {
        if isCompactScreen, !ui.isEditing,
           overlayVM?.activeMode == .controls,
           overlayVM?.zoomedRoomID != nil {
            VStack {
                HStack {
                    Button(action: zoomOutToFullPlan) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text(floorplan.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(FloorplanTokens.Surface.filterChipActiveText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(FloorplanTokens.Surface.filterChipActive)
                                .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "floorplan.zoom.back",
                                               defaultValue: "Back to \(floorplan.name)"))
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 16)
            // Con la stanza zoomata la chrome è nascosta: il bottone sale
            // in alto, unico elemento sopra la planimetria.
            .padding(.top, 12)
            .transition(.opacity)
        }
    }

    private var markerAuditService: FloorplanMarkerAuditService {
        FloorplanMarkerAuditService(
            isEditing: ui.isEditing,
            duplicatedMarkerAccessoryIDs: duplicatedMarkerAccessoryIDs,
            linkedRooms: floorplan.linkedRooms
        )
    }

    private var selectedMarkerToolbarStateBuilder: FloorplanSelectedMarkerToolbarStateBuilder {
        FloorplanSelectedMarkerToolbarStateBuilder(
            homeKit: homeKit,
            markerAuditService: markerAuditService
        )
    }

    private var markerEditingCoordinator: FloorplanMarkerEditingCoordinator {
        FloorplanMarkerEditingCoordinator(
            floorplan: floorplan,
            modelContext: modelContext,
            cloudKitSync: cloudKitSync,
            homeKit: homeKit
        )
    }

    private var drawingUpdateCoordinator: FloorplanDrawingUpdateCoordinator {
        FloorplanDrawingUpdateCoordinator(
            floorplan: floorplan,
            modelContext: modelContext,
            cloudKitSync: cloudKitSync,
            markerEditingCoordinator: markerEditingCoordinator
        )
    }

    private var accessoryObservationCoordinator: FloorplanAccessoryObservationCoordinator {
        FloorplanAccessoryObservationCoordinator(homeKit: homeKit)
    }

    private var viewportController: FloorplanViewportController {
        FloorplanViewportController(viewport: $viewport, floorplanID: floorplan.id)
    }

    private var imageLoader: FloorplanImageLoader {
        FloorplanImageLoader(cache: $imageCache)
    }

    private var runtimeContextController: FloorplanRuntimeContextController {
        FloorplanRuntimeContextController(
            floorplan: floorplan,
            homeKit: homeKit,
            isAIEnabled: isAIEnabled
        )
    }

    private var chromeController: FloorplanInteractionChromeController {
        FloorplanInteractionChromeController(
            controlsVisible: $controlsVisible,
            hideTask: $hideTask,
            showHelp: $ui.showFloorplanHelp,
            hasSeenHelp: $hasSeenFloorplanHelp
        )
    }

    private var editorPresentationModifier: FloorplanEditorPresentationModifier {
        FloorplanEditorPresentationModifier(
            floorplan: floorplan,
            homeKit: homeKit,
            modelContext: modelContext,
            cloudKitSync: cloudKitSync,
            accessoryPickerTitle: accessoryPickerTitle,
            ui: ui,
            onAddAccessory: { accessory, position in
                addAccessory(accessory, at: position)
            },
            onStartAssistedPlacement: { roomID in
                startAssistedPlacement(for: roomID)
            },
            onHelpDismiss: chromeController.markHelpSeen,
            onHelpClose: chromeController.dismissHelp,
            onDrawingDismiss: handleDrawingDismiss,
            drawingEditor: { editingFloorplan in
                AnyView(drawingEditor(for: editingFloorplan))
            },
            onDeleteMarker: { markerID in
                deleteMarker(id: markerID)
            }
        )
    }

    private func markerInteractionGesture(for markerID: UUID,
                                          accessory: HMAccessory?,
                                          adapter: (any AccessoryAdapter)?) -> some Gesture {
        LongPressGesture(minimumDuration: 0.42, maximumDistance: 64)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first:
                    if let accessory {
                        chromeController.scheduleAutoHide(isEditing: ui.isEditing)
                        ui.controllingAccessory = accessory
                    }
                case .second:
                    handleTap(on: markerID, accessory: accessory, adapter: adapter)
                }
            }
    }

    private func resolveMarkerAudit(for markerID: UUID) {
        guard let placed = marker(withID: markerID) else { return }
        let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID)
        guard let issue = markerAuditService.editIssue(for: placed, accessory: accessory) else { return }

        switch issue {
        case .missingHomeKitAccessory, .duplicateMarker:
            ui.pendingDeleteMarkerID = markerID
        case .outsideLinkedRoom:
            recenterMarker(id: markerID)
        case .roomLinkMismatch:
            alignMarkerRoomLink(id: markerID)
        }
    }

    private func alignMarkerRoomLink(id markerID: UUID) {
        markerEditingCoordinator.alignMarkerRoomLink(id: markerID)
    }

    private func markerCollisionOffsets(in imageRect: CGRect) -> [UUID: CGSize] {
        collisionOffsetCache.offsets(
            markers: floorplan.accessories,
            isEditing: ui.isEditing,
            effectiveScale: effectiveScale,
            in: imageRect
        )
    }
    
    // MARK: - Tap handling
    
    private func handleTap(on markerID: UUID,
                           accessory: HMAccessory?,
                           adapter: (any AccessoryAdapter)?) {
        guard !ui.isEditing else { return }
        guard let accessory else { return }

        if ui.suppressNextMarkerTapID == markerID {
            ui.suppressNextMarkerTapID = nil
            return
        }

        chromeController.scheduleAutoHide(isEditing: ui.isEditing)

        // Tap: toggle diretto se supportato; per il clima (novità D) la vista
        // parametri si apre nel pannello docked; per il resto lo sheet storico.
        if let adapter, adapter.supportsQuickToggle {
            performQuickToggle(adapter: adapter, markerID: markerID)
        } else if !isCompactScreen,
                  overlayVM?.activeMode == .controls,
                  adapter is (any ThermostatControlling),
                  let vm = overlayVM {
            vm.showClimateDetail(for: accessory.uniqueIdentifier)
        } else {
            ui.controllingAccessory = accessory
        }
    }
    
    private func performQuickToggle(adapter: any AccessoryAdapter, markerID: UUID) {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        ui.executingMarkerID = markerID
        
        Task {
            do {
                try await adapter.performQuickToggle(via: homeKit)
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
            await MainActor.run {
                if ui.executingMarkerID == markerID {
                    ui.executingMarkerID = nil
                }
            }
        }
    }
    
    private func triggerShake(for id: UUID) {
        ui.shakeMarkerID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if ui.shakeMarkerID == id {
                ui.shakeMarkerID = nil
            }
        }
    }
    
    // MARK: - Drag dei marker
    
    private func dragGesture(for markerID: UUID,
                             position: NormalizedPoint,
                             imageRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let s = effectiveScale
                ui.dragDeltas[markerID] = CGSize(
                    width: value.translation.width / s,
                    height: value.translation.height / s
                )
            }
            .onEnded { value in
                let s = effectiveScale
                let tx = value.translation.width / s
                let ty = value.translation.height / s
                let basePointX = position.x * imageRect.width
                let basePointY = position.y * imageRect.height
                let newX = basePointX + tx
                let newY = basePointY + ty
                
                let normalized = NormalizedPoint(
                    x: max(0, min(1, newX / imageRect.width)),
                    y: max(0, min(1, newY / imageRect.height))
                )
                markerEditingCoordinator.moveMarker(id: markerID, to: normalized)
                
                ui.dragDeltas[markerID] = .zero
            }
    }

    // MARK: - Marker actions

    private func startAssistedPlacement(for roomID: UUID) {
        ui.pickerRoomFilter = roomID
        ui.editHighlightedRoomID = roomID
        ui.pendingMarkerPosition = floorplan.linkedRooms
            .first { $0.hmRoomUUID == roomID }
            .map(markerEditingCoordinator.normalizedCenter)

        ui.showFloorplanDiagnostics = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            ui.showingPicker = true
        }
    }
    
    private func addAccessory(_ accessory: HMAccessory, at position: NormalizedPoint? = nil) {
        markerEditingCoordinator.addAccessory(accessory, at: position)
    }

    private func deleteMarker(id markerID: UUID) {
        markerEditingCoordinator.deleteMarker(id: markerID)
        ui.selectedMarkerID = nil
        ui.pendingDeleteMarkerID = nil
    }

    private func recenterMarker(id markerID: UUID) {
        markerEditingCoordinator.recenterMarker(id: markerID)
    }

    private func applyRename(to markerID: UUID, newLabel: String) {
        markerEditingCoordinator.applyRename(to: markerID, newLabel: newLabel)
    }

    private func backfillMarkerRoomLinksIfNeeded() {
        markerEditingCoordinator.backfillMarkerRoomLinksIfNeeded()
        // Stesso momento, stessa logica: chi ha marker posati da prima si
        // ritrova il legame con l'apertura senza dover rifare niente.
        markerEditingCoordinator.backfillMarkerOpeningLinksIfNeeded()
    }
}
