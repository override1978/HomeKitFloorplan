import SwiftUI
import UIKit

// MARK: - DrawingCanvasView

/// `UIViewRepresentable` wrapping a `UIScrollView` for pinch-zoom + pan,
/// hosting `DrawingCanvasContent` (SwiftUI Canvas) inside it.
///
/// Gesture modes:
/// - **draw**: long-press/drag draws a new wall. Pan disabled.
/// - **select**: pan enabled. Tap selects. Drag on a selected opening/label/area slides it.
/// - **placeOpening**: tap places door/window on nearest wall.
/// - **placeRoomLabel**: tap places a room label at the tapped point.
/// - **drawRoomArea**: long-press/drag draws a room area rectangle. Pan disabled.
struct DrawingCanvasView: UIViewRepresentable {

    @Binding var document: DrawingDocument
    @Binding var mode: DrawingMode
    @Binding var selection: DrawingSelection
    /// The wall kind to use when committing a new wall in draw mode.
    @Binding var wallKind: WallKind
    /// When true, wall drawing/endpoint dragging use vertex snap first (30pt radius).
    /// When false, only 20pt grid snap is applied.
    var vertexSnapEnabled: Bool
    /// When false, wall dimension labels are hidden on the canvas.
    var showDimensions: Bool

    var onCommit: (DrawingDocument) -> Void
    var onPlaceOpening: (OpeningKind, CGPoint) -> Void
    /// Called when the user taps to place a room label (canvas-space point).
    var onPlaceRoomLabel: (CGPoint) -> Void
    /// Called once when the user begins dragging an opening (used to push undo).
    var onBeginMoveOpening: (UUID) -> Void
    /// Called when an opening is dragged to a new position (canvas-space point).
    var onMoveOpening: (UUID, CGPoint) -> Void
    /// Called once when the user begins dragging a room label (used to push undo).
    var onBeginMoveRoomLabel: (UUID) -> Void
    /// Called when a room label is dragged to a new position (canvas-space point).
    var onMoveRoomLabel: (UUID, CGPoint) -> Void
    /// Called when a room area drag is committed (canvas-space rect).
    var onCommitRoomArea: (CGRect) -> Void
    /// Called once when the user begins dragging a room area (used to push undo).
    var onBeginMoveRoomArea: (UUID) -> Void
    /// Called when a room area is dragged by a delta (translation CGSize).
    var onMoveRoomArea: (UUID, CGSize) -> Void
    /// Called once when the user begins resizing a room area corner (used to push undo).
    var onBeginResizeRoomArea: (UUID) -> Void
    /// Called when a room area corner is dragged to resize (new rect in canvas coords).
    var onResizeRoomArea: (UUID, CGRect) -> Void
    /// Called when a polygon vertex of a room area is dragged to a new position.
    /// - Parameters:
    ///   - id: the room area UUID
    ///   - vertexIndex: index into `area.effectivePoints`
    ///   - point: new canvas-space position (fine-snapped)
    var onMoveRoomAreaVertex: ((UUID, Int, CGPoint) -> Void)?
    /// Called when the user taps on a polygon edge of a selected room area to insert a new vertex.
    /// - Parameters:
    ///   - id: the room area UUID
    ///   - edgeIndex: index of the first vertex of the tapped edge
    ///   - point: insertion point in canvas space (fine-snapped, projected onto the edge)
    var onInsertRoomAreaVertex: ((UUID, Int, CGPoint) -> Void)?
    /// Called when the user double-taps a polygon vertex of a selected room area to remove it.
    /// Only fired when the area has > 3 vertices so the polygon remains valid.
    var onRemoveRoomAreaVertex: ((UUID, Int) -> Void)?
    /// Called when the user taps to place a furniture item (canvas-space point).
    var onPlaceFurniture: (CGPoint) -> Void
    /// Called once when the user begins dragging a furniture item (used to push undo).
    var onBeginMoveFurniture: (UUID) -> Void
    /// Called when a furniture item is dragged by a delta (translation CGSize).
    var onMoveFurniture: (UUID, CGSize) -> Void
    /// Called once when the user begins resizing a furniture item corner (used to push undo).
    var onBeginResizeFurniture: (UUID) -> Void
    /// Called when a furniture item corner is dragged to resize (new rect in canvas coords).
    var onResizeFurniture: (UUID, CGRect) -> Void
    /// Called once when the user begins dragging a wall endpoint (used to push undo).
    var onBeginMoveWallEndpoint: ((UUID) -> Void)?
    /// Called when a wall endpoint is dragged to a new position.
    /// - Parameters:
    ///   - id: the wall's UUID
    ///   - endpointIndex: 0 = start, 1 = end
    ///   - point: new canvas-space position (smartSnapped)
    var onMoveWallEndpoint: ((UUID, Int, CGPoint) -> Void)?
    /// Called once when the user begins dragging the body of a wall (used to push undo).
    var onBeginMoveWall: ((UUID) -> Void)?
    /// Called while the user drags the body of a wall to translate it.
    /// `delta` is the offset from the touch-down position (anti-drift pattern).
    var onMoveWall: ((UUID, CGSize) -> Void)?

