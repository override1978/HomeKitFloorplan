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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HabitAnalysisService.self) private var habitService
    @Environment(SmartLightingEngine.self) private var smartLightingEngine
    @Environment(CloudKitSyncService.self) private var cloudKitSync
    @Environment(IconOverrideStore.self) private var iconOverrides
    
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
    @State private var drawingEditFloorplan: Floorplan?
    @State private var editHighlightedRoomID: UUID?
    @State private var suppressNextMarkerTapID: UUID?
    @State private var executingMarkerID: UUID?

    @State private var showFloorplanHelp = false
    @AppStorage("floorplan.help.hasSeen.v1")
    private var hasSeenFloorplanHelp = false
    
    @State private var viewport = FloorplanViewportState()
    
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

    /// Cached floorplan image — loaded once on appear and when the floorplan is updated.
    /// Avoids repeated decoding on every body re-evaluation.
    @State private var cachedFloorplanImage: UIImage?
    @State private var cachedFloorplanImageDate: Date = .distantPast
    /// True while the image is being loaded from disk — prevents the "not available" state flash.
    @State private var isLoadingImage: Bool = false
    @State private var isSystemOverlayTransitionActive = false
    @State private var systemOverlayTransitionTask: Task<Void, Never>?

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

    private func buildOverlayContext() -> FloorplanOverlayContext {
        let hasEnv = !floorplan.linkedRooms.isEmpty
        let hasSecure = homeKit.allAccessories.contains { acc in
            if acc.category.categoryType == HMAccessoryCategoryTypeIPCamera ||
                acc.category.categoryType == HMAccessoryCategoryTypeVideoDoorbell {
                return true
            }
            return acc.services.contains { svc in
                svc.serviceType == HMServiceTypeLockMechanism
                    || svc.serviceType == HMServiceTypeSecuritySystem
                    || svc.serviceType == HMServiceTypeGarageDoorOpener
                    || svc.serviceType == HMServiceTypeDoorbell
                    || svc.serviceType == HMServiceTypeContactSensor
            }
        }
        return FloorplanOverlayContext(
            hasEnvironmentData: hasEnv,
            hasSecurityDevices: hasSecure,
            hasAIService: isAIEnabled,
            hasIntelligenceSuggestions: isAIEnabled && !habitService.pendingPatterns.isEmpty
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
        viewport.effectiveScale
    }
    
    private var effectiveOffset: CGSize {
        viewport.effectiveOffset
    }
    
    private var shouldShowControls: Bool {
        isEditing || controlsVisible
    }

    private var shouldSuppressIdleScreensaver: Bool {
        showingPicker
            || controllingAccessory != nil
            || iconPickerTarget != nil
            || showFloorplanDiagnostics
            || showScenesPanel
            || showFloorplanHelp
            || pendingDelete != nil
    }

    private var pendingDeleteIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDelete = nil
                }
            }
        )
    }

    private var floorplanBackgroundColor: Color {
        let visualStyle = DrawingVisualExportStyle(rawValue: floorplan.drawingVisualExportStyleRaw) ?? .standard
        if visualStyle == .architecturalDark {
            return DrawingVisualExportStyle.architecturalDarkBackgroundColor
        }
        return ExteriorFillPalette(rawValue: floorplan.exteriorFillColorIndex).map { $0.swiftUIColor } ?? Color.white
    }

    private var systemOverlayTransitionPlaceholder: some View {
        ZStack {
            floorplanBackgroundColor
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Image(systemName: "house")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Text(floorplan.name)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            .opacity(0.72)
        }
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                floorplanBackgroundColor
                    .ignoresSafeArea()

                if isSystemOverlayTransitionActive {
                    systemOverlayTransitionPlaceholder
                } else {
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
                            String(localized: "floorplan.image.unavailable", defaultValue: "Image not available"),
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
                        FloorplanOverlayContextContent(
                            overlayVM: vm,
                            containerWidth: proxy.size.width,
                            floorplan: floorplan,
                            homeKit: homeKit,
                            environmentViewModel: overlayEnvVM,
                            pendingSuggestionCount: habitService.pendingPatterns.count
                        )
                    }
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
            let preferredRoomUUIDs = pickerRoomFilter != nil
                ? Set([pickerRoomFilter!])
                : Set(floorplan.linkedRooms.map(\.hmRoomUUID))
            let preferredRoomNames = Set(
                floorplan.linkedRooms
                    .filter { room in
                        pickerRoomFilter == nil || room.hmRoomUUID == pickerRoomFilter
                    }
                    .map { normalizedRoomName($0.name) }
            )
            let alreadyPlaced = Set(floorplan.accessories.map(\.homeKitAccessoryUUID))
            let title = accessoryPickerTitle
            AccessoryPickerSheet(
                alreadyPlaced: alreadyPlaced,
                preferredRoomUUIDs: preferredRoomUUIDs,
                preferredRoomNames: preferredRoomNames,
                title: title,
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
                    defaultIconName: adapter.iconName,
                    onIconChanged: {
                        floorplan.updatedAt = .now
                        try? modelContext.save()
                        cloudKitSync.markFloorplanNeedsSync(floorplan.id)
                    }
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
        .sheet(isPresented: $showFloorplanHelp, onDismiss: {
            hasSeenFloorplanHelp = true
        }) {
            FloorplanHelpSheet {
                hasSeenFloorplanHelp = true
                showFloorplanHelp = false
            }
        }
        .fullScreenCover(item: $drawingEditFloorplan, onDismiss: {
            refreshFloorplanImageCache()
            refreshOverlayContext()
            subscribeToAccessories()
        }) { editingFloorplan in
            drawingEditor(for: editingFloorplan)
                .environment(homeKit)
                .ignoresSafeArea()
        }
        .suppressesIdleScreensaver(.floorplanInteraction, when: shouldSuppressIdleScreensaver)
        
        
        .alert(String(localized: "floorplan.marker.delete.title", defaultValue: "Remove accessory from floorplan?"),
               isPresented: pendingDeleteIsPresented,
               presenting: pendingDelete) { placed in
            Button(String(localized: "common.delete", defaultValue: "Delete"), role: .destructive) {
                deleteMarker(placed)
            }
            Button(String(localized: "common.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "floorplan.marker.delete.message", defaultValue: "The accessory will be removed from the floorplan but will remain active in HomeKit."))
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
            showFloorplanHelpIfNeeded()
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
        .onChange(of: floorplan.updatedAt) { _, _ in
            refreshFloorplanImageCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .floorplansDidApplyRemoteChanges)) { notification in
            handleFloorplanRemoteChanges(notification)
        }
        .onDisappear {
            handleDisappear()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
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

                        FloorplanTitleMenu(
                            currentFloorplan: floorplan,
                            pinnedFloorplans: pinnedFloorplans,
                            primaryFloorplanID: primaryFloorplanID,
                            onOpenSidebar: {
                                withAnimation(.spring(response: 0.4)) {
                                    columnVisibility = .all
                                }
                            },
                            onSelectFloorplan: onSelectFloorplan
                        )
                    }

                    Spacer()

                    // Destra: azioni (+ / scene / modifica)
                    topRightActions(in: size)
                }
            }
            .animation(.spring(response: 0.4), value: columnVisibility)
            .padding(.horizontal, 20)
            .padding(.top, 12)

            if !isEditing,
               overlayVM?.activeMode == .controls,
               cloudKitSync.isMaster,
               let status = smartLightingEngine.floorplanStatus {
                FloorplanSmartLightingStatusPill(
                    status: status,
                    onPause: smartLightingEngine.pauseFromFloorplan,
                    onResume: smartLightingEngine.resumeFromFloorplan
                )
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

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
                FloorplanEditModeBanner {
                    showFloorplanDiagnostics = true
                }
                    .padding(.top, 6)
                    .transition(.opacity)
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
            let auditNotice = markerAuditService.auditNotice(for: placed, accessory: accessory)

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
                    },
                    auditNotice: auditNotice,
                    onResolveAudit: auditNotice == nil ? nil : {
                        resolveMarkerAudit(for: placed, accessory: accessory)
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
        FloorplanTopRightActions(
            isEditing: isEditing,
            isOverlayMode: (overlayVM?.activeMode ?? .controls) != .controls,
            showsSceneText: size.width >= 760,
            isDrawingAvailable: floorplan.drawingDocumentJSON != nil,
            onAddAccessory: {
                pickerRoomFilter = nil
                pendingMarkerPosition = nil
                editHighlightedRoomID = nil
                showingPicker = true
            },
            onShowHelp: {
                hasSeenFloorplanHelp = true
                showFloorplanHelp = true
            },
            onShowDiagnostics: {
                showFloorplanDiagnostics = true
            },
            onEditDrawing: {
                drawingEditFloorplan = floorplan
            },
            onShowScenes: {
                showScenesPanel = true
            },
            onToggleEditing: {
                isEditing.toggle()
                suppressNextMarkerTapID = nil
                executingMarkerID = nil
                if !isEditing {
                    selectedMarkerID = nil
                    editHighlightedRoomID = nil
                }
            }
        )
    }

    private func drawingEditor(for floorplan: Floorplan) -> some View {
        DrawingFloorplanSheet(
            initialDocument: floorplan.drawingDocument,
            initialExteriorFillColorIndex: floorplan.exteriorFillColorIndex,
            initialVisualExportStyle: DrawingVisualExportStyle(rawValue: floorplan.drawingVisualExportStyleRaw) ?? .standard,
            initialExportRotation: floorplan.drawingExportRotation
        ) { image, rooms, doc, colorIndex, visualStyle, exportRotation in
            let previousRooms = floorplan.linkedRooms
            let previousRotation = floorplan.drawingExportRotation
            if let newData = image.jpegData(compressionQuality: 0.85) {
                floorplan.imageData = newData
            }
            floorplan.drawingDocument = doc
            floorplan.exteriorFillColorIndex = colorIndex
            floorplan.drawingVisualExportStyleRaw = visualStyle.rawValue
            floorplan.drawingExportRotation = exportRotation
            if !rooms.isEmpty {
                preserveMarkerPositions(
                    on: floorplan,
                    from: previousRooms,
                    to: rooms,
                    previousRotation: previousRotation,
                    newRotation: exportRotation
                )
                floorplan.linkedRooms = rooms
            }
            floorplan.updatedAt = .now
            try? modelContext.save()
            cloudKitSync.markFloorplanNeedsSync(floorplan.id)
            refreshFloorplanImageCache()
            refreshOverlayContext()
        }
    }
    
    // MARK: - Auto-hide

    private func showFloorplanHelpIfNeeded() {
        guard !hasSeenFloorplanHelp else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !hasSeenFloorplanHelp,
                  !showingPicker,
                  controllingAccessory == nil,
                  iconPickerTarget == nil,
                  !showFloorplanDiagnostics,
                  !showScenesPanel else { return }
            showFloorplanHelp = true
        }
    }
    
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
                viewport.updateLiveScale(value)
            }
            .onEnded { value in
                viewport.finishMagnification(value, floorplanID: floorplan.id)
            }

        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                viewport.updateLiveOffset(value.translation)
            }
            .onEnded { value in
                viewport.finishDrag(value.translation, container: container, floorplanID: floorplan.id)
            }

        return magnify.simultaneously(with: drag)
    }

    private func resetZoom() {
        viewport.reset(floorplanID: floorplan.id)
    }

    private func refreshFloorplanImageCache() {
        let stamp = floorplan.updatedAt
        guard stamp != cachedFloorplanImageDate || cachedFloorplanImage == nil else { return }
        cachedFloorplanImageDate = stamp
        let data = floorplan.currentImageData
        guard let data else {
            isLoadingImage = false
            return
        }
        isLoadingImage = true
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
            withAnimation(.easeIn(duration: 0.2)) {
                cachedFloorplanImage = image
                isLoadingImage = false
            }
        }
    }

    private func handleFloorplanRemoteChanges(_ notification: Notification) {
        reconcileVisibleMarkersIfNeeded(from: notification)
        SyncDiagnosticsLogger.log(
            "Editor observed floorplan remote-change floorplan=\(floorplan.id.uuidString) markers=\(floorplan.accessories.count) positions=[\(markerPositionDigest())]"
        )
        refreshFloorplanImageCache()
        refreshOverlayContext()
        subscribeToAccessories()
    }

    private func handleDisappear() {
        unsubscribeFromAccessories()
        hideTask?.cancel()
        systemOverlayTransitionTask?.cancel()
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        systemOverlayTransitionTask?.cancel()

        switch phase {
        case .inactive:
            withTransaction(Transaction(animation: nil)) {
                isSystemOverlayTransitionActive = true
            }
        case .active:
            systemOverlayTransitionTask = Task {
                try? await Task.sleep(for: .milliseconds(420))
                await MainActor.run {
                    withTransaction(Transaction(animation: nil)) {
                        isSystemOverlayTransitionActive = false
                    }
                }
            }
        case .background:
            withTransaction(Transaction(animation: nil)) {
                isSystemOverlayTransitionActive = true
            }
        @unknown default:
            break
        }
    }

    private func restoreZoom() {
        viewport.restore(floorplanID: floorplan.id)
    }
    
    // MARK: - Image rect
    
    private func imageRect(imageSize: CGSize, container: CGSize) -> CGRect {
        FloorplanCanvasGeometry.imageRect(imageSize: imageSize, container: container)
    }
    
    private func imageWithMarkers(image: UIImage, container: CGSize) -> some View {
        let rect = imageRect(imageSize: image.size, container: container)
        let showMarkers = isEditing || (overlayVM?.activeMode == .controls)
        return FloorplanCanvasView(
            image: image,
            containerSize: container,
            showOverlayLayer: overlayVM != nil && !isEditing,
            showEditLayer: isEditing && !floorplan.linkedRooms.isEmpty,
            showMarkers: showMarkers,
            markerItems: showMarkers ? markerRenderItems() : [],
            collisionOffsets: showMarkers ? markerCollisionOffsets(in: rect) : [:]
        ) { container, imageRect in
            if let vm = overlayVM, !isEditing {
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
                    pickerRoomFilter = nil
                    pendingMarkerPosition = nil
                    showingPicker = true
                }
            )
        }
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

    private func reconcileVisibleMarkersIfNeeded(from notification: Notification) {
        guard let snapshotsByFloorplanID = notification.userInfo?[FloorplanRemoteChangeNotification.markerSnapshotsByFloorplanIDKey] as? [UUID: [PlacedAccessorySnapshot]],
              let snapshots = snapshotsByFloorplanID[floorplan.id] else {
            return
        }

        let existingByID = Dictionary(uniqueKeysWithValues: floorplan.accessories.map { ($0.id, $0) })
        var updatedCount = 0

        for snapshot in snapshots {
            guard let placed = existingByID[snapshot.id] else { continue }
            if placed.positionX != snapshot.positionX || placed.positionY != snapshot.positionY {
                updatedCount += 1
            }
            placed.positionX = snapshot.positionX
            placed.positionY = snapshot.positionY
            placed.linkedRoomUUID = snapshot.linkedRoomUUID
            placed.customLabel = snapshot.customLabel
            if let iconOverride = snapshot.iconOverride {
                iconOverrides.setIcon(iconOverride, for: placed.homeKitAccessoryUUID)
            } else {
                iconOverrides.removeIcon(for: placed.homeKitAccessoryUUID)
            }
        }

        if updatedCount > 0 {
            SyncDiagnosticsLogger.log(
                "Editor reconciled remote marker snapshot floorplan=\(floorplan.id.uuidString) updatedMarkers=\(updatedCount)"
            )
        }
    }

    private func markerPositionDigest() -> String {
        floorplan.accessories
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map {
                "\($0.id.uuidString.prefix(8))=(\(formatCoordinate($0.positionX)),\(formatCoordinate($0.positionY)))"
            }
            .joined(separator: ",")
    }

    private func formatCoordinate(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func normalizedRoomName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private func markerView(item: FloorplanMarkerRenderItem,
                            in imageRect: CGRect,
                            collisionOffset: CGSize) -> some View {
        let placed = item.placed
        let basePoint = CGPoint(
            x: imageRect.origin.x + placed.position.x * imageRect.width,
            y: imageRect.origin.y + placed.position.y * imageRect.height
        )
        let delta = dragDeltas[placed.id] ?? .zero
        let livePoint = CGPoint(x: basePoint.x + delta.width,
                                y: basePoint.y + delta.height)
        let displayPoint = CGPoint(
            x: livePoint.x + collisionOffset.width,
            y: livePoint.y + collisionOffset.height
        )
        
        let inverseScale = 1.0 / effectiveScale
        
        AccessoryMarkerView(
            adapter: item.adapter,
            isEditing: isEditing,
            isSelected: isEditing && item.isSelected,
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
            isEditing
            ? nil
            : markerInteractionGesture(for: placed, accessory: item.accessory, adapter: item.adapter)
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

    private func markerRenderItems() -> [FloorplanMarkerRenderItem] {
        FloorplanMarkerRenderItemBuilder(
            homeKit: homeKit,
            isEditing: isEditing,
            allowsCameraSnapshot: !isEditing && overlayVM?.activeMode == .security,
            selectedMarkerID: selectedMarkerID,
            executingMarkerID: executingMarkerID,
            shakeMarkerID: shakeMarkerID,
            duplicatedMarkerAccessoryIDs: duplicatedMarkerAccessoryIDs,
            linkedRooms: floorplan.linkedRooms
        ).makeItems(from: floorplan.accessories)
    }

    private var markerAuditService: FloorplanMarkerAuditService {
        FloorplanMarkerAuditService(
            isEditing: isEditing,
            duplicatedMarkerAccessoryIDs: duplicatedMarkerAccessoryIDs,
            linkedRooms: floorplan.linkedRooms
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

    private func markerInteractionGesture(for placed: PlacedAccessory,
                                          accessory: HMAccessory?,
                                          adapter: (any AccessoryAdapter)?) -> some Gesture {
        LongPressGesture(minimumDuration: 0.42, maximumDistance: 64)
            .exclusively(before: TapGesture())
            .onEnded { result in
                switch result {
                case .first:
                    if let accessory {
                        scheduleAutoHide()
                        controllingAccessory = accessory
                    }
                case .second:
                    handleTap(on: placed, accessory: accessory, adapter: adapter)
                }
            }
    }

    private func resolveMarkerAudit(for placed: PlacedAccessory,
                                    accessory: HMAccessory?) {
        guard let issue = markerAuditService.editIssue(for: placed, accessory: accessory) else { return }

        switch issue {
        case .missingHomeKitAccessory, .duplicateMarker:
            pendingDelete = placed
        case .outsideLinkedRoom:
            recenterMarker(placed)
        case .roomLinkMismatch:
            alignMarkerRoomLink(placed)
        }
    }

    private func alignMarkerRoomLink(_ placed: PlacedAccessory) {
        markerEditingCoordinator.alignMarkerRoomLink(placed)
    }

    private func markerCollisionOffsets(in imageRect: CGRect) -> [UUID: CGSize] {
        guard !isEditing, floorplan.accessories.count > 1 else { return [:] }

        let scale = max(effectiveScale, 0.01)
        let threshold = 32 / scale
        let markerPoints = floorplan.accessories.map { marker in
            (
                marker: marker,
                point: CGPoint(
                    x: imageRect.origin.x + marker.position.x * imageRect.width,
                    y: imageRect.origin.y + marker.position.y * imageRect.height
                )
            )
        }
        var offsets: [UUID: CGSize] = [:]

        for entry in markerPoints {
            let nearbyMarkers = markerPoints
                .filter { candidate in
                    hypot(candidate.point.x - entry.point.x, candidate.point.y - entry.point.y) <= threshold
                }
                .map(\.marker)
                .sorted { $0.id.uuidString < $1.id.uuidString }

            guard nearbyMarkers.count > 1,
                  let index = nearbyMarkers.firstIndex(where: { $0.id == entry.marker.id }) else {
                continue
            }

            let count = CGFloat(nearbyMarkers.count)
            let angle = (2 * CGFloat.pi * CGFloat(index) / count) - (.pi / 2)
            let radius = min(24, 10 + count * 3) / scale

            offsets[entry.marker.id] = CGSize(
                width: cos(angle) * radius,
                height: sin(angle) * radius
            )
        }

        return offsets
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
                cloudKitSync.markFloorplanNeedsSync(floorplan.id)
                
                dragDeltas[placed.id] = .zero
            }
    }

    // MARK: - Marker actions

    private func startAssistedPlacement(for roomID: UUID) {
        pickerRoomFilter = roomID
        editHighlightedRoomID = roomID
        pendingMarkerPosition = floorplan.linkedRooms
            .first { $0.hmRoomUUID == roomID }
            .map(markerEditingCoordinator.normalizedCenter)

        showFloorplanDiagnostics = false

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            showingPicker = true
        }
    }
    
    private func addAccessory(_ accessory: HMAccessory, at position: NormalizedPoint? = nil) {
        markerEditingCoordinator.addAccessory(accessory, at: position)
    }

    private func deleteMarker(_ placed: PlacedAccessory) {
        markerEditingCoordinator.deleteMarker(placed)
        selectedMarkerID = nil
    }

    private func recenterMarker(_ placed: PlacedAccessory) {
        markerEditingCoordinator.recenterMarker(placed)
    }

    private func applyRename(to placed: PlacedAccessory, newLabel: String) {
        markerEditingCoordinator.applyRename(to: placed, newLabel: newLabel)
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

    private func preserveMarkerPositions(on floorplan: Floorplan,
                                         from previousRooms: [LinkedRoom],
                                         to newRooms: [LinkedRoom],
                                         previousRotation: DrawingExportRotation,
                                         newRotation: DrawingExportRotation) {
        guard !previousRooms.isEmpty, !newRooms.isEmpty else { return }

        let previousByID = Dictionary(uniqueKeysWithValues: previousRooms.map { ($0.hmRoomUUID, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: newRooms.map { ($0.hmRoomUUID, $0) })
        let rotationDelta = (newRotation.quarterTurns - previousRotation.quarterTurns + 4) % 4

        for marker in floorplan.accessories {
            let markerPoint = NormalizedPoint(x: marker.positionX, y: marker.positionY)
            guard let roomID = marker.linkedRoomUUID ?? roomID(containing: markerPoint, in: previousRooms),
                  let previousRoom = previousByID[roomID],
                  let newRoom = newByID[roomID] else { continue }

            let previousRect = previousRoom.normalizedRect
            let newRect = newRoom.normalizedRect
            guard previousRect.width > 0, previousRect.height > 0 else { continue }

            let localX = (marker.positionX - previousRect.x) / previousRect.width
            let localY = (marker.positionY - previousRect.y) / previousRect.height
            let rotatedLocal = rotatedLocalPoint(x: localX, y: localY, quarterTurns: rotationDelta)

            marker.positionX = clamped(markerPosition: newRect.x + rotatedLocal.x * newRect.width)
            marker.positionY = clamped(markerPosition: newRect.y + rotatedLocal.y * newRect.height)
            marker.linkedRoomUUID = FloorplanRoomMatcher.linkedRoomID(
                containing: marker.position,
                in: newRooms
            ) ?? roomID
        }
    }

    private func rotatedLocalPoint(x: Double, y: Double, quarterTurns: Int) -> (x: Double, y: Double) {
        switch quarterTurns {
        case 1:
            return (1 - y, x)
        case 2:
            return (1 - x, 1 - y)
        case 3:
            return (y, 1 - x)
        default:
            return (x, y)
        }
    }

    private func roomID(containing point: NormalizedPoint, in rooms: [LinkedRoom]) -> UUID? {
        rooms.first { room in
            let rect = room.normalizedRect
            return point.x >= rect.x &&
                point.x <= rect.x + rect.width &&
                point.y >= rect.y &&
                point.y <= rect.y + rect.height
        }?.hmRoomUUID
    }

    private func clamped(markerPosition value: Double) -> Double {
        min(1, max(0, value))
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

private struct FloorplanHelpSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(String(localized: "floorplan.help.subtitle",
                                defaultValue: "Use the floorplan as a live map for HomeKit controls, scenes, overlays, and setup."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        helpRow(
                            icon: "pencil",
                            title: String(localized: "floorplan.help.edit.title", defaultValue: "Edit mode"),
                            message: String(localized: "floorplan.help.edit.message", defaultValue: "Tap Edit to place and manage accessory markers on the floorplan.")
                        )
                        helpRow(
                            icon: "rectangle.dashed",
                            title: String(localized: "floorplan.help.add.title", defaultValue: "Add markers"),
                            message: String(localized: "floorplan.help.add.message", defaultValue: "In edit mode, tap a room area to add an accessory there. If no room areas exist, use + in the top-right corner.")
                        )
                        helpRow(
                            icon: "hand.tap",
                            title: String(localized: "floorplan.help.editMarker.title", defaultValue: "Edit a marker"),
                            message: String(localized: "floorplan.help.editMarker.message", defaultValue: "In edit mode, tap a marker to rename it, change its icon, recenter it, or remove it from the floorplan.")
                        )
                        helpRow(
                            icon: "bolt.fill",
                            title: String(localized: "floorplan.help.action.title", defaultValue: "Run quick actions"),
                            message: String(localized: "floorplan.help.action.message", defaultValue: "Outside edit mode, tap a marker to run its primary action when supported.")
                        )
                        helpRow(
                            icon: "rectangle.expand.vertical",
                            title: String(localized: "floorplan.help.detail.title", defaultValue: "Open details"),
                            message: String(localized: "floorplan.help.detail.message", defaultValue: "Long-press a marker to open the full accessory control view.")
                        )
                        helpRow(
                            icon: "ipad",
                            title: String(localized: "floorplan.help.foreground.title", defaultValue: "When to keep it open"),
                            message: String(localized: "floorplan.help.foreground.message", defaultValue: "Keep HomeFloorplan in the foreground while editing, monitoring live dashboards, collecting sensor context, or letting AI suggestions and habits learn from recent activity. HomeKit automations saved to Apple Home continue to run without keeping the app open.")
                        )
                    }
                }
                .padding(24)
            }
            .navigationTitle(String(localized: "floorplan.help.title", defaultValue: "Floorplan basics"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) {
                        onDone()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func helpRow(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(BrandColor.primary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
