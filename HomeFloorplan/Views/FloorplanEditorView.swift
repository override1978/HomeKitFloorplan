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

    /// Contenuto canvas separato dalla catena di lifecycle: un'unica espressione
    /// col GeometryReader + 15 modifier superava il limite del type-checker.
    private var canvasContent: some View {
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

                // Top bar: sempre visibile
                topBar(in: proxy.size)
                    .environment(\.colorScheme, chromeColorScheme)

                // Controlli secondari (zoom, toolbar marker): soggetti ad auto-hide
                secondaryControls(in: proxy.size)
                    .opacity(shouldShowControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: shouldShowControls)
                    .environment(\.colorScheme, chromeColorScheme)

                // Pulsante apri-pannello — sempre visibile (non soggetto ad auto-hide)
                openPanelButton
                    .environment(\.colorScheme, chromeColorScheme)

                if hidesMarkersInPortrait(container: proxy.size) {
                    rotateForMarkersHint
                        .environment(\.colorScheme, chromeColorScheme)
                }

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

                // Z+4: overlay context panel
                if let vm = overlayVM {
                    FloorplanOverlayContextContent(
                        overlayVM: vm,
                        containerWidth: proxy.size.width,
                        floorplan: floorplan,
                        homeKit: homeKit,
                        environmentViewModel: overlayEnvVM
                    )
                    // Il pannello segue la planimetria come il resto della
                    // chrome: era l'ultimo pezzo flottante rimasto appeso al
                    // tema di sistema. Con iOS scuro e planimetria chiara la
                    // differenza si vedeva a occhio, perché il vetro si adatta a
                    // ciò che ha dietro mentre un materiale obbedisce a iOS —
                    // così una card non ancora convertita restava scura in mezzo
                    // a card chiare.
                    .environment(\.colorScheme, chromeColorScheme)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleBackgroundTap(at: location, in: proxy.size)
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
    }

    /// Installazioni "a muro": il loop foreground campiona ogni ~5 min, ma
    /// `overlayEnvVM` veniva caricato solo all'appear dell'editor e l'overlay
    /// Ambiente restava congelato per ore. Finché la modalità Ambiente è
    /// attiva, ricarica subito e poi a cadenza allineata al campionamento;
    /// il task si cancella da solo al cambio modalità o all'uscita.
    @Sendable
    private func refreshEnvironmentOverlayWhileActive() async {
        guard overlayVM?.activeMode == .environment else { return }
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

    /// Ricalcola gli adapter cache-ati (sicurezza + mappa marker). Chiamato solo
    /// su eventi discreti (appear, HomeKit pronto, cambio elenco accessori),
    /// mai per-frame.
    private func refreshAdapterCaches() {
        cachedSecurityAdapter = runtimeContextController.securityAdapter()
        cachedAdapterMap = AccessoryAdapterFactory.adapterMap(homeKit: homeKit)
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

    // MARK: - Pulsante apri pannello (sempre visibile, non soggetto ad auto-hide)

    /// Bottone bottom-right che apre il pannello contestuale.
    /// Vive in un proprio layer ZStack così non scompare con l'auto-hide dei controlli secondari.
    @ViewBuilder
    private var openPanelButton: some View {
        if !ui.isEditing, let vm = overlayVM,
           vm.activeMode != .controls, !vm.isPanelVisible {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    OverlayPanelMarkerButton(mode: vm.activeMode) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                            vm.isPanelVisible = true
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: vm.isPanelVisible)
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

        // 2. Not editing: show controls
        if !ui.isEditing {
            chromeController.showControlsAndScheduleAutoHide(isEditing: ui.isEditing)
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
                                containerSize: CGSize) -> FloorplanRoomTapResolution? {
        FloorplanRoomTapResolver(
            linkedRooms: floorplan.linkedRooms,
            imageSize: imageSize,
            containerSize: containerSize,
            effectiveScale: effectiveScale,
            effectiveOffset: effectiveOffset
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
    
    private func imageRect(imageSize: CGSize, container: CGSize) -> CGRect {
        FloorplanCanvasGeometry.imageRect(imageSize: imageSize, container: container)
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

    private func imageWithMarkers(image: UIImage, container: CGSize) -> some View {
        let rect = imageRect(imageSize: image.size, container: container)
        let showMarkers = !hidesMarkersInPortrait(container: container)
            && (ui.isEditing || (overlayVM?.activeMode == .controls))
        return FloorplanCanvasView(
            image: image,
            containerSize: container,
            showOverlayLayer: overlayVM != nil && !ui.isEditing,
            showEditLayer: ui.isEditing && !floorplan.linkedRooms.isEmpty,
            showMarkers: showMarkers,
            markerItems: showMarkers ? markerRenderItems() : [],
            collisionOffsets: showMarkers ? markerCollisionOffsets(in: rect) : [:]
        ) { container, imageRect in
            if let vm = overlayVM, !ui.isEditing {
                overlayLayer(vm: vm, container: container, imageRect: imageRect)
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
    private func overlayLayer(vm: FloorplanOverlayViewModel, container: CGSize, imageRect: CGRect) -> some View {
        switch vm.activeMode {
        case .controls:
            EmptyView()
        case .environment:
            EnvironmentOverlayView(
                floorplan: floorplan,
                overlayVM: vm,
                containerSize: container,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                effectiveOffset: effectiveOffset,
                envVM: overlayEnvVM
            )
        case .security:
            SecurityOverlayView(
                floorplan: floorplan,
                overlayVM: vm,
                containerSize: container,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                effectiveOffset: effectiveOffset
            )
        case .intelligence:
            IntelligenceOverlayView(
                floorplan: floorplan,
                overlayVM: vm,
                containerSize: container,
                imageRect: imageRect,
                effectiveScale: effectiveScale,
                effectiveOffset: effectiveOffset
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
            allowsCameraSnapshot: item.allowsCameraSnapshot
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

    private func markerRenderItems() -> [FloorplanMarkerRenderItem] {
        FloorplanMarkerRenderItemBuilder(
            adaptersByUUID: currentAdapterMap(),
            isEditing: ui.isEditing,
            allowsCameraSnapshot: !ui.isEditing && overlayVM?.activeMode == .security,
            selectedMarkerID: ui.selectedMarkerID,
            executingMarkerID: ui.executingMarkerID,
            shakeMarkerID: ui.shakeMarkerID,
            duplicatedMarkerAccessoryIDs: duplicatedMarkerAccessoryIDs,
            linkedRooms: floorplan.linkedRooms
        ).makeItems(from: floorplan.accessories)
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

        // Tap: toggle diretto se supportato, altrimenti apre il pannello dettaglio.
        if let adapter, adapter.supportsQuickToggle {
            performQuickToggle(adapter: adapter, markerID: markerID)
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
    }
}