    // MARK: makeUIView

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.backgroundColor = .white
        sv.minimumZoomScale = 0.3
        sv.maximumZoomScale = 4.0
        sv.zoomScale = 0.6
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator   = false
        sv.delegate    = context.coordinator
        sv.bouncesZoom = true

        let size = DrawingDocument.canvasSize
        sv.contentSize = CGSize(width: size, height: size)

        let hostVC = context.coordinator.makeHostingController()
        hostVC.view.frame           = CGRect(x: 0, y: 0, width: size, height: size)
        hostVC.view.backgroundColor = .white
        sv.addSubview(hostVC.view)
        context.coordinator.hostedView = hostVC.view

        // Main gesture: zero-delay long-press used for both drawing and dragging
        let mainGesture = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMainGesture(_:))
        )
        mainGesture.minimumPressDuration = 0
        mainGesture.delegate = context.coordinator
        sv.addGestureRecognizer(mainGesture)
        context.coordinator.mainGesture = mainGesture

        // Double-tap: remove polygon vertex on selected room area
        let doubleTapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.delegate = context.coordinator
        sv.addGestureRecognizer(doubleTapGesture)
        context.coordinator.doubleTapGesture = doubleTapGesture

        // Single-tap for selection / placeOpening / placeRoomLabel
        // Requires the double-tap to fail so a quick double-tap doesn't trigger both.
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tapGesture.require(toFail: doubleTapGesture)
        sv.addGestureRecognizer(tapGesture)

        return sv
    }

    // MARK: updateUIView

    func updateUIView(_ sv: UIScrollView, context: Context) {
        let panDisabled: Bool
        if case .draw = mode { panDisabled = true }
        else if case .drawRoomArea = mode { panDisabled = true }
        else { panDisabled = false }

        sv.panGestureRecognizer.isEnabled  = !panDisabled
        let gestureEnabled: Bool
        switch mode {
        case .draw, .select, .drawRoomArea: gestureEnabled = true
        default: gestureEnabled = false
        }
        context.coordinator.mainGesture?.isEnabled = gestureEnabled
        context.coordinator.vertexSnapEnabled = vertexSnapEnabled
        context.coordinator.showDimensions    = showDimensions

        context.coordinator.updateContent(document: document, mode: mode, selection: selection)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {

        var parent: DrawingCanvasView
        var hostedView: UIView?
        weak var mainGesture: UILongPressGestureRecognizer?
        weak var doubleTapGesture: UITapGestureRecognizer?

        // Draw wall state
        private var drawStartPoint: CGPoint?
        private var drawTouchStartPoint: CGPoint?
        private var didExceedDrawDragThreshold = false
        private var pendingTapWallStart: CGPoint?
        private var pendingTapWallKind: WallKind?
        private var currentPreviewWall: WallSegment?
        private var currentCursor: CGPoint?
        private var currentIsVertexSnap: Bool = false

        // Draw room area state
        private var drawAreaStart: CGPoint?
        private var currentPreviewArea: CGRect?

        // Drag state
        private var draggingOpeningID: UUID?
        private var draggingRoomLabelID: UUID?
        private var draggingRoomAreaID: UUID?
        private var dragAreaTouchStart: CGPoint?   // touch position at drag start (for delta)

        // Resize room area state
        private var resizingRoomAreaID: UUID?
        private var resizingCornerIndex: Int?      // 0=TL, 1=TR, 2=BL, 3=BR
        private var resizeOriginalRect: CGRect?

        // Drag/resize furniture state
        private var draggingFurnitureID: UUID?
        private var dragFurnitureTouchStart: CGPoint?
        private var resizingFurnitureID: UUID?
        private var resizingFurnitureCornerIndex: Int?
        private var resizeFurnitureOriginalRect: CGRect?
        private var resizeFurnitureRotationDegrees: Double = 0

        // Drag wall endpoint state
        private var draggingWallEndpointID: UUID?
        private var draggingEndpointIndex: Int?   // 0 = start, 1 = end

        // Drag whole-wall state
        private var draggingWallID: UUID?
        private var dragWallTouchStart: CGPoint?

        /// Mirrors `DrawingCanvasView.vertexSnapEnabled`; updated in `updateUIView`.
        var vertexSnapEnabled: Bool = true
        /// Mirrors `DrawingCanvasView.showDimensions`; updated in `updateUIView`.
        var showDimensions: Bool = false

        private var contentState = DrawingContentState()

        init(parent: DrawingCanvasView) { self.parent = parent }

        // MARK: Snap helper

        /// Returns either smartSnap (vertex-first) or plain grid snap depending on the toggle.
        private func performSnap(_ point: CGPoint) -> SnapResult {
            if vertexSnapEnabled {
                return parent.document.smartSnap(point)
            } else {
                return .grid(DrawingDocument.snap(point))
            }
        }

        private func angleSnappedEnd(from start: CGPoint, to end: CGPoint, snapResult: SnapResult) -> CGPoint {
            guard !snapResult.isVertex else { return end }

            let dx = end.x - start.x
            let dy = end.y - start.y
            guard hypot(dx, dy) >= DrawingDocument.gridSpacing else { return end }

            let angle = atan2(dy, dx)
            let octant = CGFloat(Int(round(angle / (.pi / 4))))
            let snappedAngle = octant * (.pi / 4)
            let directionX = cos(snappedAngle)
            let directionY = sin(snappedAngle)

            if abs(directionY) < 0.001 {
                return CGPoint(x: end.x, y: start.y)
            }
            if abs(directionX) < 0.001 {
                return CGPoint(x: start.x, y: end.y)
            }

            let diagonalLength = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (directionX > 0 ? diagonalLength : -diagonalLength),
                           y: start.y + (directionY > 0 ? diagonalLength : -diagonalLength))
        }

        func makeHostingController() -> UIHostingController<DrawingContentWrapper> {
            UIHostingController(rootView: DrawingContentWrapper(state: contentState))
        }

        func updateContent(document: DrawingDocument, mode: DrawingMode, selection: DrawingSelection) {
            if mode != .draw {
                clearPendingTapWall()
            }
            contentState.document        = document
            contentState.mode            = mode
            contentState.selection       = selection
            contentState.previewWall     = currentPreviewWall
            contentState.previewArea     = currentPreviewArea
            contentState.cursorPoint     = currentCursor
            contentState.isVertexSnap    = currentIsVertexSnap
            contentState.showDimensions  = showDimensions
        }

        // MARK: Zoom centering

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { hostedView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let view = hostedView else { return }
            let offsetX = max((scrollView.bounds.width  - view.frame.width)  / 2, 0)
            let offsetY = max((scrollView.bounds.height - view.frame.height) / 2, 0)
            view.frame.origin = CGPoint(x: offsetX, y: offsetY)
        }

        // MARK: Main gesture (draw walls OR drag openings/labels)

        @objc func handleMainGesture(_ gr: UILongPressGestureRecognizer) {
            let rawPoint = gr.location(in: hostedView)

            switch parent.mode {
            case .draw:
                handleDrawGesture(gr, rawPoint: rawPoint)
            case .select:
                handleDragGesture(gr, rawPoint: rawPoint)
            case .drawRoomArea:
                handleDrawAreaGesture(gr, rawPoint: rawPoint)
            default:
                break
            }
        }

        // MARK: Draw walls

        private func handleDrawGesture(_ gr: UILongPressGestureRecognizer, rawPoint: CGPoint) {
            let snapResult = performSnap(rawPoint)
            let snapped = snapResult.point

            switch gr.state {
            case .began:
                drawStartPoint      = snapped
                drawTouchStartPoint = rawPoint
                didExceedDrawDragThreshold = false
                currentCursor       = snapped
                currentIsVertexSnap = snapResult.isVertex
                refreshPreview()
            case .changed:
                let constrained = drawStartPoint.map {
                    angleSnappedEnd(from: $0, to: snapped, snapResult: snapResult)
                } ?? snapped
                currentCursor       = constrained
                currentIsVertexSnap = snapResult.isVertex
                if let touchStart = drawTouchStartPoint,
                   hypot(rawPoint.x - touchStart.x, rawPoint.y - touchStart.y) > canvasThreshold(10) {
                    didExceedDrawDragThreshold = true
                }
                if didExceedDrawDragThreshold, let start = drawStartPoint {
                    pendingTapWallStart = nil
                    pendingTapWallKind  = nil
                    currentPreviewWall = WallSegment(start: start, end: constrained,
                                                     kind: parent.wallKind)
                }
                refreshPreview()
            case .ended, .cancelled, .failed:
                if gr.state == .ended {
                    if didExceedDrawDragThreshold {
                        if let start = drawStartPoint {
                            let constrained = angleSnappedEnd(from: start, to: snapped, snapResult: snapResult)
                            if start != constrained {
                                commitWall(start: start, end: constrained, kind: parent.wallKind)
                            }
                        }
                        clearPendingTapWall()
                    } else {
                        handleTapWallPoint(snapped, snapResult: snapResult)
                    }
                } else if didExceedDrawDragThreshold {
                    clearPendingTapWall()
                }
                drawStartPoint      = nil
                drawTouchStartPoint = nil
                didExceedDrawDragThreshold = false
                currentPreviewWall  = nil
                if pendingTapWallStart == nil {
                    currentCursor       = nil
                    currentIsVertexSnap = false
                }
                refreshPreview()
            default:
                break
            }
        }

        private func handleTapWallPoint(_ point: CGPoint, snapResult: SnapResult) {
            if let start = pendingTapWallStart {
                let constrained = angleSnappedEnd(from: start, to: point, snapResult: snapResult)
                if start != constrained {
                    commitWall(start: start, end: constrained, kind: pendingTapWallKind ?? parent.wallKind)
                }
                clearPendingTapWall()
            } else {
                pendingTapWallStart = point
                pendingTapWallKind  = parent.wallKind
                currentCursor       = point
                currentIsVertexSnap = snapResult.isVertex
            }
        }

        private func commitWall(start: CGPoint, end: CGPoint, kind: WallKind) {
            var newDoc = parent.document
            newDoc.walls.append(WallSegment(start: start, end: end, kind: kind))
            parent.onCommit(newDoc)
        }

        private func clearPendingTapWall() {
            pendingTapWallStart = nil
            pendingTapWallKind  = nil
            currentCursor       = nil
            currentIsVertexSnap = false
            currentPreviewWall  = nil
        }

        // MARK: Draw room area

        private func handleDrawAreaGesture(_ gr: UILongPressGestureRecognizer, rawPoint: CGPoint) {
            let snapped = DrawingDocument.snap(rawPoint)

            switch gr.state {
            case .began:
                drawAreaStart       = snapped
                currentPreviewArea  = CGRect(origin: snapped, size: .zero)
                contentState.previewArea = currentPreviewArea
            case .changed:
                guard let start = drawAreaStart else { return }
                let minX = min(start.x, snapped.x)
                let minY = min(start.y, snapped.y)
                let w    = abs(snapped.x - start.x)
                let h    = abs(snapped.y - start.y)
                currentPreviewArea = CGRect(x: minX, y: minY, width: w, height: h)
                contentState.previewArea = currentPreviewArea
            case .ended, .cancelled, .failed:
                if let rect = currentPreviewArea, rect.width > 40, rect.height > 40 {
                    parent.onCommitRoomArea(rect)
                }
                drawAreaStart      = nil
                currentPreviewArea = nil
                contentState.previewArea = nil
            default:
                break
            }
        }

        // MARK: Drag openings or room labels

        private func handleDragGesture(_ gr: UILongPressGestureRecognizer, rawPoint: CGPoint) {
            switch gr.state {
            case .began:
                // Check room area corners first (resize takes priority over move)
                if case .roomArea(let id) = parent.selection,
                   let area = parent.document.roomArea(for: id) {
                    if let cornerIdx = hitVertex(point: rawPoint, in: area) {
                        resizingRoomAreaID  = id
                        resizingCornerIndex = cornerIdx
                        resizeOriginalRect  = area.rect
                        parent.onBeginResizeRoomArea(id)
                        return
                    }
                    // Not near a vertex — check if inside the area for move
                    if area.contains(rawPoint) {
                        draggingRoomAreaID = id
                        dragAreaTouchStart = rawPoint
                        parent.onBeginMoveRoomArea(id)
                        return
                    }
                }
                // Check furniture item corners first (resize), then body (move)
                if case .furniture(let id) = parent.selection,
                   let item = parent.document.furnitureItem(for: id) {
                    if let cornerIdx = hitCorner(point: rawPoint, in: item) {
                        resizingFurnitureID = id
                        resizingFurnitureCornerIndex = cornerIdx
                        resizeFurnitureOriginalRect  = item.rect
                        resizeFurnitureRotationDegrees = item.rotationDegrees
                        parent.onBeginResizeFurniture(id)
                        return
                    }
                    if item.containsVisualPoint(rawPoint) {
                        draggingFurnitureID = id
                        dragFurnitureTouchStart = rawPoint
                        parent.onBeginMoveFurniture(id)
                        return
                    }
                }
                // Check room labels
                if case .roomLabel(let id) = parent.selection,
                   let label = parent.document.roomLabel(for: id),
                   hypot(rawPoint.x - label.position.x, rawPoint.y - label.position.y) < 40 {
                    draggingRoomLabelID = id
                    parent.onBeginMoveRoomLabel(id)
                    return
                }
                // Then openings
                if case .opening(let id) = parent.selection,
                   let opening = parent.document.opening(for: id),
                   let eps = parent.document.openingEndpoints(opening) {
                    let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2,
                                      y: (eps.start.y + eps.end.y) / 2)
                    if hypot(rawPoint.x - mid.x, rawPoint.y - mid.y) < 40 {
                        draggingOpeningID = id
                        parent.onBeginMoveOpening(id)
                    }
                }
                // Wall endpoint drag — hit-test start/end circles when a wall is selected,
                // then fall back to whole-wall body drag.
                if case .wall(let id) = parent.selection,
                   let wall = parent.document.wall(for: id) {
                    let distToStart = hypot(rawPoint.x - wall.start.x, rawPoint.y - wall.start.y)
                    let distToEnd   = hypot(rawPoint.x - wall.end.x,   rawPoint.y - wall.end.y)
                    if distToStart < 20 {
                        draggingWallEndpointID = id
                        draggingEndpointIndex  = 0
                        parent.onBeginMoveWallEndpoint?(id)
                    } else if distToEnd < 20 {
                        draggingWallEndpointID = id
                        draggingEndpointIndex  = 1
                        parent.onBeginMoveWallEndpoint?(id)
                    } else {
                        // No endpoint handle hit — check if the touch is on the wall body
                        let proj = wall.project(rawPoint)
                        let tolerance = DrawingDocument.wallWidth(for: wall.kind) / 2 + 6
                        if proj.distance < tolerance {
                            draggingWallID      = id
                            dragWallTouchStart  = rawPoint
                            parent.onBeginMoveWall?(id)
                        }
                    }
                }
            case .changed:
                // Resize furniture
                if let id = resizingFurnitureID,
                   let cornerIdx = resizingFurnitureCornerIndex,
                   let originalRect = resizeFurnitureOriginalRect {
                    let unrotatedPoint = FurnitureItem.rotate(
                        rawPoint,
                        around: originalRect.center,
                        degrees: -resizeFurnitureRotationDegrees
                    )
                    let snapped = DrawingDocument.fineSnap(unrotatedPoint)
                    let newRect = computeResizedRect(original: originalRect,
                                                     cornerIndex: cornerIdx,
                                                     newCornerPosition: snapped,
                                                     minSize: 40)
                    parent.onResizeFurniture(id, newRect)
                    return
                }
                // Move furniture
                if let id = draggingFurnitureID, let touchStart = dragFurnitureTouchStart {
                    let delta = CGSize(width: rawPoint.x - touchStart.x,
                                       height: rawPoint.y - touchStart.y)
                    parent.onMoveFurniture(id, delta)
                    return
                }
                // Resize / reshape room area vertex
                if let id = resizingRoomAreaID,
                   let cornerIdx = resizingCornerIndex {
                    let snapped = DrawingDocument.fineSnap(rawPoint)
                    // Always delegate to handleMoveRoomAreaVertex which auto-promotes
                    // legacy rect areas to polygon on the first vertex drag.
                    parent.onMoveRoomAreaVertex?(id, cornerIdx, snapped)
                    return
                }
                if let id = draggingRoomAreaID, let touchStart = dragAreaTouchStart {
                    let delta = CGSize(width: rawPoint.x - touchStart.x,
                                       height: rawPoint.y - touchStart.y)
                    parent.onMoveRoomArea(id, delta)
                    return
                }
                if let id = draggingRoomLabelID {
                    let snapped = DrawingDocument.snap(rawPoint)
                    parent.onMoveRoomLabel(id, snapped)
                    return
                }
                if let id = draggingOpeningID {
                    parent.onMoveOpening(id, rawPoint)
                    return
                }
                // Move wall endpoint
                if let id = draggingWallEndpointID, let epIdx = draggingEndpointIndex {
                    let snapResult = performSnap(rawPoint)
                    var snapped = snapResult.point
                    var axisGuide: (from: CGPoint, to: CGPoint)? = nil
                    if !snapResult.isVertex, let axisResult = parent.document.axisSnap(rawPoint) {
                        // Axis snap fires: lock one coordinate, grid-snap the free axis.
                        snapped = DrawingDocument.snap(axisResult.point)
                        axisGuide = (from: axisResult.referenceVertex, to: snapped)
                    } else if let wall = parent.document.wall(for: id) {
                        let anchor = epIdx == 0 ? wall.end : wall.start
                        snapped = angleSnappedEnd(from: anchor, to: snapped, snapResult: snapResult)
                    }
                    contentState.axisSnapGuide = axisGuide
                    parent.onMoveWallEndpoint?(id, epIdx, snapped)
                }
                // Move whole wall
                if let id = draggingWallID, let touchStart = dragWallTouchStart {
                    let delta = CGSize(width: rawPoint.x - touchStart.x,
                                       height: rawPoint.y - touchStart.y)
                    parent.onMoveWall?(id, delta)
                }
            case .ended, .cancelled, .failed:
                draggingOpeningID            = nil
                draggingRoomLabelID          = nil
                draggingRoomAreaID           = nil
                dragAreaTouchStart           = nil
                resizingRoomAreaID           = nil
                resizingCornerIndex          = nil
                resizeOriginalRect           = nil
                draggingFurnitureID          = nil
                dragFurnitureTouchStart      = nil
                resizingFurnitureID          = nil
                resizingFurnitureCornerIndex = nil
                resizeFurnitureOriginalRect  = nil
                resizeFurnitureRotationDegrees = 0
                draggingWallEndpointID       = nil
                draggingEndpointIndex        = nil
                draggingWallID               = nil
                dragWallTouchStart           = nil
                contentState.axisSnapGuide   = nil
            default:
                break
            }
        }

        // MARK: Resize helpers

        /// Current zoom scale of the hosting scroll view (1.0 if unavailable).
        private var currentZoomScale: CGFloat {
            (hostedView?.superview as? UIScrollView)?.zoomScale ?? 1.0
        }

        /// Converts a screen-space touch radius to canvas-space, accounting for zoom.
        /// A 24pt finger target on screen becomes 24/zoomScale canvas units.
        private func canvasThreshold(_ screenPts: CGFloat = 24) -> CGFloat {
            screenPts / currentZoomScale
        }

        /// Returns the vertex index if `point` is within `threshold` of any effective
        /// vertex of the given `RoomArea` (supports both rect and polygon modes).
        private func hitVertex(point: CGPoint, in area: RoomArea, threshold: CGFloat? = nil) -> Int? {
            let t = threshold ?? canvasThreshold()
            for (i, vertex) in area.effectivePoints.enumerated() {
                if hypot(point.x - vertex.x, point.y - vertex.y) < t {
                    return i
                }
            }
            return nil
        }

        /// Returns the corner index (0=TL, 1=TR, 2=BL, 3=BR) if `point` is within
        /// `threshold` of any visual corner of a furniture item, else nil.
        private func hitCorner(point: CGPoint, in item: FurnitureItem, threshold: CGFloat? = nil) -> Int? {
            let t = threshold ?? canvasThreshold()
            for (i, corner) in item.visualCorners.enumerated() {
                if hypot(point.x - corner.x, point.y - corner.y) < t {
                    return i
                }
            }
            return nil
        }

        /// Computes a new rect when dragging `cornerIndex` to `newCornerPosition`,
        /// keeping the opposite corner anchored. Enforces a minimum size.
        private func computeResizedRect(original: CGRect,
                                        cornerIndex: Int,
                                        newCornerPosition: CGPoint,
                                        minSize: CGFloat) -> CGRect {
            // Opposite corner stays anchored
            let anchor: CGPoint
            switch cornerIndex {
            case 0: anchor = CGPoint(x: original.maxX, y: original.maxY) // TL → anchor BR
            case 1: anchor = CGPoint(x: original.minX, y: original.maxY) // TR → anchor BL
            case 2: anchor = CGPoint(x: original.maxX, y: original.minY) // BL → anchor TR
            default: anchor = CGPoint(x: original.minX, y: original.minY) // BR → anchor TL
            }

            var minX = min(anchor.x, newCornerPosition.x)
            var maxX = max(anchor.x, newCornerPosition.x)
            var minY = min(anchor.y, newCornerPosition.y)
            var maxY = max(anchor.y, newCornerPosition.y)

            // Enforce minimum size
            if maxX - minX < minSize {
                if newCornerPosition.x < anchor.x { minX = anchor.x - minSize }
                else { maxX = anchor.x + minSize }
            }
            if maxY - minY < minSize {
                if newCornerPosition.y < anchor.y { minY = anchor.y - minSize }
                else { maxY = anchor.y + minSize }
            }

            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        private func refreshPreview() {
            contentState.previewWall  = currentPreviewWall
            contentState.cursorPoint  = currentCursor
            contentState.isVertexSnap = currentIsVertexSnap
        }

        // MARK: Tap gesture

        @objc func handleTap(_ gr: UITapGestureRecognizer) {
            let tapPoint = gr.location(in: hostedView)
            switch parent.mode {
            case .placeOpening(let kind):
                parent.onPlaceOpening(kind, tapPoint)
            case .placeRoomLabel:
                parent.onPlaceRoomLabel(tapPoint)
            case .placeFurniture:
                parent.onPlaceFurniture(tapPoint)
            case .select:
                // If the tap lands on a handle of the currently selected element, keep the
                // selection as-is (the user may have intended a drag that was too short).
                if isTapOnSelectionHandle(tapPoint, selection: parent.selection, doc: parent.document) {
                    return
                }
                // If a room area is selected and the tap hits a polygon edge (but not a vertex
                // handle, already guarded above), insert a new vertex on that edge.
                if case .roomArea(let id) = parent.selection,
                   let area = parent.document.roomArea(for: id),
                   let edge = area.nearestEdge(to: tapPoint, threshold: canvasThreshold()) {
                    let snapped = DrawingDocument.fineSnap(edge.point)
                    parent.onInsertRoomAreaVertex?(id, edge.edgeIndex, snapped)
                    return
                }
                parent.selection = hitTest(tapPoint, in: parent.document)
            case .draw, .drawRoomArea:
                break
            }
        }

        // MARK: Double-tap gesture (remove polygon vertex)

        @objc func handleDoubleTap(_ gr: UITapGestureRecognizer) {
            guard parent.mode == .select else { return }
            let tapPoint = gr.location(in: hostedView)
            // Only act when a room area is selected and the double-tap lands on a vertex
            guard case .roomArea(let id) = parent.selection,
                  let area = parent.document.roomArea(for: id),
                  area.effectivePoints.count > 3,         // keep minimum 3 vertices
                  let vertexIdx = hitVertex(point: tapPoint, in: area) else { return }
            parent.onRemoveRoomAreaVertex?(id, vertexIdx)
        }

        /// Returns true if `point` is within handle-tap distance of any selection handle
        /// for the currently selected element. Used to prevent tap-deselection when the
        /// user intends to drag a handle but the gesture registers as a short tap.
        private func isTapOnSelectionHandle(_ point: CGPoint,
                                            selection: DrawingSelection,
                                            doc: DrawingDocument) -> Bool {
            let t = canvasThreshold()
            switch selection {
            case .roomArea(let id):
                guard let area = doc.roomArea(for: id) else { return false }
                return area.effectivePoints.contains {
                    hypot(point.x - $0.x, point.y - $0.y) < t
                }
            case .furniture(let id):
                guard let item = doc.furnitureItem(for: id) else { return false }
                return item.visualCorners.contains { hypot(point.x - $0.x, point.y - $0.y) < t }
            case .wall(let id):
                guard let wall = doc.wall(for: id) else { return false }
                return hypot(point.x - wall.start.x, point.y - wall.start.y) < t
                    || hypot(point.x - wall.end.x,   point.y - wall.end.y)   < t
            case .opening, .roomLabel, .none:
                return false
            }
        }

        private func hitTest(_ point: CGPoint, in doc: DrawingDocument) -> DrawingSelection {
            // B3: If a room area is currently selected and the tap lands inside it,
            // keep the selection so that vertex handles are not intercepted by nearby walls.
            if case .roomArea(let id) = parent.selection,
               let area = doc.roomArea(for: id),
               area.contains(point) {
                return .roomArea(id)
            }
            // Openings first
            for opening in doc.openings {
                guard let eps = doc.openingEndpoints(opening) else { continue }
                let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2,
                                  y: (eps.start.y + eps.end.y) / 2)
                if hypot(point.x - mid.x, point.y - mid.y) < 24 {
                    return .opening(opening.id)
                }
            }
            // Room labels
            for label in doc.roomLabels {
                if hypot(point.x - label.position.x, point.y - label.position.y) < 30 {
                    return .roomLabel(label.id)
                }
            }
            // Furniture items (checked before walls, last-added wins)
            for item in doc.furnitureItems.reversed() {
                if item.containsVisualPoint(point) {
                    return .furniture(item.id)
                }
            }
            // Walls — tolerance proportional to wall width
            var bestWall: (id: UUID, dist: CGFloat)?
            for wall in doc.walls {
                let proj      = wall.project(point)
                let tolerance = DrawingDocument.wallWidth(for: wall.kind) / 2 + 6
                if proj.distance < tolerance {
                    if bestWall == nil || proj.distance < bestWall!.dist {
                        bestWall = (wall.id, proj.distance)
                    }
                }
            }
            if let b = bestWall { return .wall(b.id) }
            // Room areas — last added wins (reversed order)
            for area in doc.roomAreas.reversed() {
                if area.contains(point) {
                    return .roomArea(area.id)
                }
            }
            return .none
        }

        // MARK: UIGestureRecognizerDelegate

        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if gr === mainGesture && other is UIPanGestureRecognizer { return false }
            return true
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }

        /// Prevents the tap gesture from firing when the long-press (main) gesture is already
        /// in an active dragging state (began / changed). Without this, a slow drag that ends
        /// near the touch-down point triggers a tap, deselecting the element just dragged.
        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            // If this is the tap recognizer and the main gesture is mid-drag, swallow the tap.
            if gr is UITapGestureRecognizer,
               let main = mainGesture,
               main.state == .began || main.state == .changed {
                return false
            }
            return true
        }
    }
}

// MARK: - DrawingContentState + DrawingContentWrapper

@Observable
final class DrawingContentState {
    var document: DrawingDocument   = DrawingDocument()
    var mode: DrawingMode           = .draw
    var selection: DrawingSelection = .none
    var previewWall: WallSegment?
    var previewArea: CGRect?
    var cursorPoint: CGPoint?
    var isVertexSnap: Bool          = false
    /// Guide line shown during axis-snap (extension snap) of a wall endpoint.
    var axisSnapGuide: (from: CGPoint, to: CGPoint)? = nil
    /// When false, dimension labels (wall lengths in metres) are hidden on the canvas.
    var showDimensions: Bool = true
}

struct DrawingContentWrapper: View {
    @State var state: DrawingContentState

    var body: some View {
        DrawingCanvasContent(
            document:       state.document,
            mode:           state.mode,
            selection:      state.selection,
            previewWall:    state.previewWall,
            previewArea:    state.previewArea,
            cursorPoint:    state.cursorPoint,
            isVertexSnap:   state.isVertexSnap,
            axisSnapGuide:  state.axisSnapGuide,
            showDimensions: state.showDimensions
        )
    }
}
