import SwiftUI
import UIKit
import HomeKit

enum DrawingExportMode: String, CaseIterable, Identifiable {
    case legacy
    case adaptive

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .legacy:
            return String(localized: "drawing.export.mode.legacy", defaultValue: "Legacy")
        case .adaptive:
            return String(localized: "drawing.export.mode.adaptive", defaultValue: "Adaptive")
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .legacy:
            return String(localized: "drawing.export.mode.legacy.subtitle", defaultValue: "Current screen-based export")
        case .adaptive:
            return String(localized: "drawing.export.mode.adaptive.subtitle", defaultValue: "Stable landscape export")
        }
    }
}

// MARK: - DrawingFloorplanSheet

/// Full-screen 2D drawing editor.
/// Owns all drawing state, undo stack, and exports the result as a `UIImage`.
///
/// Usage:
/// ```swift
/// .fullScreenCover(isPresented: $showDrawingEditor) {
///     DrawingFloorplanSheet { image in
///         // save `image` via ImageStorageService
///     }
/// }
/// ```
struct DrawingFloorplanSheet: View {

    /// Called when the user taps "Fatto" — provides the rendered PNG, linked rooms, and the drawing document.
    var onComplete: (UIImage, [LinkedRoom], DrawingDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(HomeKitService.self) private var homeKit

    // MARK: Drawing state

    @State private var document: DrawingDocument

    init(initialDocument: DrawingDocument? = nil,
         onComplete: @escaping (UIImage, [LinkedRoom], DrawingDocument) -> Void) {
        self.onComplete = onComplete
        _document = State(initialValue: initialDocument ?? DrawingDocument())
    }

    @State private var mode: DrawingMode = .draw
    @State private var selection: DrawingSelection = .none
    @State private var wallKind: WallKind = .exterior
    @AppStorage("drawing.export.mode") private var exportModeRaw: String = DrawingExportMode.legacy.rawValue
    @AppStorage("drawing.help.hasSeen") private var hasSeenDrawingHelp = false
    /// When false, wall drawing snaps only to the 20pt grid (no vertex snapping).
    @State private var vertexSnapEnabled: Bool = true

    // MARK: Room label placement state

    /// Canvas position saved when the user taps in .placeRoomLabel mode;
    /// cleared after the room picker resolves.
    @State private var pendingLabelPosition: CGPoint?
    @State private var showRoomPicker = false

    // MARK: Room area placement state

    /// Canvas rect saved when the user finishes dragging in .drawRoomArea mode;
    /// cleared after the room picker resolves.
    @State private var pendingAreaRect: CGRect?
    @State private var showAreaRoomPicker = false

    // MARK: Undo stack (max 30 snapshots)

    @State private var undoStack: [DrawingDocument] = []
    @State private var redoStack: [DrawingDocument] = []
    private let undoLimit = 30

    // MARK: Alert for cancel confirmation

    @State private var showCancelConfirm = false
    @State private var isExporting = false
    @State private var showHelpSheet = false

    private var exportMode: DrawingExportMode {
        get { DrawingExportMode(rawValue: exportModeRaw) ?? .legacy }
        nonmutating set { exportModeRaw = newValue.rawValue }
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            // Canvas (fills entire screen)
            DrawingCanvasView(
                document:          $document,
                mode:              $mode,
                selection:         $selection,
                wallKind:          $wallKind,
                vertexSnapEnabled: vertexSnapEnabled,
                onCommit: { newDoc in
                    pushUndo()
                    document = newDoc
                },
                onPlaceOpening: handlePlaceOpening(kind:at:),
                onPlaceRoomLabel: handlePlaceRoomLabel(at:),
                onBeginMoveOpening: { _ in pushUndo() },
                onMoveOpening: handleMoveOpening(id:at:),
                onBeginMoveRoomLabel: { _ in pushUndo() },
                onMoveRoomLabel: handleMoveRoomLabel(id:at:),
                onCommitRoomArea: handleCommitRoomArea(rect:),
                onBeginMoveRoomArea: { _ in pushUndo() },
                onMoveRoomArea: handleMoveRoomArea(id:delta:),
                onBeginResizeRoomArea: { _ in pushUndo() },
                onResizeRoomArea: handleResizeRoomArea(id:newRect:),
                onMoveRoomAreaVertex: handleMoveRoomAreaVertex(id:vertexIndex:to:),
                onInsertRoomAreaVertex: handleInsertRoomAreaVertex(id:edgeIndex:at:),
                onRemoveRoomAreaVertex: handleRemoveRoomAreaVertex(id:vertexIndex:),
                onPlaceFurniture: handlePlaceFurniture(at:),
                onBeginMoveFurniture: { _ in pushUndo() },
                onMoveFurniture: handleMoveFurniture(id:delta:),
                onBeginResizeFurniture: { _ in pushUndo() },
                onResizeFurniture: handleResizeFurniture(id:newRect:),
                onBeginMoveWallEndpoint: { _ in pushUndo() },
                onMoveWallEndpoint: handleMoveWallEndpoint(id:endpointIndex:to:),
                onBeginMoveWall: { _ in pushUndo() },
                onMoveWall: handleMoveWall(id:delta:)
            )
            .ignoresSafeArea()

            // Bottom area: inspector + banner + toolbar
            VStack(spacing: 0) {
                Spacer()

                // Opening inspector — shown when an opening is selected in select mode
                if case .select = mode,
                   case .opening(let id) = selection,
                   let opening = document.opening(for: id) {
                    OpeningInspectorPanel(
                        opening: opening,
                        onWidthChange: { newWidth in
                            applyOpeningChange(id: id) { $0.width = newWidth }
                        },
                        onFlip: {
                            applyOpeningChange(id: id) { $0.flipSide.toggle() }
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Room label inspector — shown when a room label is selected in select mode
                if case .select = mode,
                   case .roomLabel(let id) = selection,
                   let label = document.roomLabel(for: id) {
                    RoomLabelInspectorPanel(label: label)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Room area inspector — shown when a room area is selected in select mode
                if case .select = mode,
                   case .roomArea(let id) = selection,
                   let area = document.roomArea(for: id) {
                    RoomAreaInspectorPanel(area: area)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Furniture inspector — shown when a furniture item is selected in select mode
                if case .select = mode,
                   case .furniture(let id) = selection,
                   let item = document.furnitureItem(for: id) {
                    FurnitureInspectorPanel(item: item) { newName in
                        guard let idx = document.furnitureItems.firstIndex(where: { $0.id == id }) else { return }
                        document.furnitureItems[idx].name = newName
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Contextual banner while in placeOpening mode
                if case .placeOpening(let kind) = mode {
                    PlaceOpeningBanner(kind: kind) {
                        mode = .select
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Contextual banner while in placeRoomLabel mode
                if mode == .placeRoomLabel {
                    PlaceRoomLabelBanner {
                        mode = .select
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Contextual banner while in drawRoomArea mode
                if mode == .drawRoomArea {
                    DrawRoomAreaBanner {
                        mode = .select
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Contextual banner while in placeFurniture mode
                if mode == .placeFurniture {
                    PlaceFurnitureBanner {
                        mode = .select
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                DrawingToolbar(
                    mode: $mode,
                    wallKind: $wallKind,
                    vertexSnapEnabled: $vertexSnapEnabled,
                    hasSelection: selection != .none,
                    onDelete: deleteSelected
                )
            }
            .animation(.spring(response: 0.3), value: selection)

            // Floating top bar. Keep a minimum top offset because iPad full-screen
            // covers can report a small/zero safe inset while the system menu bar
            // is still visually present.
            VStack(spacing: 0) {
                DrawingTopBar(
                    canUndo: !undoStack.isEmpty,
                    canRedo: !redoStack.isEmpty,
                    isExporting: isExporting,
                    exportMode: exportMode,
                    onExportModeChange: { exportMode = $0 },
                    onHelp: { showHelpSheet = true },
                    onCancel: { showCancelConfirm = true },
                    onUndo: performUndo,
                    onRedo: performRedo,
                    onDone: exportAndFinish
                )
                .frame(maxWidth: 640)
                .padding(.horizontal, 18)
                .padding(.top, max(geo.safeAreaInsets.top + 12, 28))
                Spacer()
            }

            if isExporting {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text(String(localized: "drawing.export.progress", defaultValue: "Preparing floorplan..."))
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
            }
        }
        .ignoresSafeArea()
        // Re-apply bottom safe area so the bottom toolbar isn't clipped.
        .ignoresSafeArea(edges: .bottom)
        .confirmationDialog(String(localized: "drawing.cancelDialog.title", defaultValue: "Cancel drawing?"),
                            isPresented: $showCancelConfirm,
                            titleVisibility: .visible) {
            Button(String(localized: "drawing.cancelDialog.discard", defaultValue: "Discard drawing"), role: .destructive) { dismiss() }
            Button(String(localized: "drawing.cancelDialog.continue", defaultValue: "Continue drawing"), role: .cancel) {}
        }
        .sheet(isPresented: $showRoomPicker) {
            RoomPickerSheet(
                rooms: homeKit.currentHome?.rooms ?? [],
                onPick: { room in
                    guard let position = pendingLabelPosition else { return }
                    let label = RoomLabel(
                        hmRoomUUID: room.uniqueIdentifier,
                        name: room.name,
                        position: position,
                        colorIndex: document.roomLabels.count
                    )
                    pushUndo()
                    document.roomLabels.append(label)
                    selection = .roomLabel(label.id)
                    pendingLabelPosition = nil
                    mode = .select
                },
                onCancel: {
                    pendingLabelPosition = nil
                    mode = .select
                }
            )
        }
        .sheet(isPresented: $showAreaRoomPicker) {
            RoomPickerSheet(
                rooms: homeKit.currentHome?.rooms ?? [],
                onPick: { room in
                    guard let rect = pendingAreaRect else { return }
                    // New areas are always created as polygons (4 draggable vertices from birth).
                    let initialPoints: [CGPoint] = [
                        CGPoint(x: rect.minX, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.maxX, y: rect.maxY),
                        CGPoint(x: rect.minX, y: rect.maxY)
                    ]
                    let area = RoomArea(
                        hmRoomUUID: room.uniqueIdentifier,
                        name: room.name,
                        rect: rect,
                        colorIndex: document.roomAreas.count,
                        points: initialPoints
                    )
                    pushUndo()
                    document.roomAreas.append(area)
                    selection = .roomArea(area.id)
                    pendingAreaRect = nil
                    mode = .select
                },
                onCancel: {
                    pendingAreaRect = nil
                    mode = .select
                }
            )
        }
        .sheet(isPresented: $showHelpSheet) {
            DrawingEditorHelpSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            guard !hasSeenDrawingHelp else { return }
            hasSeenDrawingHelp = true
            showHelpSheet = true
        }
        .suppressesIdleScreensaver(.drawingEditor)
        } // GeometryReader
    }

    // MARK: - Opening placement (called from canvas tap in placeOpening mode)

    /// Called by `DrawingCanvasView` when the user taps in `.placeOpening` mode.
    /// `canvasPoint` is already in canvas coordinate space.
    private func handlePlaceOpening(kind: OpeningKind, at canvasPoint: CGPoint) {
        let maxDist: CGFloat = 60
        guard let (wallID, t) = document.nearestWall(to: canvasPoint, maxDistance: maxDist) else { return }
        let defaultWidth: CGFloat = kind == .door ? 80 : 60
        let opening = PlacedOpening(wallID: wallID, t: t, kind: kind, width: defaultWidth)
        pushUndo()
        document.openings.append(opening)
        selection = .opening(opening.id)
        // Return to select mode so the user can inspect/move the placed opening
        mode = .select
    }

    // MARK: - Opening movement (drag along wall)

    /// Called repeatedly while the user drags a placed opening.
    /// Projects the raw canvas point onto the opening's host wall and updates `t`.
    /// Undo is pushed once on the first `.began` call from the canvas coordinator;
    /// subsequent `.changed` callbacks just mutate in place for smooth live feedback.
    private func handleMoveOpening(id: UUID, at canvasPoint: CGPoint) {
        guard let idx = document.openings.firstIndex(where: { $0.id == id }),
              let wall = document.wall(for: document.openings[idx].wallID) else { return }
        let proj = wall.project(canvasPoint)
        // Clamp away from wall endpoints so the opening never hangs off the edge
        document.openings[idx].t = max(0.05, min(0.95, proj.t))
    }

    // MARK: - Room label placement

    /// Called by `DrawingCanvasView` when the user taps in `.placeRoomLabel` mode.
    /// Saves the grid-snapped position and presents the HomeKit room picker.
    private func handlePlaceRoomLabel(at canvasPoint: CGPoint) {
        pendingLabelPosition = DrawingDocument.snap(canvasPoint)
        showRoomPicker = true
    }

    // MARK: - Room label movement

    /// Called repeatedly while the user drags a placed room label.
    /// The canvas coordinator already grid-snaps the point before calling this.
    private func handleMoveRoomLabel(id: UUID, at canvasPoint: CGPoint) {
        guard let idx = document.roomLabels.firstIndex(where: { $0.id == id }) else { return }
        document.roomLabels[idx].position = canvasPoint
    }

    // MARK: - Room area placement

    /// Called when the user finishes dragging to define a new room area rectangle.
    private func handleCommitRoomArea(rect: CGRect) {
        pendingAreaRect = rect
        showAreaRoomPicker = true
    }

    // MARK: - Room area movement

    /// Called repeatedly while the user drags a placed room area.
    /// `delta` is the total offset from the touch-down position.
    private func handleMoveRoomArea(id: UUID, delta: CGSize) {
        guard let idx = document.roomAreas.firstIndex(where: { $0.id == id }) else { return }
        guard let originalDoc = undoStack.last,
              let originalArea = originalDoc.roomArea(for: id) else {
            // Fallback: offset from current position
            document.roomAreas[idx].rect.origin.x += delta.width
            document.roomAreas[idx].rect.origin.y += delta.height
            if let pts = document.roomAreas[idx].points {
                document.roomAreas[idx].points = pts.map {
                    CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
                }
            }
            return
        }
        document.roomAreas[idx].rect.origin = CGPoint(
            x: originalArea.rect.origin.x + delta.width,
            y: originalArea.rect.origin.y + delta.height
        )
        // Move polygon vertices by the same delta
        if let originalPts = originalArea.points {
            document.roomAreas[idx].points = originalPts.map {
                CGPoint(x: $0.x + delta.width, y: $0.y + delta.height)
            }
        }
    }

    // MARK: - Room area resize

    /// Called repeatedly while the user drags a vertex handle to resize/reshape a room area.
    /// For rect-mode areas `newRect` re-applies the bounding box; for polygon areas
    /// the Coordinator passes a sentinel rect with `.null` origin and the vertex index
    /// encoded in size (see DrawingCanvasView `onResizeRoomArea` usage).
    /// Here we just store the rect for rect-mode (polygon vertex dragging is handled
    /// via `onMoveRoomAreaVertex`).
    private func handleResizeRoomArea(id: UUID, newRect: CGRect) {
        guard let idx = document.roomAreas.firstIndex(where: { $0.id == id }) else { return }
        document.roomAreas[idx].rect = newRect
        // For rect-mode areas, clear any stale points so they stay in sync.
        if document.roomAreas[idx].points == nil {
            // rect-only — nothing else to update
        }
    }

    // MARK: - Room area polygon vertex drag

    /// Called repeatedly while the user drags a polygon vertex.
    /// Moves the vertex at `vertexIndex` to `newPoint` and updates `rect` to the new bounding box.
    private func handleMoveRoomAreaVertex(id: UUID, vertexIndex: Int, to newPoint: CGPoint) {
        guard let idx = document.roomAreas.firstIndex(where: { $0.id == id }) else { return }
        // Auto-promote legacy rect-only areas to polygon on the first vertex drag.
        if document.roomAreas[idx].points == nil {
            document.roomAreas[idx].promoteToPolygon()
        }
        guard var pts = document.roomAreas[idx].points,
              vertexIndex < pts.count else { return }
        pts[vertexIndex] = newPoint
        document.roomAreas[idx].points = pts
        document.roomAreas[idx].rect = document.roomAreas[idx].boundingRect
    }

    // MARK: - Room area vertex insertion

    /// Called when the user taps a polygon edge to add a new vertex at that point.
    private func handleInsertRoomAreaVertex(id: UUID, edgeIndex: Int, at point: CGPoint) {
        guard let idx = document.roomAreas.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        document.roomAreas[idx].insertVertex(at: edgeIndex, point: point)
    }

    // MARK: - Room area vertex removal

    /// Called when the user double-taps a polygon vertex to remove it.
    /// Requires the area to have > 3 vertices (enforced also by the canvas coordinator).
    private func handleRemoveRoomAreaVertex(id: UUID, vertexIndex: Int) {
        guard let idx = document.roomAreas.firstIndex(where: { $0.id == id }),
              var pts = document.roomAreas[idx].points,
              pts.count > 3,
              vertexIndex < pts.count else { return }
        pushUndo()
        pts.remove(at: vertexIndex)
        document.roomAreas[idx].points = pts
        document.roomAreas[idx].rect = document.roomAreas[idx].boundingRect
    }

    // MARK: - Furniture placement

    /// Called when the user taps the canvas in `.placeFurniture` mode.
    /// Creates an 80×60pt rectangle centred on the tapped point, snapped to grid.
    private func handlePlaceFurniture(at canvasPoint: CGPoint) {
        let snapped = DrawingDocument.snap(canvasPoint)
        let defaultW: CGFloat = 80
        let defaultH: CGFloat = 60
        let rect = CGRect(
            x: snapped.x - defaultW / 2,
            y: snapped.y - defaultH / 2,
            width: defaultW,
            height: defaultH
        )
        let item = FurnitureItem(name: "Mobile", rect: rect)
        pushUndo()
        document.furnitureItems.append(item)
        selection = .furniture(item.id)
        mode = .select
    }

    // MARK: - Furniture movement

    /// Called repeatedly while the user drags a furniture item.
    /// Reads original rect from the undo snapshot to avoid delta drift.
    private func handleMoveFurniture(id: UUID, delta: CGSize) {
        guard let idx = document.furnitureItems.firstIndex(where: { $0.id == id }) else { return }
        guard let originalDoc = undoStack.last,
              let originalItem = originalDoc.furnitureItem(for: id) else {
            document.furnitureItems[idx].rect.origin.x += delta.width
            document.furnitureItems[idx].rect.origin.y += delta.height
            return
        }
        document.furnitureItems[idx].rect.origin = CGPoint(
            x: originalItem.rect.origin.x + delta.width,
            y: originalItem.rect.origin.y + delta.height
        )
    }

    // MARK: - Furniture resize

    /// Called repeatedly while the user drags a corner handle to resize a furniture item.
    /// `newRect` is already grid-snapped and minimum-enforced by the Coordinator.
    private func handleResizeFurniture(id: UUID, newRect: CGRect) {
        guard let idx = document.furnitureItems.firstIndex(where: { $0.id == id }) else { return }
        document.furnitureItems[idx].rect = newRect
    }

    // MARK: - Wall endpoint movement

    /// Called repeatedly while the user drags a wall endpoint.
    /// `endpointIndex` is 0 for start, 1 for end. `point` is already smartSnapped.
    private func handleMoveWallEndpoint(id: UUID, endpointIndex: Int, to point: CGPoint) {
        guard let idx = document.walls.firstIndex(where: { $0.id == id }) else { return }
        if endpointIndex == 0 {
            document.walls[idx].start = point
        } else {
            document.walls[idx].end = point
        }
    }

    // MARK: - Wall body movement

    /// Called repeatedly while the user drags the body of a wall.
    /// Reads original endpoints from the undo snapshot to avoid delta drift.
    private func handleMoveWall(id: UUID, delta: CGSize) {
        guard let idx = document.walls.firstIndex(where: { $0.id == id }) else { return }
        guard let originalDoc = undoStack.last,
              let originalWall = originalDoc.wall(for: id) else {
            // Fallback: offset from current position
            document.walls[idx].start.x += delta.width
            document.walls[idx].start.y += delta.height
            document.walls[idx].end.x   += delta.width
            document.walls[idx].end.y   += delta.height
            return
        }
        document.walls[idx].start = CGPoint(
            x: originalWall.start.x + delta.width,
            y: originalWall.start.y + delta.height
        )
        document.walls[idx].end = CGPoint(
            x: originalWall.end.x + delta.width,
            y: originalWall.end.y + delta.height
        )
    }

    // MARK: - Opening mutation (resize / flip)

    /// Applies a mutation to a specific opening without pushing undo (live slider).
    /// Call with `pushUndo: true` when the gesture ends.
    private func applyOpeningChange(id: UUID, mutation: (inout PlacedOpening) -> Void) {
        guard let idx = document.openings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&document.openings[idx])
    }

    // MARK: - Delete

    private func deleteSelected() {
        guard selection != .none else { return }
        pushUndo()
        document.delete(selection)
        selection = .none
    }

    // MARK: - Undo

    private func pushUndo() {
        undoStack.append(document)
        if undoStack.count > undoLimit {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        selection = .none
    }

    private func performRedo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        if undoStack.count > undoLimit {
            undoStack.removeFirst()
        }
        document = next
        selection = .none
    }

    // MARK: - Export

    private func exportAndFinish() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            await Task.yield()
            let (image, linkedRooms) = renderToImage(document, mode: exportMode)
            onComplete(image, linkedRooms, document)
            dismiss()
        }
    }

    private func renderToImage(_ doc: DrawingDocument, mode: DrawingExportMode) -> (UIImage, [LinkedRoom]) {
        switch mode {
        case .legacy:
            return renderToImage(doc)
        case .adaptive:
            return renderAdaptiveToImage(doc)
        }
    }

    /// Renders the document cropped to the drawing content with margin, scaled to
    /// the screen diagonal (width×height of the device screen), keeping the
    /// floorplan centred and well-proportioned.
    /// Also returns `[LinkedRoom]` with normalized rects relative to the exported image.
    private func renderToImage(_ doc: DrawingDocument) -> (UIImage, [LinkedRoom]) {
        var allPoints: [CGPoint] = doc.walls.flatMap { [$0.start, $0.end] }
                                  + doc.roomLabels.map(\.position)
        // Include all effective polygon vertices for each room area in the bounding box
        for area in doc.roomAreas {
            allPoints.append(contentsOf: area.effectivePoints)
        }
        // Include furniture item corners in bounding box
        for item in doc.furnitureItems {
            allPoints.append(CGPoint(x: item.rect.minX, y: item.rect.minY))
            allPoints.append(CGPoint(x: item.rect.maxX, y: item.rect.maxY))
        }

        // Output size = screen dimensions so the exported image matches the device display
        let screenBounds = UIScreen.main.bounds
        let outputW: CGFloat    = screenBounds.width
        let outputH: CGFloat    = screenBounds.height
        let scale: CGFloat      = 2.0   // @2x physical pixels
        let marginFraction: CGFloat = 0.08  // 8% padding around the drawing

        func blankImage() -> UIImage {
            let size = CGSize(width: outputW, height: outputH)
            let fmt  = UIGraphicsImageRendererFormat()
            fmt.scale = scale
            return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
        }

        guard !allPoints.isEmpty else { return (blankImage(), []) }

        let minX = allPoints.map(\.x).min()!
        let maxX = allPoints.map(\.x).max()!
        let minY = allPoints.map(\.y).min()!
        let maxY = allPoints.map(\.y).max()!

        let drawingW = maxX - minX
        let drawingH = maxY - minY
        let longestSide = max(drawingW, drawingH)
        guard longestSide > 0 else { return (blankImage(), []) }

        // Fit the padded floorplan inside the output rectangle (outputW × outputH),
        // centred, preserving aspect ratio (uniform scale = fit to shorter dimension ratio).
        let margin       = longestSide * marginFraction
        let paddedW      = drawingW + margin * 2
        let paddedH      = drawingH + margin * 2
        // Scale to fill the output size while keeping the drawing proportioned
        let scaleFactor  = min(outputW / paddedW, outputH / paddedH)

        // Centre of the bounding box in canvas space
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        // How much canvas space the output rectangle covers at this scale
        let cropW = outputW / scaleFactor
        let cropH = outputH / scaleFactor

        // Top-left corner of the crop region in canvas space (centred on drawing)
        let originX = centerX - cropW / 2
        let originY = centerY - cropH / 2

        // Build LinkedRoom list with normalized rects (and optional polygon vertices).
        // Normalise coords by the crop dimensions so [0,1] maps exactly to the image edges.
        let linkedRooms: [LinkedRoom] = doc.roomAreas.compactMap { area in
            guard let hmUUID = area.hmRoomUUID else { return nil }
            let normX = Double((area.rect.minX - originX) / cropW)
            let normY = Double((area.rect.minY - originY) / cropH)
            let normW = Double(area.rect.width  / cropW)
            let normH = Double(area.rect.height / cropH)
            // Normalize polygon vertices when present
            let normalizedPoints: [CodablePoint]? = area.points.map { pts in
                pts.map { CodablePoint(
                    x: Double(($0.x - originX) / cropW),
                    y: Double(($0.y - originY) / cropH)
                )}
            }
            return LinkedRoom(
                hmRoomUUID: hmUUID,
                name: area.name,
                normalizedRect: CodableRect(x: normX, y: normY, width: normW, height: normH),
                normalizedPoints: normalizedPoints
            )
        }

        let outputSize = CGSize(width: outputW, height: outputH)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: fmt)

        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext

            // White background
            cgCtx.setFillColor(UIColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: outputSize))

            // Transform: shift to crop origin, then scale to fit output size
            cgCtx.translateBy(x: -originX * scaleFactor, y: -originY * scaleFactor)
            cgCtx.scaleBy(x: scaleFactor, y: scaleFactor)

            renderDocument(doc, in: cgCtx, canvasSize: DrawingDocument.canvasSize)
        }
        return (image, linkedRooms)
    }

    /// Parallel export pipeline for test floorplans. It keeps the same crop/fit
    /// strategy as legacy but renders into a deterministic landscape canvas so the
    /// result is not tied to the current device orientation or split-view size.
    private func renderAdaptiveToImage(_ doc: DrawingDocument) -> (UIImage, [LinkedRoom]) {
        var allPoints: [CGPoint] = doc.walls.flatMap { [$0.start, $0.end] }
                                  + doc.roomLabels.map(\.position)
        for area in doc.roomAreas {
            allPoints.append(contentsOf: area.effectivePoints)
        }
        for item in doc.furnitureItems {
            allPoints.append(CGPoint(x: item.rect.minX, y: item.rect.minY))
            allPoints.append(CGPoint(x: item.rect.maxX, y: item.rect.maxY))
        }

        let outputW: CGFloat = 1600
        let outputH: CGFloat = 1000
        let scale: CGFloat = 2.0
        let marginFraction: CGFloat = 0.10

        func blankImage() -> UIImage {
            let size = CGSize(width: outputW, height: outputH)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = scale
            return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
        }

        guard !allPoints.isEmpty else { return (blankImage(), []) }

        let minX = allPoints.map(\.x).min()!
        let maxX = allPoints.map(\.x).max()!
        let minY = allPoints.map(\.y).min()!
        let maxY = allPoints.map(\.y).max()!

        let drawingW = maxX - minX
        let drawingH = maxY - minY
        let longestSide = max(drawingW, drawingH)
        guard longestSide > 0 else { return (blankImage(), []) }

        let margin = longestSide * marginFraction
        let paddedW = drawingW + margin * 2
        let paddedH = drawingH + margin * 2
        let scaleFactor = min(outputW / paddedW, outputH / paddedH)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let cropW = outputW / scaleFactor
        let cropH = outputH / scaleFactor
        let originX = centerX - cropW / 2
        let originY = centerY - cropH / 2

        let linkedRooms: [LinkedRoom] = doc.roomAreas.compactMap { area in
            guard let hmUUID = area.hmRoomUUID else { return nil }
            let normX = Double((area.rect.minX - originX) / cropW)
            let normY = Double((area.rect.minY - originY) / cropH)
            let normW = Double(area.rect.width / cropW)
            let normH = Double(area.rect.height / cropH)
            let normalizedPoints: [CodablePoint]? = area.points.map { pts in
                pts.map { CodablePoint(
                    x: Double(($0.x - originX) / cropW),
                    y: Double(($0.y - originY) / cropH)
                )}
            }
            return LinkedRoom(
                hmRoomUUID: hmUUID,
                name: area.name,
                normalizedRect: CodableRect(x: normX, y: normY, width: normW, height: normH),
                normalizedPoints: normalizedPoints
            )
        }

        let outputSize = CGSize(width: outputW, height: outputH)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: fmt)

        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.setFillColor(UIColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: outputSize))
            cgCtx.translateBy(x: -originX * scaleFactor, y: -originY * scaleFactor)
            cgCtx.scaleBy(x: scaleFactor, y: scaleFactor)
            renderDocument(doc, in: cgCtx, canvasSize: DrawingDocument.canvasSize)
        }
        return (image, linkedRooms)
    }
}

// MARK: - Preview

#Preview {
    DrawingFloorplanSheet { _, _, _ in }
}
