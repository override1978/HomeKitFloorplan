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

        // Tap for selection / placeOpening / placeRoomLabel
        let tapGesture = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
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

        context.coordinator.updateContent(document: document, mode: mode, selection: selection)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {

        var parent: DrawingCanvasView
        var hostedView: UIView?
        weak var mainGesture: UILongPressGestureRecognizer?

        // Draw wall state
        private var drawStartPoint: CGPoint?
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

        // Drag wall endpoint state
        private var draggingWallEndpointID: UUID?
        private var draggingEndpointIndex: Int?   // 0 = start, 1 = end

        private var contentState = DrawingContentState()

        init(parent: DrawingCanvasView) { self.parent = parent }

        func makeHostingController() -> UIHostingController<DrawingContentWrapper> {
            UIHostingController(rootView: DrawingContentWrapper(state: contentState))
        }

        func updateContent(document: DrawingDocument, mode: DrawingMode, selection: DrawingSelection) {
            contentState.document     = document
            contentState.mode         = mode
            contentState.selection    = selection
            contentState.previewWall  = currentPreviewWall
            contentState.previewArea  = currentPreviewArea
            contentState.cursorPoint  = currentCursor
            contentState.isVertexSnap = currentIsVertexSnap
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
            let snapResult = parent.document.smartSnap(rawPoint)
            let snapped = snapResult.point

            switch gr.state {
            case .began:
                drawStartPoint      = snapped
                currentCursor       = snapped
                currentIsVertexSnap = snapResult.isVertex
                refreshPreview()
            case .changed:
                currentCursor       = snapped
                currentIsVertexSnap = snapResult.isVertex
                if let start = drawStartPoint {
                    currentPreviewWall = WallSegment(start: start, end: snapped,
                                                     kind: parent.wallKind)
                }
                refreshPreview()
            case .ended, .cancelled, .failed:
                if let start = drawStartPoint, start != snapped {
                    var newDoc = parent.document
                    newDoc.walls.append(WallSegment(start: start, end: snapped,
                                                    kind: parent.wallKind))
                    parent.onCommit(newDoc)
                }
                drawStartPoint      = nil
                currentPreviewWall  = nil
                currentCursor       = nil
                currentIsVertexSnap = false
                refreshPreview()
            default:
                break
            }
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
                    if let cornerIdx = hitCorner(point: rawPoint, rect: area.rect, threshold: 20) {
                        resizingRoomAreaID  = id
                        resizingCornerIndex = cornerIdx
                        resizeOriginalRect  = area.rect
                        parent.onBeginResizeRoomArea(id)
                        return
                    }
                    // Not near a corner — check if inside the rect for move
                    if area.rect.contains(rawPoint) {
                        draggingRoomAreaID = id
                        dragAreaTouchStart = rawPoint
                        parent.onBeginMoveRoomArea(id)
                        return
                    }
                }
                // Check furniture item corners first (resize), then body (move)
                if case .furniture(let id) = parent.selection,
                   let item = parent.document.furnitureItem(for: id) {
                    if let cornerIdx = hitCorner(point: rawPoint, rect: item.rect, threshold: 20) {
                        resizingFurnitureID = id
                        resizingFurnitureCornerIndex = cornerIdx
                        resizeFurnitureOriginalRect  = item.rect
                        parent.onBeginResizeFurniture(id)
                        return
                    }
                    if item.rect.contains(rawPoint) {
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
                // Wall endpoint drag — hit-test start/end circles when a wall is selected
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
                    }
                }
            case .changed:
                // Resize furniture
                if let id = resizingFurnitureID,
                   let cornerIdx = resizingFurnitureCornerIndex,
                   let originalRect = resizeFurnitureOriginalRect {
                    let snapped = DrawingDocument.fineSnap(rawPoint)
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
                // Resize room area
                if let id = resizingRoomAreaID,
                   let cornerIdx = resizingCornerIndex,
                   let originalRect = resizeOriginalRect {
                    let snapped = DrawingDocument.fineSnap(rawPoint)
                    let newRect = computeResizedRect(original: originalRect,
                                                     cornerIndex: cornerIdx,
                                                     newCornerPosition: snapped,
                                                     minSize: 40)
                    parent.onResizeRoomArea(id, newRect)
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
                    let snapped = parent.document.smartSnap(rawPoint).point
                    parent.onMoveWallEndpoint?(id, epIdx, snapped)
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
                draggingWallEndpointID       = nil
                draggingEndpointIndex        = nil
            default:
                break
            }
        }

        // MARK: Resize helpers

        /// Returns the corner index (0=TL, 1=TR, 2=BL, 3=BR) if `point` is within
        /// `threshold` of any corner of `rect`, else nil.
        private func hitCorner(point: CGPoint, rect: CGRect, threshold: CGFloat = 20) -> Int? {
            let corners: [CGPoint] = [
                CGPoint(x: rect.minX, y: rect.minY),  // 0: topLeft
                CGPoint(x: rect.maxX, y: rect.minY),  // 1: topRight
                CGPoint(x: rect.minX, y: rect.maxY),  // 2: bottomLeft
                CGPoint(x: rect.maxX, y: rect.maxY)   // 3: bottomRight
            ]
            for (i, corner) in corners.enumerated() {
                if hypot(point.x - corner.x, point.y - corner.y) < threshold {
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
                parent.selection = hitTest(tapPoint, in: parent.document)
            case .draw, .drawRoomArea:
                break
            }
        }

        private func hitTest(_ point: CGPoint, in doc: DrawingDocument) -> DrawingSelection {
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
                if item.rect.contains(point) {
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
                if area.rect.contains(point) {
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
}

struct DrawingContentWrapper: View {
    @State var state: DrawingContentState

    var body: some View {
        DrawingCanvasContent(
            document:     state.document,
            mode:         state.mode,
            selection:    state.selection,
            previewWall:  state.previewWall,
            previewArea:  state.previewArea,
            cursorPoint:  state.cursorPoint,
            isVertexSnap: state.isVertexSnap
        )
    }
}
