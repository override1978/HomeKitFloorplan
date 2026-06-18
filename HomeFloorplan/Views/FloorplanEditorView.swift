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
    @Environment(HabitAnalysisService.self) private var habitService
    
    @State private var isEditing: Bool = false
    @State private var showingPicker: Bool = false
    /// When set, the picker shows this room prominently (tap on room area).
    @State private var pickerRoomFilter: UUID?
    /// Normalized position where the user tapped — new accessories placed here.
    @State private var pendingMarkerPosition: NormalizedPoint?
    @State private var dragDeltas: [UUID: CGSize] = [:]
    @State private var controllingAccessory: HMAccessory?
    @State private var shakeMarkerID: UUID?
    @State private var selectedMarkerID: UUID?
    @State private var pendingDelete: PlacedAccessory?
    @State private var iconPickerTarget: PlacedAccessory?
    @State private var showFloorplanDiagnostics = false
    @State private var editHighlightedRoomID: UUID?
    @State private var suppressNextMarkerTapID: UUID?
    @State private var executingMarkerID: UUID?
    
    // Zoom & pan state
    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomOffset: CGSize = .zero
    @State private var liveScale: CGFloat = 1.0
    @State private var liveOffset: CGSize = .zero
    
    // Auto-hide controls
    @State private var controlsVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    
    @Environment(HomeKitScenesService.self) private var scenesService
    @State private var showScenesPanel = false

    @Query(sort: \Floorplan.createdAt, order: .reverse) private var allFloorplans: [Floorplan]

    @AppStorage("primaryFloorplanID") private var primaryFloorplanID: String = ""
    @AppStorage("pinnedFloorplanIDs") private var pinnedFloorplanIDsRaw: String = "[]"

    /// Overlay layer view model — scoped to this editor instance, keyed to the floorplan UUID.
    @State private var overlayVM: FloorplanOverlayViewModel?
    /// Shared environment view model used by both the overlay layer and the context panel.
    @State private var overlayEnvVM = EnvironmentViewModel()

    /// Cached floorplan image — loaded once on appear and when imageFilename changes.
    /// Avoids repeated disk I/O on every body re-evaluation.
    @State private var cachedFloorplanImage: UIImage?
    @State private var cachedFloorplanImageFilename: String = ""
    /// True while the image is being loaded from disk — prevents the "not available" state flash.
    @State private var isLoadingImage: Bool = false

    /// Cached overlay context — recomputed only when HomeKit accessories change.
    @State private var cachedOverlayContext: FloorplanOverlayContext = .none

    /// Timestamp (seconds since epoch) when the security mode was last observed to change.
    @AppStorage("securityModeActivationDate") private var securityModeActivationDate: Double = 0

    /// Last known security mode raw value — used to detect mode changes.
    @State private var lastKnownSecurityModeRaw: Int = -1

    /// Altezza misurata della top bar (incluse pills secondarie).
    /// Usata per tenere l'immagine al di sotto della barra.
    @State private var topBarHeight: CGFloat = 0

    private var selectedMarker: PlacedAccessory? {
        guard let id = selectedMarkerID else { return nil }
        return floorplan.accessories.first { $0.id == id }
    }

    private var duplicatedMarkerAccessoryIDs: Set<UUID> {
        let counts = Dictionary(grouping: floorplan.accessories, by: \.homeKitAccessoryUUID)
        return Set(counts.compactMap { accessoryID, markers in
            markers.count > 1 ? accessoryID : nil
        })
    }

    private var accessoryPickerTitle: String {
        guard let pickerRoomFilter,
              let room = floorplan.linkedRooms.first(where: { $0.hmRoomUUID == pickerRoomFilter }) else {
            return "Aggiungi accessori"
        }
        return "Aggiungi in \(room.name)"
    }

    private var availableFloorplans: [Floorplan] {
        guard let homeUUID = homeKit.currentHome?.uniqueIdentifier else {
            return allFloorplans
        }
        return allFloorplans.filter { $0.homeUUID == nil || $0.homeUUID == homeUUID }
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

    private func buildOverlayContext() -> FloorplanOverlayContext {
        let hasEnv = !floorplan.linkedRooms.isEmpty
        let hasSecure = homeKit.allAccessories.contains { acc in
            acc.services.contains { svc in
                svc.serviceType == HMServiceTypeLockMechanism
                    || svc.serviceType == HMServiceTypeSecuritySystem
                    || svc.serviceType == HMServiceTypeGarageDoorOpener
                    || svc.serviceType == HMServiceTypeDoorbell
            }
        }
        return FloorplanOverlayContext(
            hasEnvironmentData: hasEnv,
            hasSecurityDevices: hasSecure,
            hasAIService: isAIEnabled
        )
    }

    private func refreshOverlayContext() {
        let context = buildOverlayContext()
        cachedOverlayContext = context

        if let vm = overlayVM,
           !vm.activeMode.isAvailable(in: context) {
            vm.activeMode = .controls
        }
    }
    
    private var effectiveScale: CGFloat {
        zoomScale * liveScale
    }
    
    private var effectiveOffset: CGSize {
        CGSize(width: zoomOffset.width + liveOffset.width,
               height: zoomOffset.height + liveOffset.height)
    }
    
    private var shouldShowControls: Bool {
        isEditing || controlsVisible
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white
                    .ignoresSafeArea()

                if let image = cachedFloorplanImage {
                    imageWithMarkers(image: image, container: proxy.size)
                        .scaleEffect(effectiveScale, anchor: .center)
                        // Sposta l'immagine verso il basso di metà dell'altezza della top bar,
                        // così risulta centrata nello spazio libero sotto la barra.
                        .offset(CGSize(
                            width:  effectiveOffset.width,
                            height: effectiveOffset.height + topBarHeight / 2
                        ))
                        .gesture(zoomPanGesture(in: proxy.size))
                        .transition(.opacity)
                } else if isLoadingImage {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Immagine non disponibile",
                        systemImage: "photo.badge.exclamationmark"
                    )
                }
                
                // Top bar: sempre visibile
                topBar(in: proxy.size)

                // Controlli secondari (zoom, toolbar marker): soggetti ad auto-hide
                secondaryControls(in: proxy.size)
                    .opacity(shouldShowControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: shouldShowControls)

                // Pulsante apri-pannello — sempre visibile (non soggetto ad auto-hide)
                openPanelButton

                // Right-side scenes panel overlay
                if showScenesPanel {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                showScenesPanel = false
                            }
                        }
                        .transition(.opacity)
                }

                HStack(spacing: 0) {
                    Spacer()
                    ScenesSidePanel(isPresented: $showScenesPanel)
                        .frame(width: min(proxy.size.width * 0.72, 320))
                        .offset(x: showScenesPanel ? 0 : min(proxy.size.width * 0.72, 320) + 20)
                        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: showScenesPanel)
                }
                .ignoresSafeArea(edges: .vertical)

                // Z+4: overlay context panel
                if let vm = overlayVM {
                    overlayContextPanel(vm: vm, containerSize: proxy.size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                handleBackgroundTap(at: location, in: proxy.size)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingPicker, onDismiss: {
            pickerRoomFilter = nil
            pendingMarkerPosition = nil
            editHighlightedRoomID = nil
        }) {
            AccessoryPickerSheet(
                alreadyPlaced: Set(floorplan.accessories.map(\.homeKitAccessoryUUID)),
                preferredRoomUUIDs: pickerRoomFilter != nil
                    ? Set([pickerRoomFilter!])
                    : Set(floorplan.linkedRooms.map(\.hmRoomUUID)),
                title: accessoryPickerTitle,
                onPick: { accessories in
                    for accessory in accessories {
                        addAccessory(accessory, at: pendingMarkerPosition)
                    }
                }
            )
        }
        .sheet(item: $controllingAccessory) { accessory in
            AccessoryDetailView(accessory: accessory)
        }
        .sheet(item: $iconPickerTarget) { placed in
            if let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID) {
                let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
                IconPickerSheet(
                    accessory: accessory,
                    defaultIconName: adapter.iconName
                )
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showFloorplanDiagnostics) {
            FloorplanDiagnosticsView(
                report: FloorplanHealthAnalyzer.analyze(floorplan: floorplan, homeKit: homeKit),
                onAddAccessories: startAssistedPlacement
            )
        }
        
        
        .alert("Eliminare l'accessorio dal floorplan?",
               isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
               ),
               presenting: pendingDelete) { placed in
            Button("Elimina", role: .destructive) {
                deleteMarker(placed)
            }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text("L'accessorio verrà rimosso dalla planimetria ma resterà attivo in HomeKit.")
        }
        .onAppear {
            // Initialise the overlay VM once so it's keyed to the real floorplan UUID.
            if overlayVM == nil {
                overlayVM = FloorplanOverlayViewModel(floorplanID: floorplan.id)
            }
            overlayEnvVM.configure(modelContainer: modelContext.container)
            overlayEnvVM.loadFromCoreData()
            subscribeToAccessories()
            restoreZoom()
            if startInEditMode {
                isEditing = true
                controlsVisible = true
                hideTask?.cancel()
            } else {
                scheduleAutoHide()
            }
            // Warm up caches
            refreshFloorplanImageCache()
            backfillMarkerRoomLinksIfNeeded()
            refreshOverlayContext()
        }
        .onChange(of: homeKit.isReady) { _, isReady in
            if isReady {
                subscribeToAccessories()
                refreshOverlayContext()
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
        .onChange(of: habitService.pendingPatterns.count) { _, _ in
            refreshOverlayContext()
        }
        .onChange(of: habitService.isAnalyzing) { _, _ in
            refreshOverlayContext()
        }
        .onChange(of: isAIEnabled) { _, _ in
            refreshOverlayContext()
        }
        .onChange(of: floorplan.imageFilename) { _, _ in
            refreshFloorplanImageCache()
        }
        .onDisappear {
            unsubscribeFromAccessories()
            hideTask?.cancel()
        }
        .onChange(of: floorplan.accessories.count) { _, _ in
            subscribeToAccessories()
        }
        .onChange(of: isEditing) { _, newValue in
            if newValue {
                controlsVisible = true
                hideTask?.cancel()
            } else {
                scheduleAutoHide()
            }
        }
        .onChange(of: homeKit.allAccessories) { _, _ in
            trackSecurityModeChange()
        }
        .onAppear {
            trackSecurityModeChange()
        }
    }

    /// Checks if the security system mode has changed and records the activation timestamp.
    private func trackSecurityModeChange() {
        guard let home = homeKit.currentHome else { return }
        for acc in home.accessories {
            if let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? SecuritySystemAdapter {
                let raw = adapter.currentMode.rawValue
                if raw != lastKnownSecurityModeRaw {
                    lastKnownSecurityModeRaw = raw
                    securityModeActivationDate = Date().timeIntervalSince1970
                }
                break
            }
        }
    }

    /// Returns the first SecuritySystemAdapter in the current home, if any.
    private func findSecurityAdapter() -> SecuritySystemAdapter? {
        guard let home = homeKit.currentHome else { return nil }
        for acc in home.accessories {
            if let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit) as? SecuritySystemAdapter {
                return adapter
            }
        }
        return nil
    }
    
    // MARK: - Top bar (sempre visibile)

    @ViewBuilder
    private func topBar(in size: CGSize) -> some View {
        // VStack senza Spacer: si restringe all'altezza reale del contenuto.
        // Il Spacer esterno (nello ZStack) non è necessario perché la top bar
        // è allineata al top dello ZStack per natura.
        VStack(spacing: 0) {
            ZStack {
                // Pill — centrata rispetto alla larghezza totale della barra,
                // indipendente dai pesi dei gruppi laterali.
                if !isEditing, let vm = overlayVM {
                    FloorplanModePill(overlayVM: vm, context: cachedOverlayContext)
                }

                // Sinistra e destra sovrapposti: non influenzano il centro della pill.
                HStack {
                    // Sinistra: sidebar / dismiss + nome floorplan
                    HStack(spacing: 10) {
                        switch presentationStyle {
                        case .splitView:
                            if columnVisibility == .detailOnly {
                                Button {
                                    withAnimation(.spring(response: 0.4)) {
                                        columnVisibility = .all
                                    }
                                } label: {
                                    GlassCircle(size: 40) {
                                        Image(systemName: "sidebar.left")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(.primary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .transition(.scale.combined(with: .opacity))
                            }
                        case .pushed:
                            Button {
                                dismiss()
                            } label: {
                                GlassCircle(size: 40) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.red)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        floorplanTitleMenu
                    }

                    Spacer()

                    // Destra: azioni (+ / scene / modifica)
                    topRightActions(in: size)
                }
            }
            .animation(.spring(response: 0.4), value: columnVisibility)
            .animation(.spring(response: 0.35), value: isEditing)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            // Sub-filter bar: visible only in Environment mode (not in edit mode)
            if !isEditing, let vm = overlayVM, vm.activeMode == .environment {
                EnvironmentFilterBar(
                    overlayVM: vm,
                    availableTypes: overlayEnvVM.availableSensorTypes
                )
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Security alarm status pill: visible only in Security mode (not in edit mode)
            if !isEditing, let vm = overlayVM, vm.activeMode == .security,
               let adapter = findSecurityAdapter() {
                AlarmStatusPill(
                    adapter: adapter,
                    activationDate: securityModeActivationDate > 0
                        ? Date(timeIntervalSince1970: securityModeActivationDate)
                        : nil
                )
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isEditing {
                editModeBanner
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Hint banner: stanze non collegate → layer Ambiente non disponibile
            if !isEditing && floorplan.linkedRooms.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(String(localized: "floorplan.editor.banner.noRooms",
                                defaultValue: "No rooms linked — open the 2D editor (✏️) to draw the areas and unlock the Environment layer."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Padding inferiore per separare visivamente la barra dal canvas
            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.spring(response: 0.35), value: overlayVM?.activeMode)
        .animation(.spring(response: 0.35), value: floorplan.linkedRooms.isEmpty)
        // Misura l'altezza reale della top bar (senza Spacer espanso)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TopBarHeightKey.self,
                    value: geo.size.height
                )
            }
        )
        .onPreferenceChange(TopBarHeightKey.self) { topBarHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var editModeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil.and.outline")
                .font(.caption.weight(.semibold))
                .foregroundStyle(BrandColor.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Modifica planimetria")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Tocca una stanza per aggiungere lì. Usa + per aggiunta libera.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            Button {
                showFloorplanDiagnostics = true
            } label: {
                Image(systemName: "checklist")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stato planimetria")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.horizontal, 20)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(BrandColor.primary.opacity(0.18), lineWidth: 1)
        )
    }

    private var floorplanTitleMenu: some View {
        Menu {
            if pinnedFloorplans.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.4)) {
                        columnVisibility = .all
                    }
                } label: {
                    Label("Apri sidebar", systemImage: "sidebar.left")
                }
            } else {
                Section("Accesso rapido") {
                    ForEach(pinnedFloorplans) { item in
                        Button {
                            guard item.id != floorplan.id else { return }
                            onSelectFloorplan?(item.id)
                        } label: {
                            Label {
                                HStack {
                                    Text(item.name)
                                    if item.id == floorplan.id {
                                        Text("Attuale")
                                    }
                                }
                            } icon: {
                                Image(systemName: titleMenuIcon(for: item))
                            }
                        }
                        .disabled(item.id == floorplan.id || onSelectFloorplan == nil)
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.4)) {
                        columnVisibility = .all
                    }
                } label: {
                    Label("Mostra sidebar", systemImage: "sidebar.left")
                }
            }
        } label: {
            GlassTitlePill {
                HStack(spacing: 8) {
                    Text(floorplan.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }

    private func titleMenuIcon(for item: Floorplan) -> String {
        if item.id == floorplan.id {
            return "checkmark.circle.fill"
        }
        if item.id.uuidString == primaryFloorplanID {
            return "star.square.fill"
        }
        return "pin.circle.fill"
    }

    // MARK: - Controlli secondari (auto-hide)

    @ViewBuilder
    private func secondaryControls(in size: CGSize) -> some View {
        // Bottom-right: zoom indicator
        VStack {
            Spacer()
            HStack(alignment: .bottom) {
                Spacer()
                VStack(spacing: 10) {
                    // Zoom indicator (only when zoomed in)
                    if effectiveScale > 1.01 {
                        GlassTitlePill {
                            HStack(spacing: 8) {
                                Text(String(format: "%.1f×", effectiveScale))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                                Divider().frame(height: 20)
                                Button {
                                    resetZoom()
                                } label: {
                                    Image(systemName: "1.magnifyingglass")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: overlayVM?.isPanelVisible)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: overlayVM?.activeMode)

        // Bottom-center: toolbar contestuale per marker selezionato (solo Edit)
        if isEditing, let placed = selectedMarker {
            let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID)
            let displayName = placed.customLabel?.isEmpty == false
                ? placed.customLabel!
                : (accessory?.name ?? "(rimosso)")

            VStack {
                Spacer()
                MarkerActionToolbar(
                    markerName: displayName,
                    initialRenameText: placed.customLabel ?? "",
                    onRename: { newLabel in
                        applyRename(to: placed, newLabel: newLabel)
                    },
                    onResetName: {
                        applyRename(to: placed, newLabel: "")
                    },
                    onRecenter: {
                        recenterMarker(placed)
                    },
                    onDelete: {
                        pendingDelete = placed
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.35)) {
                            selectedMarkerID = nil
                        }
                    },
                    onChangeIcon: {
                        iconPickerTarget = placed
                    }
                )
                .padding(.bottom, 20)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: selectedMarkerID)
        }
    }
    
    // MARK: - Pulsante apri pannello (sempre visibile, non soggetto ad auto-hide)

    /// Bottone bottom-right che apre il pannello contestuale.
    /// Vive in un proprio layer ZStack così non scompare con l'auto-hide dei controlli secondari.
    @ViewBuilder
    private var openPanelButton: some View {
        if !isEditing, let vm = overlayVM,
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

    @ViewBuilder
    private func topRightActions(in size: CGSize) -> some View {
        // Nascondi la pill quando si è in un overlay non-Controlli (Ambiente / Sicurezza / …)
        // a meno che non si stia già modificando (uscire dall'edit deve essere sempre possibile).
        let inOverlayMode = (overlayVM?.activeMode ?? .controls) != .controls
        let hideEditButton = inOverlayMode && !isEditing
        let showSceneText = size.width >= 760

        GlassTitlePill {
            HStack(spacing: 0) {
                // Bottone + solo in edit mode
                if isEditing {
                    Button {
                        pickerRoomFilter = nil
                        pendingMarkerPosition = nil
                        editHighlightedRoomID = nil
                        showingPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Aggiungi accessorio")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    Divider().frame(height: 20)
                        .transition(.opacity)
                }

                // Scene: visibile solo in modalità Controlli o in editing
                if !hideEditButton {
                    Button {
                        showFloorplanDiagnostics = true
                    } label: {
                        Image(systemName: "checklist")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().frame(height: 20)

                    Button {
                        showScenesPanel = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.rectangle.on.rectangle")
                            if showSceneText {
                                Text("Scene")
                            }
                        }
                        .font(.subheadline)
                        .fontWeight(showSceneText ? .medium : .regular)
                        .padding(.horizontal, showSceneText ? 14 : 13)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scene")
                    .help("Apri scene")

                    Divider().frame(height: 20)
                }

                // Bottone Modifica/Fine: nascosto negli overlay non-Controlli
                if !hideEditButton {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            isEditing.toggle()
                            suppressNextMarkerTapID = nil
                            executingMarkerID = nil
                            if !isEditing {
                                selectedMarkerID = nil
                                editHighlightedRoomID = nil
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isEditing ? "checkmark" : "pencil")
                            Text(isEditing ? "Fine" : "Modifica")
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(isEditing ? BrandColor.primary : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .opacity(hideEditButton ? 0 : 1)
        .allowsHitTesting(!hideEditButton)
        .animation(.easeInOut(duration: 0.2), value: hideEditButton)
    }
    
    // MARK: - Auto-hide
    
    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard !isEditing else {
            controlsVisible = true
            return
        }
        controlsVisible = true
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled, !isEditing {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        controlsVisible = false
                    }
                }
            }
        }
    }
    
    private func handleBackgroundTap(at tapLocation: CGPoint, in containerSize: CGSize) {
        // 1. Deselect marker in edit mode
        if isEditing && selectedMarkerID != nil {
            withAnimation(.spring(response: 0.35)) {
                selectedMarkerID = nil
            }
            return
        }

        // 2. Not editing: show controls
        if !isEditing {
            withAnimation(.easeInOut(duration: 0.25)) {
                controlsVisible = true
            }
            scheduleAutoHide()
            return
        }

        // 3. Editing + has linked room areas: detect which area was tapped
        guard !floorplan.linkedRooms.isEmpty else { return }

        // Reverse the zoom/pan transform (scaleEffect anchor: .center, then offset).
        // The rendered image is additionally shifted by topBarHeight / 2 to stay centered
        // below the top bar, so the inverse transform must subtract the same visual offset.
        let centerX = containerSize.width / 2
        let centerY = containerSize.height / 2
        let adjustedX = (tapLocation.x - centerX - effectiveOffset.width) / effectiveScale + centerX
        let visualYOffset = effectiveOffset.height + topBarHeight / 2
        let adjustedY = (tapLocation.y - centerY - visualYOffset) / effectiveScale + centerY

        // Compute the content rect from the cached image to avoid disk I/O on every tap.
        guard let image = cachedFloorplanImage else { return }
        let imgRect = imageRect(imageSize: image.size, container: containerSize)
        let helper = FloorplanCoordinateHelper(imageRect: imgRect)

        // Normalize to [0, 1] within the content rect
        let normX = (adjustedX - imgRect.origin.x) / imgRect.width
        let normY = (adjustedY - imgRect.origin.y) / imgRect.height
        guard normX >= 0, normX <= 1, normY >= 0, normY <= 1 else { return }

        pendingMarkerPosition = NormalizedPoint(x: normX, y: normY)

        // Hit-test linked room areas
        let tappedRoom = floorplan.linkedRooms.first { room in
            helper.overlayPath(for: room).contains(CGPoint(x: adjustedX, y: adjustedY))
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            editHighlightedRoomID = tappedRoom?.hmRoomUUID
        }
        pickerRoomFilter = tappedRoom?.hmRoomUUID

        showingPicker = true
    }
    
    // MARK: - Zoom & pan

    private func zoomPanGesture(in container: CGSize) -> some Gesture {
        let magnify = MagnificationGesture()
            .onChanged { value in
                liveScale = value
            }
            .onEnded { value in
                zoomScale = clampedScale(zoomScale * value)
                liveScale = 1.0
                if zoomScale <= 1.01 {
                    withAnimation(.spring(response: 0.4)) {
                        zoomScale = 1.0
                        zoomOffset = .zero
                    }
                }
                saveZoom()
            }

        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard effectiveScale > 1.01 else { return }
                liveOffset = value.translation
            }
            .onEnded { value in
                guard zoomScale > 1.01 else {
                    liveOffset = .zero
                    return
                }
                zoomOffset = CGSize(
                    width: zoomOffset.width + value.translation.width,
                    height: zoomOffset.height + value.translation.height
                )
                liveOffset = .zero
                clampOffset(in: container)
                saveZoom()
            }

        return magnify.simultaneously(with: drag)
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1.0), 4.0)
    }

    private func clampOffset(in container: CGSize) {
        let extraW = container.width * (zoomScale - 1) / 2
        let extraH = container.height * (zoomScale - 1) / 2
        let maxX = max(0, extraW)
        let maxY = max(0, extraH)

        let clampedX = min(maxX, max(-maxX, zoomOffset.width))
        let clampedY = min(maxY, max(-maxY, zoomOffset.height))

        if clampedX != zoomOffset.width || clampedY != zoomOffset.height {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                zoomOffset = CGSize(width: clampedX, height: clampedY)
            }
        }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            zoomScale = 1.0
            zoomOffset = .zero
            liveScale = 1.0
            liveOffset = .zero
        }
        saveZoom()
    }

    // MARK: - Zoom persistence

    /// UserDefaults keys are scoped to the floorplan UUID so each
    /// planimetria remembers its own zoom and pan state independently.
    private var zoomScaleKey:   String { "zoom_scale_\(floorplan.id.uuidString)" }
    private var zoomOffsetXKey: String { "zoom_offsetX_\(floorplan.id.uuidString)" }
    private var zoomOffsetYKey: String { "zoom_offsetY_\(floorplan.id.uuidString)" }

    private func saveZoom() {
        let ud = UserDefaults.standard
        ud.set(Double(zoomScale),        forKey: zoomScaleKey)
        ud.set(Double(zoomOffset.width), forKey: zoomOffsetXKey)
        ud.set(Double(zoomOffset.height),forKey: zoomOffsetYKey)
    }

    private func refreshFloorplanImageCache() {
        guard floorplan.imageFilename != cachedFloorplanImageFilename
                || cachedFloorplanImage == nil else { return }
        let filename = floorplan.imageFilename
        cachedFloorplanImageFilename = filename
        guard !filename.isEmpty else { return }
        isLoadingImage = true
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                ImageStorageService.load(filename: filename)
            }.value
            withAnimation(.easeIn(duration: 0.2)) {
                cachedFloorplanImage = image
                isLoadingImage = false
            }
        }
    }

    private func restoreZoom() {
        let ud = UserDefaults.standard
        guard ud.object(forKey: zoomScaleKey) != nil else { return }
        // Disable animations so the zoom/offset snap to the saved state without animating
        // from the default values (scale 1.0, offset .zero).
        withTransaction(Transaction(animation: nil)) {
            zoomScale  = CGFloat(ud.double(forKey: zoomScaleKey))
            zoomOffset = CGSize(
                width:  CGFloat(ud.double(forKey: zoomOffsetXKey)),
                height: CGFloat(ud.double(forKey: zoomOffsetYKey))
            )
        }
    }
    
    // MARK: - Image rect
    
    private func imageRect(imageSize: CGSize, container: CGSize) -> CGRect {
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        var size = container
        if imageAspect > containerAspect {
            size.height = container.width / imageAspect
        } else {
            size.width = container.height * imageAspect
        }
        let origin = CGPoint(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }
    
    private func imageWithMarkers(image: UIImage, container: CGSize) -> some View {
        let rect = imageRect(imageSize: image.size, container: container)
        return ZStack(alignment: .topLeading) {
            Color.clear

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // Z+2: overlay layer (environment / security / intelligence)
            if let vm = overlayVM, !isEditing {
                overlayLayer(vm: vm, container: container, imageRect: rect)
            }

            if isEditing, !floorplan.linkedRooms.isEmpty {
                editRoomInteractionLayer(container: container, imageRect: rect)
            }

            // Marker accessori: visibili solo in modalità Controlli (o in modifica).
            // Transizione opacity per evitare un salto brusco al cambio modalità.
            let showMarkers = isEditing || (overlayVM?.activeMode == .controls)
            Group {
                if showMarkers {
                    ForEach(floorplan.accessories) { placed in
                        markerView(for: placed, in: rect)
                    }
                    if floorplan.accessories.isEmpty {
                        emptyMarkersHint
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showMarkers)
        }
        .frame(width: container.width, height: container.height)
    }

    private func editRoomInteractionLayer(container: CGSize, imageRect: CGRect) -> some View {
        let helper = FloorplanCoordinateHelper(imageRect: imageRect)

        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for room in floorplan.linkedRooms {
                    let path = helper.overlayPath(for: room)
                    let isHighlighted = room.hmRoomUUID == editHighlightedRoomID
                    let fill = isHighlighted
                        ? BrandColor.primary.opacity(0.18)
                        : BrandColor.primary.opacity(0.055)
                    let stroke = isHighlighted
                        ? BrandColor.primary.opacity(0.72)
                        : BrandColor.primary.opacity(0.24)

                    ctx.fill(path, with: .color(fill))
                    ctx.stroke(
                        path,
                        with: .color(stroke),
                        style: StrokeStyle(lineWidth: isHighlighted ? 2.0 : 1.0, dash: [6, 5])
                    )
                }
            }
            .frame(width: container.width, height: container.height)
            .allowsHitTesting(false)

            ForEach(floorplan.linkedRooms, id: \.hmRoomUUID) { room in
                let center = helper.centroid(for: room)
                let isHighlighted = room.hmRoomUUID == editHighlightedRoomID

                Text(room.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(isHighlighted ? .white : BrandColor.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isHighlighted ? BrandColor.primary.opacity(0.92) : Color(.systemBackground).opacity(0.78))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(BrandColor.primary.opacity(isHighlighted ? 0.0 : 0.24), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .position(center)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: container.width, height: container.height)
    }

    // MARK: - Overlay context panel

    @ViewBuilder
    private func overlayContextPanel(vm: FloorplanOverlayViewModel, containerSize: CGSize) -> some View {
        let mode = vm.activeMode

        FloorplanContextPanelContainer(
            overlayVM: vm,
            containerWidth: containerSize.width,
            title: panelTitle(for: mode),
            accentColor: mode.accentColor
        ) {
            VStack(spacing: 14) {
                if mode == .intelligence, !habitService.pendingPatterns.isEmpty {
                    floorplanOverviewCard(for: mode)
                }

                switch mode {
                case .controls:
                    EmptyView()
                case .environment:
                    EnvironmentContextDashboard(
                        envVM: overlayEnvVM,
                        overlayVM: vm,
                        highlightedRoomID: vm.highlightedRoomID,
                        linkedRooms: floorplan.linkedRooms
                    )
                case .security:
                    SecurityContextDashboard(
                        highlightedRoomID: vm.highlightedRoomID,
                        linkedRooms: floorplan.linkedRooms
                    )
                case .intelligence:
                    IntelligenceContextDashboard(
                        highlightedRoomID: vm.highlightedRoomID,
                        linkedRooms: floorplan.linkedRooms
                    )
                }
            }
            .padding(.top, mode == .intelligence ? 36 : 0)
        }
    }

    private func floorplanOverviewCard(for mode: FloorplanOverlayMode) -> some View {
        let health = FloorplanHealthAnalyzer.analyze(floorplan: floorplan, homeKit: homeKit)
        let attentionRoomList = overlayEnvVM.rooms
            .filter { $0.worstUrgency != .normal }
            .sorted {
                if $0.worstUrgency != $1.worstUrgency { return $0.worstUrgency > $1.worstUrgency }
                return $0.roomName < $1.roomName
            }
        let attentionRooms = attentionRoomList.count
        let topEnvironmentRoom = attentionRoomList.first
        let suggestions = habitService.pendingPatterns.count
        let issueCount = health.criticalCount + health.warningCount
        let securityDeviceCount = homeKit.allAccessories.filter { accessory in
            accessory.services.contains { service in
                service.serviceType == HMServiceTypeLockMechanism ||
                    service.serviceType == HMServiceTypeSecuritySystem ||
                    service.serviceType == HMServiceTypeGarageDoorOpener ||
                    service.serviceType == HMServiceTypeDoorbell
            }
        }.count

        let color: Color
        let icon: String
        if mode == .environment, topEnvironmentRoom?.worstUrgency == .danger {
            color = .red
            icon = "exclamationmark.triangle.fill"
        } else if mode == .security, securityDeviceCount == 0 {
            color = .orange
            icon = "lock.shield"
        } else if mode == .intelligence, suggestions > 0 {
            color = .orange
            icon = "sparkles"
        } else if issueCount > 0 {
            color = .orange
            icon = "checklist"
        } else if attentionRooms > 0 || health.criticalCount > 0 {
            color = .red
            icon = "house.and.flag.fill"
        } else {
            color = .green
            icon = "checkmark.seal.fill"
        }

        let title: String = {
            switch mode {
            case .environment:
                if let room = topEnvironmentRoom {
                    return "\(room.roomName) da controllare"
                }
                return "Ambiente stabile"
            case .security:
                if securityDeviceCount == 0 {
                    return "Configura la sicurezza"
                }
                return "Sicurezza disponibile"
            case .intelligence:
                if suggestions > 0 {
                    return suggestions == 1 ? "Un suggerimento pronto" : "\(suggestions) suggerimenti pronti"
                }
                return "Intelligenza in apprendimento"
            case .controls:
                if issueCount > 0 {
                    return "Completa la planimetria"
                }
                return "Floorplan pronto"
            }
        }()

        let message: String = {
            switch mode {
            case .environment:
                if let room = topEnvironmentRoom {
                    let level = room.worstUrgency == .danger ? "critica" : "da monitorare"
                    return "Priorità \(level): guarda le card sotto per valori, spiegazione AI e azioni disponibili."
                }
                return "Nessuna stanza è fuori soglia: puoi usare questo pannello per controllare il riepilogo ambientale."
            case .security:
                if securityDeviceCount == 0 {
                    return "Aggiungi serrature, sensori o allarme HomeKit per vedere stato e priorità sicurezza qui."
                }
                return "Usa le card sotto per controllare stato sistema, sensori monitorati e stanze evidenziate."
            case .intelligence:
                if suggestions > 0 {
                    return "Valuta le raccomandazioni sotto: puoi approvarle o ignorarle direttamente da questo pannello."
                }
                return "Non ci sono azioni pronte: la casa continua a raccogliere pattern e mostrerà opportunità affidabili qui."
            case .controls:
                if issueCount > 0 {
                    return "Apri la diagnostica con l'icona checklist per vedere cosa manca o cosa non torna."
                }
                return "Marker e stanze sono pronti: usa la pill centrale per passare agli overlay operativi."
            }
        }()

        return FloorplanStatusSummaryCard(
            title: title,
            message: message,
            icon: icon,
            color: color,
            metrics: [
                FloorplanStatusMetric(value: "\(attentionRooms)", label: "Da controllare"),
                FloorplanStatusMetric(value: "\(suggestions)", label: "Suggerimenti"),
                FloorplanStatusMetric(value: "\(health.linkableUnplacedCount)", label: "Da piazzare")
            ]
        )
    }

    private func panelTitle(for mode: FloorplanOverlayMode) -> String {
        switch mode {
        case .controls:     return ""
        case .environment:  return "Ambiente"
        case .security:     return "Sicurezza"
        case .intelligence: return "Intelligenza"
        }
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

    private var emptyMarkersHint: some View {
        let hasAreas = !floorplan.linkedRooms.isEmpty
        return VStack(spacing: 14) {
            Image(systemName: hasAreas ? "rectangle.dashed.badge.plus" : "plus.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Nessun accessorio piazzato")
                .font(.headline)

            if hasAreas {
                Text("Tocca un'area stanza sulla planimetria per aggiungere il primo accessorio HomeKit.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text("Tap su + in alto a destra per aggiungere il primo accessorio HomeKit sulla planimetria.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // Hint: stanze linkate abilitano il layer Ambiente
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.top, 1)
                    Text(String(localized: "floorplan.editor.hint.ambiente",
                                defaultValue: "Draw room areas (pencil → Room Area) and link them to HomeKit to unlock the **Environment** layer."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.08))
                )
                .padding(.horizontal, 4)

                Button {
                    pickerRoomFilter = nil
                    pendingMarkerPosition = nil
                    showingPicker = true
                } label: {
                    Label("Aggiungi accessorio", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(.tint)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
    }
    
    // MARK: - Marker
    
    @ViewBuilder
    private func markerView(for placed: PlacedAccessory, in imageRect: CGRect) -> some View {
        let accessory = homeKit.accessory(for: placed.homeKitAccessoryUUID)
        let displayLabel: String = {
            if let custom = placed.customLabel, !custom.isEmpty { return custom }
            guard let accessory else { return "(rimosso)" }
            let fullName = accessory.name
            if let roomName = accessory.room?.name {
                // Suffisso: "Faretti Cucina" → rimuovi " Cucina"
                let suffix = " " + roomName
                if fullName.hasSuffix(suffix) {
                    return String(fullName.dropLast(suffix.count))
                }
                // Prefisso con trattino: "Cucina - Faretti" → rimuovi "Cucina - "
                let prefix = roomName + " - "
                if fullName.hasPrefix(prefix) {
                    return String(fullName.dropFirst(prefix.count))
                }
            }
            return fullName
        }()
        let adapter: (any AccessoryAdapter)? = accessory.map { acc in
            AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
        }
        let isSelected = selectedMarkerID == placed.id
        
        let basePoint = CGPoint(
            x: imageRect.origin.x + placed.position.x * imageRect.width,
            y: imageRect.origin.y + placed.position.y * imageRect.height
        )
        let delta = dragDeltas[placed.id] ?? .zero
        let livePoint = CGPoint(x: basePoint.x + delta.width,
                                y: basePoint.y + delta.height)
        let collisionOffset = markerCollisionOffset(for: placed, in: imageRect)
        let displayPoint = CGPoint(
            x: livePoint.x + collisionOffset.width,
            y: livePoint.y + collisionOffset.height
        )
        let shaking = shakeMarkerID == placed.id
        
        let inverseScale = 1.0 / effectiveScale
        let editIssue = markerEditIssue(for: placed, accessory: accessory)
        
        AccessoryMarkerView(
            adapter: adapter,
            isEditing: isEditing,
            isSelected: isEditing && isSelected,
            isExecuting: executingMarkerID == placed.id,
            editIssue: editIssue,
            label: displayLabel,
            hasCustomLabel: placed.customLabel?.isEmpty == false
        )
        .scaleEffect(inverseScale)
        .position(displayPoint)
        .offset(x: shaking ? 6 : 0)
        .animation(shaking ? .default.repeatCount(3, autoreverses: true).speed(8) : .default,
                   value: shaking)
        .animation(.spring(response: 0.3), value: isSelected)
        .simultaneousGesture(
            isEditing
            ? nil
            : LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    if let accessory {
                        suppressNextMarkerTapID = placed.id
                        controllingAccessory = accessory
                    }
                }
        )
        .simultaneousGesture(
            isEditing
            ? nil
            : TapGesture()
                .onEnded {
                    handleTap(on: placed, accessory: accessory, adapter: adapter)
                }
        )
        .simultaneousGesture(
            isEditing
            ? TapGesture()
                .onEnded {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        selectedMarkerID = (selectedMarkerID == placed.id) ? nil : placed.id
                    }
                }
            : nil
        )
        .gesture(
            isEditing ? dragGesture(for: placed, imageRect: imageRect) : nil
        )
    }

    private func markerEditIssue(for placed: PlacedAccessory,
                                 accessory: HMAccessory?) -> AccessoryMarkerEditIssue? {
        guard isEditing else { return nil }

        if accessory == nil {
            return .missingHomeKitAccessory
        }

        if duplicatedMarkerAccessoryIDs.contains(placed.homeKitAccessoryUUID) {
            return .duplicateMarker
        }

        guard !floorplan.linkedRooms.isEmpty else { return nil }

        let containingRoomID = FloorplanRoomMatcher.linkedRoomID(
            containing: placed.position,
            in: floorplan.linkedRooms
        )

        guard let containingRoomID else {
            return .outsideLinkedRoom
        }

        if placed.linkedRoomUUID != containingRoomID {
            return .roomLinkMismatch
        }

        return nil
    }

    private func markerCollisionOffset(for placed: PlacedAccessory,
                                       in imageRect: CGRect) -> CGSize {
        guard !isEditing, floorplan.accessories.count > 1 else { return .zero }

        let scale = max(effectiveScale, 0.01)
        let threshold = 32 / scale
        let basePoint = CGPoint(
            x: imageRect.origin.x + placed.position.x * imageRect.width,
            y: imageRect.origin.y + placed.position.y * imageRect.height
        )

        let nearbyMarkers = floorplan.accessories
            .filter { candidate in
                let candidatePoint = CGPoint(
                    x: imageRect.origin.x + candidate.position.x * imageRect.width,
                    y: imageRect.origin.y + candidate.position.y * imageRect.height
                )
                return hypot(candidatePoint.x - basePoint.x, candidatePoint.y - basePoint.y) <= threshold
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }

        guard nearbyMarkers.count > 1,
              let index = nearbyMarkers.firstIndex(where: { $0.id == placed.id }) else {
            return .zero
        }

        let count = CGFloat(nearbyMarkers.count)
        let angle = (2 * CGFloat.pi * CGFloat(index) / count) - (.pi / 2)
        let radius = min(24, 10 + count * 3) / scale

        return CGSize(
            width: cos(angle) * radius,
            height: sin(angle) * radius
        )
    }
    
    // MARK: - Tap handling
    
    private func handleTap(on placed: PlacedAccessory,
                           accessory: HMAccessory?,
                           adapter: (any AccessoryAdapter)?) {
        guard !isEditing else { return }
        guard let accessory else { return }

        if suppressNextMarkerTapID == placed.id {
            suppressNextMarkerTapID = nil
            return
        }

        scheduleAutoHide()

        // Tap: toggle diretto se supportato, altrimenti apre il pannello dettaglio.
        if let adapter, adapter.supportsQuickToggle {
            performQuickToggle(adapter: adapter, markerID: placed.id)
        } else {
            controllingAccessory = accessory
        }
    }
    
    private func performQuickToggle(adapter: any AccessoryAdapter, markerID: UUID) {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        executingMarkerID = markerID
        
        Task {
            do {
                try await adapter.performQuickToggle(via: homeKit)
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
            await MainActor.run {
                if executingMarkerID == markerID {
                    executingMarkerID = nil
                }
            }
        }
    }
    
    private func triggerShake(for id: UUID) {
        shakeMarkerID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if shakeMarkerID == id {
                shakeMarkerID = nil
            }
        }
    }
    
    // MARK: - Drag dei marker
    
    private func dragGesture(for placed: PlacedAccessory,
                             imageRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let s = effectiveScale
                dragDeltas[placed.id] = CGSize(
                    width: value.translation.width / s,
                    height: value.translation.height / s
                )
            }
            .onEnded { value in
                let s = effectiveScale
                let tx = value.translation.width / s
                let ty = value.translation.height / s
                let basePointX = placed.position.x * imageRect.width
                let basePointY = placed.position.y * imageRect.height
                let newX = basePointX + tx
                let newY = basePointY + ty
                
                let normalized = NormalizedPoint(
                    x: max(0, min(1, newX / imageRect.width)),
                    y: max(0, min(1, newY / imageRect.height))
                )
                placed.position = normalized
                placed.linkedRoomUUID = FloorplanRoomMatcher.linkedRoomID(
                    containing: normalized,
                    in: floorplan.linkedRooms
                )
                floorplan.updatedAt = .now
                try? modelContext.save()
                
                dragDeltas[placed.id] = .zero
            }
    }
    
    // MARK: - Marker actions

    private func startAssistedPlacement(for roomID: UUID) {
        pickerRoomFilter = roomID
        editHighlightedRoomID = roomID
        pendingMarkerPosition = floorplan.linkedRooms
            .first { $0.hmRoomUUID == roomID }
            .map(normalizedCenter)

        showFloorplanDiagnostics = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            showingPicker = true
        }
    }

    private func normalizedCenter(for room: LinkedRoom) -> NormalizedPoint {
        if let points = room.normalizedPoints, !points.isEmpty {
            let sum = points.reduce((x: 0.0, y: 0.0)) { partial, point in
                (partial.x + point.x, partial.y + point.y)
            }
            return NormalizedPoint(
                x: sum.x / Double(points.count),
                y: sum.y / Double(points.count)
            )
        }

        return NormalizedPoint(
            x: room.normalizedRect.x + room.normalizedRect.width / 2,
            y: room.normalizedRect.y + room.normalizedRect.height / 2
        )
    }
    
    private func addAccessory(_ accessory: HMAccessory, at position: NormalizedPoint? = nil) {
        let markerPosition = position ?? .center
        let placed = PlacedAccessory(
            homeKitAccessoryUUID: accessory.uniqueIdentifier,
            position: markerPosition,
            linkedRoomUUID: FloorplanRoomMatcher.linkedRoomID(
                containing: markerPosition,
                in: floorplan.linkedRooms
            )
        )
        placed.floorplan = floorplan
        modelContext.insert(placed)
        floorplan.accessories.append(placed)
        floorplan.updatedAt = .now
        try? modelContext.save()
    }
    
    private func deleteMarker(_ placed: PlacedAccessory) {
        let uuid = placed.homeKitAccessoryUUID
        floorplan.accessories.removeAll { $0.id == placed.id }
        modelContext.delete(placed)
        floorplan.updatedAt = .now
        try? modelContext.save()
        
        selectedMarkerID = nil
        homeKit.stopObserving(accessoryUUIDs: [uuid])
    }
    
    private func recenterMarker(_ placed: PlacedAccessory) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            placed.position = .center
        }
        floorplan.updatedAt = .now
        try? modelContext.save()
    }
    
    private func applyRename(to placed: PlacedAccessory, newLabel: String) {
        let trimmed = newLabel.trimmingCharacters(in: .whitespaces)
        placed.customLabel = trimmed.isEmpty ? nil : trimmed
        floorplan.updatedAt = .now
        try? modelContext.save()
    }

    private func backfillMarkerRoomLinksIfNeeded() {
        guard !floorplan.linkedRooms.isEmpty else { return }

        var didUpdate = false
        for marker in floorplan.accessories where marker.linkedRoomUUID == nil {
            guard let roomID = FloorplanRoomMatcher.linkedRoomID(
                containing: marker.position,
                in: floorplan.linkedRooms
            ) else { continue }

            marker.linkedRoomUUID = roomID
            didUpdate = true
        }

        if didUpdate {
            floorplan.updatedAt = .now
            try? modelContext.save()
        }
    }
    
    // MARK: - Top Bar Height PreferenceKey

    // MARK: - HomeKit subscriptions

    private func subscribeToAccessories() {
        let uuids = Set(floorplan.accessories.map(\.homeKitAccessoryUUID))
        homeKit.startObserving(accessoryUUIDs: uuids)
    }
    
    private func unsubscribeFromAccessories() {
        let uuids = Set(floorplan.accessories.map(\.homeKitAccessoryUUID))
        homeKit.stopObserving(accessoryUUIDs: uuids)
    }
}

// MARK: - TopBarHeightKey

/// Propaga l'altezza misurata della top bar dallo strato della barra
/// allo ZStack principale, così l'immagine può essere centrata nel
/// rettangolo libero sotto la barra.
private struct TopBarHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
