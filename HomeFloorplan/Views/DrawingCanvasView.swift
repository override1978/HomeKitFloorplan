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
    /// Tocco secco in modalità Stanza: il foglio prova a ricavare il
    /// poligono dai muri. Il trascinamento resta la via manuale.
    var onTapRoomArea: ((CGPoint) -> Void)? = nil
    /// Su iPhone lo zoom minimo tiene il canvas a copertura dello schermo.
    var coversViewportAtMinimumZoom: Bool = false
    /// Area occupata dalla chrome flottante. La scroll view la usa come spazio
    /// di respiro operativo: il canvas resta sotto il vetro, ma può essere
    /// centrato e pannato fuori da top bar, inspector e dock.
    var chromeInsets: UIEdgeInsets = .zero
    /// iPhone-only precision lens while drawing or reshaping small geometry.
    var showsMagnifier: Bool = false
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

    /// L'unico punto che UIKit garantisce a ogni cambio di geometria è
    /// `layoutSubviews`: pavimento dello zoom e centratura vivono lì, non
    /// sparsi fra callback che a volte non arrivano.
    final class DrawingScrollView: UIScrollView {
        var onLayout: (() -> Void)?
        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = DrawingScrollView()
        // Adattivo: in dark mode lo sfondo bianco fisso disegnava una lastra
        // chiara oltre il bordo del canvas.
        sv.backgroundColor = .systemBackground
        sv.minimumZoomScale = 0.3
        sv.maximumZoomScale = 4.0
        sv.zoomScale = 0.6
        sv.showsHorizontalScrollIndicator = false
        sv.showsVerticalScrollIndicator   = false
        sv.delegate    = context.coordinator
        // Il rimbalzo elastico sotto il minimo era la porta di ogni stato
        // «incastrato»: l'animazione di ritorno si interrompe (un tocco, un
        // aggiornamento SwiftUI) e la scala resta sotto il pavimento, col
        // foglio rannicchiato in alto a sinistra. Senza rimbalzo la scala
        // non può proprio scendere sotto il minimo.
        sv.bouncesZoom = false
        // Gli inset li governa il disegno, non il sistema: il foglio ora
        // rispetta la safe area e senza questo la scrollview sposterebbe i
        // contenuti di quanto è alta la status bar.
        sv.contentInsetAdjustmentBehavior = .never

        let size = DrawingDocument.canvasSize
        sv.contentSize = CGSize(width: size, height: size)

        let hostVC = context.coordinator.makeHostingController()
        hostVC.view.frame           = CGRect(x: 0, y: 0, width: size, height: size)
        hostVC.view.backgroundColor = .systemBackground
        sv.addSubview(hostVC.view)
        context.coordinator.hostedView = hostVC.view
        sv.onLayout = { [weak sv, coordinator = context.coordinator] in
            guard let sv else { return }
            coordinator.enforceZoomFloor(sv)
            coordinator.centerContent(sv)
        }

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
        tapGesture.delegate = context.coordinator
        sv.addGestureRecognizer(tapGesture)

        // Quando parte un gesto a due dita (pan o pinch), il tratto in corso
        // si annulla: senza questo, zoomare mentre si disegna committava un
        // muro spazzatura sotto lo zoom — il grosso delle «bizze» su iPhone.
        sv.panGestureRecognizer.addTarget(context.coordinator,
                                          action: #selector(Coordinator.cancelDrawOnScrollGesture(_:)))
        sv.pinchGestureRecognizer?.addTarget(context.coordinator,
                                             action: #selector(Coordinator.cancelDrawOnScrollGesture(_:)))

        return sv
    }

    // MARK: updateUIView

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self

        let panDisabled: Bool
        if case .draw = mode { panDisabled = true }
        else if case .drawRoomArea = mode { panDisabled = true }
        else { panDisabled = false }

        // In disegno il pan non sparisce: passa a due dita. Un dito disegna,
        // due spostano — è la grammatica di qualunque app di disegno, e su
        // iPhone è l'unica alternativa al cambiare modalità per ogni pan.
        sv.panGestureRecognizer.isEnabled = true
        sv.panGestureRecognizer.minimumNumberOfTouches = panDisabled ? 2 : 1
        context.coordinator.enforceZoomFloor(sv)
        let gestureEnabled: Bool
        switch mode {
        case .draw, .select, .drawRoomArea: gestureEnabled = true
        default: gestureEnabled = false
        }
        context.coordinator.mainGesture?.isEnabled = gestureEnabled
        context.coordinator.vertexSnapEnabled = vertexSnapEnabled
        context.coordinator.showDimensions    = showDimensions

        context.coordinator.updateContent(document: document, mode: mode, selection: selection)
        context.coordinator.centerContent(sv)
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
        private var currentMagnifierPoint: CGPoint?
        private var currentSnapPreview: SnapResult?
        private weak var autoPanScrollView: UIScrollView?
        private var autoPanVelocity: CGPoint = .zero
        private var autoPanDisplayLink: CADisplayLink?

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
        private let snapHaptic      = UIImpactFeedbackGenerator(style: .light)
        private let commitHaptic    = UIImpactFeedbackGenerator(style: .medium)
        private let selectionHaptic = UISelectionFeedbackGenerator()

        init(parent: DrawingCanvasView) { self.parent = parent }

        // MARK: Snap helper

        /// Returns either smartSnap (vertex-first) or plain grid snap depending on the toggle.
        private func performSnap(_ point: CGPoint) -> SnapResult {
            if vertexSnapEnabled {
                // Il magnete si misura in punti SCHERMO: a zoom 0.4 su iPhone
                // i 30 pt canvas fissi diventavano 12 pt sotto il dito, e gli
                // angoli «non si prendevano». Così il raggio è costante al
                // polpastrello a qualunque zoom.
                return parent.document.smartSnap(point, maxDistance: canvasThreshold(precisionModeEnabled ? 34 : 26))
            } else {
                return .grid(DrawingDocument.snap(point))
            }
        }

        private func performDrawSnap(_ point: CGPoint) -> SnapResult {
            guard vertexSnapEnabled else {
                return .grid(DrawingDocument.snap(point))
            }

            if let vertex = parent.document.nearestEndpoint(
                to: point,
                maxDistance: canvasThreshold(precisionModeEnabled ? 40 : 30)
            ) {
                return .vertex(vertex)
            }
            if let hit = parent.document.nearestWall(
                to: point,
                maxDistance: canvasThreshold(parent.showsMagnifier ? 18 : 10)
            ),
               let wall = parent.document.wall(for: hit.wallID) {
                return .wall(wall.project(point).closest)
            }
            return .grid(DrawingDocument.snap(point))
        }

        private func performEndpointSnap(_ point: CGPoint,
                                         movingWallID: UUID) -> SnapResult {
            guard vertexSnapEnabled else {
                return .grid(DrawingDocument.snap(point))
            }

            if let vertex = nearestEndpoint(
                to: point,
                maxDistance: canvasThreshold(precisionModeEnabled ? 44 : 34),
                excludingWallID: movingWallID
            ) {
                return .vertex(vertex)
            }
            if let wallPoint = nearestWallPoint(
                to: point,
                maxDistance: canvasThreshold(parent.showsMagnifier ? 5 : 10),
                excludingWallID: movingWallID
            ) {
                return .wall(wallPoint)
            }
            return .grid(DrawingDocument.snap(point))
        }

        private func nearestWallPoint(to point: CGPoint,
                                      maxDistance: CGFloat,
                                      excludingWallID: UUID) -> CGPoint? {
            var bestPoint: CGPoint?
            var bestDistance: CGFloat = .greatestFiniteMagnitude

            for wall in parent.document.walls where wall.id != excludingWallID && wall.kind.rendersAsPhysicalWall {
                let projection = wall.project(point)
                guard projection.t > 0, projection.t < 1 else { continue }
                if projection.distance < bestDistance {
                    bestDistance = projection.distance
                    bestPoint = projection.closest
                }
            }

            guard bestDistance <= maxDistance else { return nil }
            return bestPoint
        }

        private func nearestEndpoint(to point: CGPoint,
                                     maxDistance: CGFloat,
                                     excludingWallID: UUID) -> CGPoint? {
            var bestPoint: CGPoint?
            var bestDistance: CGFloat = .greatestFiniteMagnitude

            for wall in parent.document.walls where wall.id != excludingWallID {
                for endpoint in [wall.start, wall.end] {
                    let distance = hypot(endpoint.x - point.x, endpoint.y - point.y)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestPoint = endpoint
                    }
                }
            }

            guard bestDistance <= maxDistance else { return nil }
            return bestPoint
        }

        private func axisSnap(_ point: CGPoint,
                              maxDistance: CGFloat,
                              excludingWallID: UUID) -> AxisSnapResult? {
            var bestX: (dist: CGFloat, vertex: CGPoint)?
            var bestY: (dist: CGFloat, vertex: CGPoint)?

            for wall in parent.document.walls where wall.id != excludingWallID {
                for endpoint in [wall.start, wall.end] {
                    let dx = abs(endpoint.x - point.x)
                    let dy = abs(endpoint.y - point.y)
                    if dx < maxDistance, bestX == nil || dx < bestX!.dist { bestX = (dx, endpoint) }
                    if dy < maxDistance, bestY == nil || dy < bestY!.dist { bestY = (dy, endpoint) }
                }
            }

            if let bestX, let bestY {
                return bestX.dist <= bestY.dist
                    ? AxisSnapResult(point: CGPoint(x: bestX.vertex.x, y: point.y),
                                     axis: .vertical,
                                     referenceVertex: bestX.vertex)
                    : AxisSnapResult(point: CGPoint(x: point.x, y: bestY.vertex.y),
                                     axis: .horizontal,
                                     referenceVertex: bestY.vertex)
            }
            if let bestX {
                return AxisSnapResult(point: CGPoint(x: bestX.vertex.x, y: point.y),
                                      axis: .vertical,
                                      referenceVertex: bestX.vertex)
            }
            if let bestY {
                return AxisSnapResult(point: CGPoint(x: point.x, y: bestY.vertex.y),
                                      axis: .horizontal,
                                      referenceVertex: bestY.vertex)
            }
            return nil
        }

        /// Signed angular distance in degrees, wrap-aware (result in [-180, 180]).
        private func angularDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            var d = (a - b).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 }
            if d < -180 { d += 360 }
            return d
        }

        /// Magnetic angle snap for wall drawing and endpoint drags.
        /// Strong magnet (±7°) on the 45° family with the legacy grid-friendly
        /// endpoint math; weak magnet (±4°) on the 15° family preserving the
        /// dragged length (rounded to 5 pt = 5 cm); free angle everywhere else,
        /// so arbitrary inclinations like 15° or 20° are drawable.
        private func angleSnappedEnd(from start: CGPoint, to end: CGPoint, snapResult: SnapResult) -> CGPoint {
            guard !snapResult.isGeometrySnap else { return end }

            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length >= DrawingDocument.gridSpacing else { return end }

            let deg = atan2(dy, dx) * 180 / .pi

            let octantTolerance: CGFloat = parent.showsMagnifier ? 12 : 7
            let fineAngleTolerance: CGFloat = parent.showsMagnifier ? 5 : 4

            let octantDeg = (deg / 45).rounded() * 45
            if abs(angularDistance(deg, octantDeg)) <= octantTolerance {
                let snappedAngle = octantDeg * .pi / 180
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

            let stepDeg = (deg / 15).rounded() * 15
            if abs(angularDistance(deg, stepDeg)) <= fineAngleTolerance {
                let snappedAngle = stepDeg * .pi / 180
                let roundedLength = (length / 5).rounded() * 5
                return CGPoint(x: start.x + cos(snappedAngle) * roundedLength,
                               y: start.y + sin(snappedAngle) * roundedLength)
            }

            return end
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
            contentState.magnifierPoint  = parent.showsMagnifier ? currentMagnifierPoint : nil
            contentState.magnifierZoomScale = currentZoomScale
            contentState.showsMagnifier  = parent.showsMagnifier
            contentState.snapPreview     = currentSnapPreview
        }

        // MARK: Zoom centering

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { hostedView }

        /// Su iPhone il minimo è «il canvas copre lo schermo»: oltre quel
        /// limite si vedrebbe solo il vuoto fuori dall'area di disegno — il
        /// «taglio» riportato tre volte. Su iPad resta 0.3: lì la vista
        /// d'insieme dell'intero canvas ha senso e lo schermo la regge.
        /// In più, se lo zoom è rimasto incastrato SOTTO il minimo (rimbalzo
        /// interrotto), qui si riaggancia.
        func enforceZoomFloor(_ scrollView: UIScrollView) {
            guard scrollView.bounds.width > 0 else { return }
            let floor: CGFloat
            if parent.coversViewportAtMinimumZoom {
                let cover = max(scrollView.bounds.width, scrollView.bounds.height)
                    / DrawingDocument.canvasSize
                floor = max(0.3, cover)
            } else {
                floor = 0.3
            }
            // Stessa regola di centerContent: si scrive solo se cambia.
            if abs(scrollView.minimumZoomScale - floor) > 0.001 {
                scrollView.minimumZoomScale = floor
            }
            if !scrollView.isZooming, !scrollView.isZoomBouncing,
               scrollView.zoomScale < scrollView.minimumZoomScale - 0.001 {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                centerContent(scrollView)
            }
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            contentState.magnifierZoomScale = scrollView.zoomScale
            centerContent(scrollView)
        }

        /// Quando il canvas è più piccolo dello schermo galleggia al centro
        /// **tramite contentInset**, non spostando il frame: il frame combatte
        /// col contentOffset, e al primo scroll a zoom basso il disegno
        /// restava incollato in alto col bianco sotto — lo «sparisce mezzo
        /// disegno» di iPhone, dove lo schermo stretto ci finisce di continuo.
        func centerContent(_ scrollView: UIScrollView) {
            // Mai toccare il frame della vista zoomata: durante il pinch la
            // scrollview la governa via transform, e scriverle il frame sotto
            // le mani corrompeva l'ancora dello zoom («resize spinto» = mezzo
            // disegno sparito). Il contentSize lo tiene giusto la scrollview.
            let chrome = parent.chromeInsets
            let visibleSize = operativeViewportSize(in: scrollView)
            let dx = max((visibleSize.width  - scrollView.contentSize.width)  / 2, 0)
            let dy = max((visibleSize.height - scrollView.contentSize.height) / 2, 0)
            let target = UIEdgeInsets(
                top: chrome.top + dy,
                left: chrome.left + dx,
                bottom: chrome.bottom + dy,
                right: chrome.right + dx
            )
            // ⚠️ Idempotente, o è un anello: scrivere contentInset rifà
            // layout, layoutSubviews richiama centerContent (onLayout), e
            // quando l'inspector cambia le fasce chrome i valori possono
            // oscillare — il main thread gira a vuoto e l'editor «freeza»
            // alla selezione di un arredo. Stessa famiglia dell'anello
            // topBarHeight già pagato caro.
            let current = scrollView.contentInset
            let differs = abs(current.top - target.top) > 0.5
                || abs(current.left - target.left) > 0.5
                || abs(current.bottom - target.bottom) > 0.5
                || abs(current.right - target.right) > 0.5
            if differs {
                scrollView.contentInset = target
            }
        }

        private func operativeViewportSize(in scrollView: UIScrollView) -> CGSize {
            let chrome = parent.chromeInsets
            return CGSize(
                width: max(scrollView.bounds.width - chrome.left - chrome.right, 1),
                height: max(scrollView.bounds.height - chrome.top - chrome.bottom, 1)
            )
        }

        /// Il rimbalzo sotto lo zoom minimo passa di qui alla fine: la
        /// centratura va rifatta sullo stato assestato, e lo zoom incastrato
        /// sotto il minimo si riaggancia.
        func scrollViewDidEndZooming(_ scrollView: UIScrollView,
                                     with view: UIView?, atScale scale: CGFloat) {
            enforceZoomFloor(scrollView)
            centerContent(scrollView)
        }

        private func updateAutoPan(for gesture: UILongPressGestureRecognizer) {
            guard parent.showsMagnifier,
                  let scrollView = gesture.view as? UIScrollView,
                  gesture.state == .began || gesture.state == .changed
            else {
                stopAutoPan()
                return
            }

            let point = gesture.location(in: scrollView)
            let bounds = scrollView.bounds
            let chrome = parent.chromeInsets
            let activeRect = CGRect(
                x: bounds.minX + chrome.left,
                y: bounds.minY + chrome.top,
                width: max(bounds.width - chrome.left - chrome.right, 1),
                height: max(bounds.height - chrome.top - chrome.bottom, 1)
            )
            let edge: CGFloat = 76
            let maxStep: CGFloat = precisionModeEnabled ? 13 : 9

            func edgeVelocity(distance: CGFloat) -> CGFloat {
                guard distance < edge else { return 0 }
                let ratio = max(0, min(1, (edge - distance) / edge))
                return maxStep * ratio * ratio
            }

            var velocity = CGPoint.zero
            velocity.x -= edgeVelocity(distance: point.x - activeRect.minX)
            velocity.x += edgeVelocity(distance: activeRect.maxX - point.x)
            velocity.y -= edgeVelocity(distance: point.y - activeRect.minY)
            velocity.y += edgeVelocity(distance: activeRect.maxY - point.y)

            autoPanVelocity = velocity
            autoPanScrollView = scrollView
            if velocity == .zero {
                stopAutoPan()
            } else {
                startAutoPanIfNeeded()
            }
        }

        private func startAutoPanIfNeeded() {
            guard autoPanDisplayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(handleAutoPanTick))
            link.add(to: .main, forMode: .common)
            autoPanDisplayLink = link
        }

        private func stopAutoPan() {
            autoPanDisplayLink?.invalidate()
            autoPanDisplayLink = nil
            autoPanVelocity = .zero
            autoPanScrollView = nil
        }

        @objc private func handleAutoPanTick() {
            guard let scrollView = autoPanScrollView, autoPanVelocity != .zero else {
                stopAutoPan()
                return
            }

            let minX = -scrollView.contentInset.left
            let minY = -scrollView.contentInset.top
            let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            var next = scrollView.contentOffset
            next.x = min(max(next.x + autoPanVelocity.x, minX), maxX)
            next.y = min(max(next.y + autoPanVelocity.y, minY), maxY)
            scrollView.setContentOffset(next, animated: false)
            refreshActiveGestureAfterAutoPan()
        }

        private func refreshActiveGestureAfterAutoPan() {
            guard let mainGesture,
                  mainGesture.state == .changed,
                  let hostedView else { return }

            let rawPoint = mainGesture.location(in: hostedView)
            switch parent.mode {
            case .draw:
                handleDrawGesture(mainGesture, rawPoint: rawPoint)
            case .select:
                handleDragGesture(mainGesture, rawPoint: rawPoint)
            case .drawRoomArea:
                handleDrawAreaGesture(mainGesture, rawPoint: rawPoint)
            default:
                break
            }
        }

        // MARK: Main gesture (draw walls OR drag openings/labels)

        @objc func handleMainGesture(_ gr: UILongPressGestureRecognizer) {
            // Due dita = zoom o pan, mai un tratto. Il delegato dei gesti non
            // basta: verificato nel simulatore, col secondo dito il long-press
            // continuava a tracciare il primo e il pinch non partiva mai — il
            // muro diagonale fantasma. La guardia sta nel gesto stesso.
            if gr.numberOfTouches > 1, gr.state == .began || gr.state == .changed {
                stopAutoPan()
                cancelMainGesture()
                return
            }
            let rawPoint = gr.location(in: hostedView)
            if let hostedView,
               parent.chromeInsets.contains(rawPoint, in: hostedView.bounds),
               gr.state == .began || gr.state == .changed {
                stopAutoPan()
                cancelMainGesture()
                return
            }

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

            stopAutoPan()
        }

        // MARK: Draw walls

        private func handleDrawGesture(_ gr: UILongPressGestureRecognizer, rawPoint: CGPoint) {
            var snapResult = performDrawSnap(rawPoint)
            var snapped = snapResult.point
            if let start = drawStartPoint,
               case .wall = snapResult,
               let intersection = axisPreservingWallIntersection(from: start,
                                                                  rawPoint: rawPoint,
                                                                  directionVector: CGPoint(x: rawPoint.x - start.x,
                                                                                           y: rawPoint.y - start.y),
                                                                  excludingWallID: nil) {
                snapResult = .wall(intersection)
                snapped = intersection
            }

            switch gr.state {
            case .began:
                drawStartPoint      = snapped
                drawTouchStartPoint = rawPoint
                didExceedDrawDragThreshold = false
                currentCursor       = snapped
                currentIsVertexSnap = snapResult.isVertex
                currentMagnifierPoint = snapped
                currentSnapPreview = snapResult
                refreshPreview()
            case .changed:
                let constrained = drawStartPoint.map {
                    angleSnappedEnd(from: $0, to: snapped, snapResult: snapResult)
                } ?? snapped
                let didCursorMove   = constrained != currentCursor
                let didSnapChange   = snapPreviewKind(currentSnapPreview) != snapPreviewKind(snapResult)
                currentCursor       = constrained
                currentIsVertexSnap = snapResult.isVertex
                currentMagnifierPoint = constrained
                currentSnapPreview = snapResult.at(constrained)
                if snapResult.isGeometrySnap && didSnapChange {
                    snapHaptic.impactOccurred()
                }
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
                if didCursorMove || didSnapChange { refreshPreview() }
            case .ended, .cancelled, .failed:
                stopAutoPan()
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
                currentMagnifierPoint = nil
                currentSnapPreview = nil
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
                var finalPoint = point
                var finalSnap = snapResult
                if case .wall = snapResult,
                   let intersection = axisPreservingWallIntersection(from: start,
                                                                      rawPoint: point,
                                                                      directionVector: CGPoint(x: point.x - start.x,
                                                                                               y: point.y - start.y),
                                                                      excludingWallID: nil) {
                    finalPoint = intersection
                    finalSnap = .wall(intersection)
                }
                let constrained = angleSnappedEnd(from: start, to: finalPoint, snapResult: finalSnap)
                if start != constrained {
                    commitWall(start: start, end: constrained, kind: pendingTapWallKind ?? parent.wallKind)
                }
                clearPendingTapWall()
            } else {
                pendingTapWallStart = point
                pendingTapWallKind  = parent.wallKind
                currentCursor       = point
                currentIsVertexSnap = snapResult.isVertex
                currentSnapPreview  = snapResult
            }
        }

        private func commitWall(start: CGPoint, end: CGPoint, kind: WallKind) {
            commitHaptic.impactOccurred()
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
            currentMagnifierPoint = nil
            currentSnapPreview = nil
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
                stopAutoPan()
                if let rect = currentPreviewArea, rect.width > 40, rect.height > 40 {
                    commitHaptic.impactOccurred()
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
                    // Grab an edge to pinch the shape: insert a vertex at the grab
                    // point and keep dragging it within the same gesture.
                    // (onInsertRoomAreaVertex pushes undo, so the whole insert+drag
                    // is one undo step — do not also call onBeginResizeRoomArea.)
                    if let edge = area.nearestEdge(to: rawPoint, threshold: canvasThreshold()) {
                        let snapResult = wallAwareSnapResult(edge.point)
                        let snapped = snapResult.point
                        currentMagnifierPoint = snapped
                        currentSnapPreview = snapResult
                        contentState.magnifierPoint = parent.showsMagnifier ? snapped : nil
                        contentState.snapPreview = snapResult
                        parent.onInsertRoomAreaVertex?(id, edge.edgeIndex, snapped)
                        resizingRoomAreaID  = id
                        resizingCornerIndex = edge.edgeIndex + 1
                        resizeOriginalRect  = area.rect
                        return
                    }
                    // Not near a vertex or edge — check if inside the area for move
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
                    let endpointHitRadius = canvasThreshold(parent.showsMagnifier ? 56 : 44)
                    if distToStart < endpointHitRadius {
                        draggingWallEndpointID = id
                        draggingEndpointIndex  = 0
                        parent.onBeginMoveWallEndpoint?(id)
                    } else if distToEnd < endpointHitRadius {
                        draggingWallEndpointID = id
                        draggingEndpointIndex  = 1
                        parent.onBeginMoveWallEndpoint?(id)
                    } else if parent.showsMagnifier {
                        let mid = CGPoint(x: (wall.start.x + wall.end.x) / 2,
                                          y: (wall.start.y + wall.end.y) / 2)
                        if hypot(rawPoint.x - mid.x, rawPoint.y - mid.y) < canvasThreshold(34) {
                            draggingWallID      = id
                            dragWallTouchStart  = rawPoint
                            parent.onBeginMoveWall?(id)
                        }
                    } else {
                        // No endpoint handle hit — check if the touch is on the wall body
                        let proj = wall.project(rawPoint)
                        let tolerance = DrawingDocument.wallWidth(for: wall.kind) / 2 + canvasThreshold(12)
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
                    let snapResult = wallAwareSnapResult(rawPoint)
                    let snapped = snapResult.point
                    currentMagnifierPoint = snapped
                    currentSnapPreview = snapResult
                    contentState.magnifierPoint = parent.showsMagnifier ? snapped : nil
                    contentState.snapPreview = snapResult
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
                    let snapResult = performEndpointSnap(rawPoint, movingWallID: id)
                    var snapped = snapResult.point
                    var axisGuide: (from: CGPoint, to: CGPoint)? = nil
                    let alignmentAxis = axisSnap(rawPoint,
                                                 maxDistance: canvasThreshold(parent.showsMagnifier ? 38 : 22),
                                                 excludingWallID: id)
                    if case .grid = snapResult,
                       let axisResult = alignmentAxis {
                        // Axis snap fires: lock one coordinate, grid-snap the free axis.
                        snapped = DrawingDocument.snap(axisResult.point)
                        axisGuide = (from: axisResult.referenceVertex, to: snapped)
                    } else if let wall = parent.document.wall(for: id) {
                        let anchor = epIdx == 0 ? wall.end : wall.start
                        if let intersection = axisPreservingWallIntersection(from: anchor,
                                                                             rawPoint: rawPoint,
                                                                             directionVector: CGPoint(x: wall.end.x - wall.start.x,
                                                                                                      y: wall.end.y - wall.start.y),
                                                                             excludingWallID: id) {
                            snapped = intersection
                            axisGuide = (from: anchor, to: intersection)
                        } else {
                            snapped = angleSnappedEnd(from: anchor, to: snapped, snapResult: snapResult)
                        }
                        if axisGuide == nil, let axisResult = alignmentAxis {
                            axisGuide = (from: axisResult.referenceVertex, to: snapped)
                        }
                    }
                    contentState.axisSnapGuide = axisGuide
                    currentMagnifierPoint = snapped
                    currentSnapPreview = snapResult.at(snapped)
                    contentState.magnifierPoint = parent.showsMagnifier ? snapped : nil
                    contentState.snapPreview = currentSnapPreview
                    parent.onMoveWallEndpoint?(id, epIdx, snapped)
                }
                // Move whole wall
                if let id = draggingWallID, let touchStart = dragWallTouchStart {
                    let delta = CGSize(width: rawPoint.x - touchStart.x,
                                       height: rawPoint.y - touchStart.y)
                    parent.onMoveWall?(id, delta)
                }
            case .ended, .cancelled, .failed:
                stopAutoPan()
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
                currentMagnifierPoint        = nil
                currentSnapPreview           = nil
                contentState.magnifierPoint  = nil
                contentState.snapPreview     = nil
            default:
                break
            }
        }

        // MARK: Resize helpers

        /// Current zoom scale of the hosting scroll view (1.0 if unavailable).
        private var currentZoomScale: CGFloat {
            (hostedView?.superview as? UIScrollView)?.zoomScale ?? 1.0
        }

        private var precisionModeEnabled: Bool {
            parent.showsMagnifier && currentZoomScale < 0.85
        }

        /// Converts a screen-space touch radius to canvas-space, accounting for zoom.
        /// A 24pt finger target on screen becomes 24/zoomScale canvas units.
        private func canvasThreshold(_ screenPts: CGFloat = 24) -> CGFloat {
            screenPts / currentZoomScale
        }

        /// Snap used while dragging a room-area vertex: wall endpoints first, then
        /// wall bodies, then the fine grid — so the area outline clicks onto the
        /// walls that describe the real room.
        private func wallAwareSnap(_ point: CGPoint) -> CGPoint {
            wallAwareSnapResult(point).point
        }

        private func wallAwareSnapResult(_ point: CGPoint) -> SnapResult {
            let doc = parent.document
            let endpointRadius = precisionModeEnabled ? CGFloat(52) : 44
            let wallRadius = precisionModeEnabled ? CGFloat(9) : 12
            if let ep = doc.nearestEndpoint(to: point, maxDistance: canvasThreshold(endpointRadius)) {
                return .vertex(ep)
            }
            if let hit = doc.nearestWall(to: point, maxDistance: canvasThreshold(wallRadius)),
               let wall = doc.wall(for: hit.wallID) {
                return .wall(wall.project(point).closest)
            }
            return .grid(DrawingDocument.fineSnap(point))
        }

        private func axisPreservingWallIntersection(from anchor: CGPoint,
                                                    rawPoint: CGPoint,
                                                    directionVector: CGPoint,
                                                    excludingWallID: UUID?) -> CGPoint? {
            let length = hypot(directionVector.x, directionVector.y)
            guard length > 0 else { return nil }

            let lockedAngle = lockedAxisAngle(forVector: directionVector)
            let direction = CGPoint(x: cos(lockedAngle), y: sin(lockedAngle))
            let wallSearchDistance: CGFloat = parent.showsMagnifier ? 22 : 14
            let intersectionTolerance: CGFloat = parent.showsMagnifier ? 72 : 44
            guard let targetWall = nearestPhysicalWall(to: rawPoint,
                                                       excludingWallID: excludingWallID,
                                                       maxDistance: canvasThreshold(wallSearchDistance)) else {
                return nil
            }

            guard let intersection = lineSegmentIntersection(linePoint: anchor,
                                                             lineDirection: direction,
                                                             segmentStart: targetWall.start,
                                                             segmentEnd: targetWall.end) else {
                return nil
            }

            guard distance(rawPoint, intersection) <= canvasThreshold(intersectionTolerance) else { return nil }
            return intersection
        }

        private func lockedAxisAngle(forVector vector: CGPoint) -> CGFloat {
            let rawAngle = atan2(vector.y, vector.x)
            let snap = CGFloat.pi / 4
            return (rawAngle / snap).rounded() * snap
        }

        private func nearestPhysicalWall(to point: CGPoint,
                                         excludingWallID: UUID?,
                                         maxDistance: CGFloat) -> WallSegment? {
            var bestWall: WallSegment?
            var bestDistance: CGFloat = .greatestFiniteMagnitude

            for wall in parent.document.walls where wall.id != excludingWallID && wall.kind.rendersAsPhysicalWall {
                let projection = wall.project(point)
                guard projection.t >= 0, projection.t <= 1 else { continue }
                if projection.distance < bestDistance {
                    bestDistance = projection.distance
                    bestWall = wall
                }
            }

            guard bestDistance <= maxDistance else { return nil }
            return bestWall
        }

        private func lineSegmentIntersection(linePoint: CGPoint,
                                             lineDirection: CGPoint,
                                             segmentStart: CGPoint,
                                             segmentEnd: CGPoint) -> CGPoint? {
            let sx = segmentEnd.x - segmentStart.x
            let sy = segmentEnd.y - segmentStart.y
            let denominator = cross(lineDirection, CGPoint(x: sx, y: sy))
            guard abs(denominator) > 0.0001 else { return nil }

            let delta = CGPoint(x: segmentStart.x - linePoint.x,
                                y: segmentStart.y - linePoint.y)
            let lineT = cross(delta, CGPoint(x: sx, y: sy)) / denominator
            let segmentT = cross(delta, lineDirection) / denominator
            guard segmentT >= -0.02, segmentT <= 1.02 else { return nil }

            return CGPoint(x: linePoint.x + lineDirection.x * lineT,
                           y: linePoint.y + lineDirection.y * lineT)
        }

        private func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            a.x * b.y - a.y * b.x
        }

        private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            hypot(a.x - b.x, a.y - b.y)
        }

        private func snapPreviewKind(_ result: SnapResult?) -> Int {
            switch result {
            case .vertex: return 2
            case .wall: return 1
            case .grid: return 0
            case nil: return -1
            }
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
            contentState.magnifierPoint = parent.showsMagnifier ? currentMagnifierPoint : nil
            contentState.magnifierZoomScale = currentZoomScale
            contentState.snapPreview = currentSnapPreview
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
                let newSelection = hitTest(tapPoint, in: parent.document)
                if newSelection != .none && newSelection != parent.selection {
                    selectionHaptic.selectionChanged()
                }
                parent.selection = newSelection
            case .drawRoomArea:
                parent.onTapRoomArea?(tapPoint)
            case .draw:
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
            // Furniture items (checked before walls). Hit-testing mirrors the
            // draw order reversed: topmost first, so flat items (rugs) are
            // checked last and never steal taps from furniture sitting on them.
            for item in doc.furnitureDrawOrder.reversed() {
                if item.containsVisualPoint(point) {
                    return .furniture(item.id)
                }
            }
            // Walls — tolerance proportional to wall width
            var bestWall: (id: UUID, dist: CGFloat)?
            for wall in doc.walls {
                let proj      = wall.project(point)
                let tolerance = DrawingDocument.wallWidth(for: wall.kind) / 2 + canvasThreshold(12)
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
            if gr === mainGesture && other is UIPanGestureRecognizer {
                // In select il pan a un dito e il drag si contendono lo stesso
                // tocco: mai simultanei. In disegno il pan richiede due dita e
                // DEVE poter partire mentre il tratto è attivo, perché è
                // proprio lui a cancellarlo.
                return (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
            }
            return true
        }

        /// Il tratto muore appena il gesto di scroll/zoom comincia: il
        /// toggle di `isEnabled` è il modo canonico di forzare `.cancelled`,
        /// e il ramo `.cancelled` dei gesti pulisce senza committare.
        @objc func cancelDrawOnScrollGesture(_ gr: UIGestureRecognizer) {
            guard gr.state == .began else { return }
            cancelMainGesture()
        }

        /// Il toggle di `isEnabled` è il modo canonico di forzare `.cancelled`;
        /// il ramo `.cancelled` dei gesti pulisce senza committare.
        private func cancelMainGesture() {
            stopAutoPan()
            guard let main = mainGesture,
                  main.state == .began || main.state == .changed
            else { return }
            main.isEnabled = false
            main.isEnabled = true
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }

        /// Prevents the tap gesture from firing when the long-press (main) gesture is already
        /// in an active dragging state (began / changed). Without this, a slow drag that ends
        /// near the touch-down point triggers a tap, deselecting the element just dragged.
        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            if let view = gr.view {
                let point = touch.location(in: view)
                if parent.chromeInsets.contains(point, in: view.bounds) {
                    return false
                }
            }

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

private extension UIEdgeInsets {
    func contains(_ point: CGPoint, in bounds: CGRect) -> Bool {
        point.x < bounds.minX + left ||
        point.x > bounds.maxX - right ||
        point.y < bounds.minY + top ||
        point.y > bounds.maxY - bottom
    }
}

private extension SnapResult {
    func at(_ point: CGPoint) -> SnapResult {
        switch self {
        case .vertex: return .vertex(point)
        case .wall: return .wall(point)
        case .grid: return .grid(point)
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
    var magnifierPoint: CGPoint?
    var magnifierZoomScale: CGFloat = 1
    var showsMagnifier: Bool = false
    var snapPreview: SnapResult?
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
            showDimensions: state.showDimensions,
            magnifierPoint: state.magnifierPoint,
            magnifierZoomScale: state.magnifierZoomScale,
            showsMagnifier: state.showsMagnifier,
            snapPreview: state.snapPreview
        )
    }
}
