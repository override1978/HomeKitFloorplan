import SwiftUI
import SwiftData
import HomeKit

struct FloorplanEditorView: View {
    @Bindable var floorplan: Floorplan
    @Binding var columnVisibility: NavigationSplitViewVisibility
    
    @AppStorage(MarkerSize.appStorageKey)
    private var markerSizeRaw: String = MarkerSize.regular.rawValue
    
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
    
    private var selectedMarker: PlacedAccessory? {
        guard let id = selectedMarkerID else { return nil }
        return floorplan.accessories.first { $0.id == id }
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
                Color(.systemBackground)
                    .ignoresSafeArea()
                
                if let image = ImageStorageService.load(filename: floorplan.imageFilename) {
                    imageWithMarkers(image: image, container: proxy.size)
                        .scaleEffect(effectiveScale, anchor: .center)
                        .offset(effectiveOffset)
                        .gesture(zoomPanGesture(in: proxy.size))
                } else {
                    ContentUnavailableView(
                        "Immagine non disponibile",
                        systemImage: "photo.badge.exclamationmark"
                    )
                }
                
                floatingControls(in: proxy.size)
                    .opacity(shouldShowControls ? 1 : 0)
                    .animation(.easeInOut(duration: 0.3), value: shouldShowControls)

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
        }) {
            AccessoryPickerSheet(
                alreadyPlaced: Set(floorplan.accessories.map(\.homeKitAccessoryUUID)),
                preferredRoomUUIDs: pickerRoomFilter != nil
                    ? Set([pickerRoomFilter!])
                    : Set(floorplan.linkedRooms.map(\.hmRoomUUID)),
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
            subscribeToAccessories()
            restoreZoom()
            if startInEditMode {
                isEditing = true
                controlsVisible = true
                hideTask?.cancel()
            } else {
                scheduleAutoHide()
            }
        }
        .onChange(of: homeKit.isReady) { _, isReady in
            if isReady {
                subscribeToAccessories()
            }
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
    }
    
    // MARK: - Floating controls
    
    @ViewBuilder
    private func floatingControls(in size: CGSize) -> some View {
        // Top: name pill (con bottone sidebar se sidebar nascosta) + actions
        VStack {
            HStack {
                HStack(spacing: 10) {
                    // Bottone "Sidebar": appare solo quando la sidebar è nascosta
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
                    
                    GlassPill {
                        Text(floorplan.name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                }
                Spacer()
                topRightActions
            }
            .animation(.spring(response: 0.4), value: columnVisibility)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
        }
        
        // Bottom-right: zoom indicator (solo se zoom != 1)
        VStack {
            Spacer()
            HStack {
                Spacer()
                if effectiveScale > 1.01 {
                    GlassPill {
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
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        
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
                    onChangeIcon: {                         // 👈 NUOVO
                        iconPickerTarget = placed
                    }
                )
                .padding(.bottom, 20)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85),
                       value: selectedMarkerID)
        }
    }
    
    private var topRightActions: some View {
        GlassPill {
            HStack(spacing: 0) {
                // Bottone + solo in edit mode
                if isEditing {
                    Button {
                        pickerRoomFilter = nil
                        pendingMarkerPosition = nil
                        showingPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))

                    Divider().frame(height: 20)
                        .transition(.opacity)
                }

                // Scene: sempre visibile
                Button {
                    showScenesPanel = true
                } label: {
                    Image(systemName: "wand.and.sparkles")
                        .font(.subheadline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().frame(height: 20)

                Button {
                    withAnimation(.spring(response: 0.3)) {
                        isEditing.toggle()
                        if !isEditing { selectedMarkerID = nil }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isEditing ? "checkmark" : "pencil")
                        Text(isEditing ? "Fine" : "Modifica")
                    }
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isEditing ? Color.accentColor : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
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

        // Reverse the zoom/pan transform (scaleEffect anchor: .center, then offset)
        let centerX = containerSize.width / 2
        let centerY = containerSize.height / 2
        let adjustedX = (tapLocation.x - centerX - effectiveOffset.width) / effectiveScale + centerX
        let adjustedY = (tapLocation.y - centerY - effectiveOffset.height) / effectiveScale + centerY

        // Compute the content rect using the saved image (aspect-fit).
        guard let image = ImageStorageService.load(filename: floorplan.imageFilename) else { return }
        let imgRect = imageRect(imageSize: image.size, container: containerSize)

        // Normalize to [0, 1] within the content rect
        let normX = (adjustedX - imgRect.origin.x) / imgRect.width
        let normY = (adjustedY - imgRect.origin.y) / imgRect.height
        guard normX >= 0, normX <= 1, normY >= 0, normY <= 1 else { return }

        pendingMarkerPosition = NormalizedPoint(x: normX, y: normY)

        // Hit-test linked room areas
        pickerRoomFilter = floorplan.linkedRooms.first { room in
            let r = room.normalizedRect
            return normX >= r.x && normX <= r.x + r.width
                && normY >= r.y && normY <= r.y + r.height
        }?.hmRoomUUID

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

    private func restoreZoom() {
        let ud = UserDefaults.standard
        guard ud.object(forKey: zoomScaleKey) != nil else { return }
        zoomScale  = CGFloat(ud.double(forKey: zoomScaleKey))
        zoomOffset = CGSize(
            width:  CGFloat(ud.double(forKey: zoomOffsetXKey)),
            height: CGFloat(ud.double(forKey: zoomOffsetYKey))
        )
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

            ForEach(floorplan.accessories) { placed in
                markerView(for: placed, in: rect)
            }

            // Hint flottante per planimetria vuota
            if floorplan.accessories.isEmpty {
                emptyMarkersHint
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .frame(width: container.width, height: container.height)
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
        let shaking = shakeMarkerID == placed.id
        
        let inverseScale = 1.0 / effectiveScale
        
        AccessoryMarkerView(
            adapter: adapter,
            isEditing: isEditing,
            isSelected: isEditing && isSelected,
            label: displayLabel,
            hasCustomLabel: placed.customLabel?.isEmpty == false
        )
        .scaleEffect(inverseScale)
        .position(livePoint)
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
    
    // MARK: - Tap handling
    
    private func handleTap(on placed: PlacedAccessory,
                           accessory: HMAccessory?,
                           adapter: (any AccessoryAdapter)?) {
        guard !isEditing else { return }
        guard let accessory else { return }

        scheduleAutoHide()

        // Tap: toggle diretto se supportato, altrimenti apre il pannello dettaglio.
        if let adapter, adapter.supportsQuickToggle {
            performQuickToggle(adapter: adapter)
        } else {
            controllingAccessory = accessory
        }
    }
    
    private func performQuickToggle(adapter: any AccessoryAdapter) {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        
        Task {
            do {
                try await adapter.performQuickToggle(via: homeKit)
            } catch {
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
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
                floorplan.updatedAt = .now
                try? modelContext.save()
                
                dragDeltas[placed.id] = .zero
            }
    }
    
    // MARK: - Marker actions
    
    private func addAccessory(_ accessory: HMAccessory, at position: NormalizedPoint? = nil) {
        let placed = PlacedAccessory(
            homeKitAccessoryUUID: accessory.uniqueIdentifier,
            position: position ?? .center
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
