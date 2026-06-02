import SwiftUI
import UIKit
import HomeKit

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
    private let undoLimit = 30

    // MARK: Alert for cancel confirmation

    @State private var showCancelConfirm = false

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
        ZStack(alignment: .bottom) {
            // Canvas (fills entire screen)
            DrawingCanvasView(
                document:  $document,
                mode:      $mode,
                selection: $selection,
                wallKind:  $wallKind,
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
                onPlaceFurniture: handlePlaceFurniture(at:),
                onBeginMoveFurniture: { _ in pushUndo() },
                onMoveFurniture: handleMoveFurniture(id:delta:),
                onBeginResizeFurniture: { _ in pushUndo() },
                onResizeFurniture: handleResizeFurniture(id:newRect:),
                onBeginMoveWallEndpoint: { _ in pushUndo() },
                onMoveWallEndpoint: handleMoveWallEndpoint(id:endpointIndex:to:)
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
                    hasSelection: selection != .none,
                    onDelete: deleteSelected
                )
            }
            .animation(.spring(response: 0.3), value: selection)

            // Top bar pinned at the top of the full-screen ZStack.
            // geo.safeAreaInsets.top gives the real status-bar / Dynamic Island
            // height so buttons are never hidden behind system UI.
            VStack(spacing: 0) {
                DrawingTopBar(
                    canUndo: !undoStack.isEmpty,
                    onCancel: { showCancelConfirm = true },
                    onUndo: performUndo,
                    onDone: exportAndFinish
                )
                .padding(.top, geo.safeAreaInsets.top)
                Spacer()
            }
        }
        .ignoresSafeArea()
        // Re-apply bottom safe area so the bottom toolbar isn't clipped.
        .ignoresSafeArea(edges: .bottom)
        .confirmationDialog("Vuoi annullare il disegno?",
                            isPresented: $showCancelConfirm,
                            titleVisibility: .visible) {
            Button("Annulla disegno", role: .destructive) { dismiss() }
            Button("Continua a disegnare", role: .cancel) {}
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
                    let area = RoomArea(
                        hmRoomUUID: room.uniqueIdentifier,
                        name: room.name,
                        rect: rect,
                        colorIndex: document.roomAreas.count
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
        // We keep a baseline origin in the undo snapshot; just apply delta from it.
        // Since the undo snapshot is pushed in onBeginMoveRoomArea, the document at
        // that moment is undoStack.last. We read the original rect from there to
        // avoid drift from accumulating tiny deltas.
        guard let originalDoc = undoStack.last,
              let originalArea = originalDoc.roomArea(for: id) else {
            // Fallback: just offset from current (less accurate but safe)
            document.roomAreas[idx].rect.origin.x += delta.width
            document.roomAreas[idx].rect.origin.y += delta.height
            return
        }
        document.roomAreas[idx].rect.origin = CGPoint(
            x: originalArea.rect.origin.x + delta.width,
            y: originalArea.rect.origin.y + delta.height
        )
    }

    // MARK: - Room area resize

    /// Called repeatedly while the user drags a corner handle to resize a room area.
    /// `newRect` is already grid-snapped and minimum-enforced by the Coordinator.
    private func handleResizeRoomArea(id: UUID, newRect: CGRect) {
        guard let idx = document.roomAreas.firstIndex(where: { $0.id == id }) else { return }
        document.roomAreas[idx].rect = newRect
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
    }

    private func performUndo() {
        guard let previous = undoStack.popLast() else { return }
        document = previous
        selection = .none
    }

    // MARK: - Export

    private func exportAndFinish() {
        let (image, linkedRooms) = renderToImage(document)
        onComplete(image, linkedRooms, document)
        dismiss()
    }

    /// Renders the document cropped to the drawing content with margin, scaled to
    /// a fixed output size suitable for iPad display (2048pt @2x = 4096px).
    /// Also returns `[LinkedRoom]` with normalized rects relative to the exported image.
    private func renderToImage(_ doc: DrawingDocument) -> (UIImage, [LinkedRoom]) {
        var allPoints: [CGPoint] = doc.walls.flatMap { [$0.start, $0.end] }
                                  + doc.roomLabels.map(\.position)
        // Include room area corners in bounding box
        for area in doc.roomAreas {
            allPoints.append(CGPoint(x: area.rect.minX, y: area.rect.minY))
            allPoints.append(CGPoint(x: area.rect.maxX, y: area.rect.maxY))
        }
        // Include furniture item corners in bounding box
        for item in doc.furnitureItems {
            allPoints.append(CGPoint(x: item.rect.minX, y: item.rect.minY))
            allPoints.append(CGPoint(x: item.rect.maxX, y: item.rect.maxY))
        }

        let outputPt: CGFloat   = 2048   // logical points for the output image
        let scale: CGFloat      = 2.0    // @2x = 4096 physical pixels
        let marginFraction: CGFloat = 0.08  // 8% padding on each side

        func blankImage() -> UIImage {
            let size = CGSize(width: outputPt, height: outputPt)
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

        // Square crop region: side = longest dimension + uniform margin on all 4 sides.
        let margin      = longestSide * marginFraction
        let paddedSide  = longestSide + margin * 2
        let scaleFactor = outputPt / paddedSide

        // Centre of the bounding box in canvas space
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        // Top-left corner of the square crop region in canvas space
        let originX = centerX - paddedSide / 2
        let originY = centerY - paddedSide / 2

        // Build LinkedRoom list with normalized rects
        let linkedRooms: [LinkedRoom] = doc.roomAreas.compactMap { area in
            guard let hmUUID = area.hmRoomUUID else { return nil }
            let normX = Double((area.rect.minX - originX) / paddedSide)
            let normY = Double((area.rect.minY - originY) / paddedSide)
            let normW = Double(area.rect.width  / paddedSide)
            let normH = Double(area.rect.height / paddedSide)
            return LinkedRoom(
                hmRoomUUID: hmUUID,
                name: area.name,
                normalizedRect: CodableRect(x: normX, y: normY, width: normW, height: normH)
            )
        }

        let outputSize = CGSize(width: outputPt, height: outputPt)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: fmt)

        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext

            // White background
            cgCtx.setFillColor(UIColor.white.cgColor)
            cgCtx.fill(CGRect(origin: .zero, size: outputSize))

            // Transform: shift to crop origin, then scale to fit outputPt
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
