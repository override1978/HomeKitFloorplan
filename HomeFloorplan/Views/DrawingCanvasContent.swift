import SwiftUI

// MARK: - DrawingCanvasContent

/// Pure SwiftUI `Canvas` view that renders the drawing document.
/// Hosted inside a `UIScrollView` via `UIHostingController` (see `DrawingCanvasView`).
///
/// All interactions (gestures) are handled by the parent `UIScrollView` coordinator;
/// this view only does rendering based on the bound state.
struct DrawingCanvasContent: View {

    // MARK: Inputs (passed from DrawingCanvasView coordinator)

    let document: DrawingDocument
    let mode: DrawingMode
    let selection: DrawingSelection

    /// The wall currently being drawn (nil when not in draw-drag).
    let previewWall: WallSegment?

    /// The room area rectangle being drawn via drag (nil when not in drawRoomArea drag).
    let previewArea: CGRect?

    /// Snapped cursor position while drawing (for crosshair feedback).
    let cursorPoint: CGPoint?

    /// True when the cursor is snapped to an existing wall vertex (shows snap indicator).
    let isVertexSnap: Bool

    // MARK: Body

    var body: some View {
        let size = DrawingDocument.canvasSize

        Canvas { ctx, _ in
            // 0. Room areas (drawn first, behind everything)
            for area in document.roomAreas {
                let isSelected: Bool
                if case .roomArea(let id) = selection { isSelected = area.id == id } else { isSelected = false }
                drawRoomArea(area, context: &ctx, selected: isSelected)
            }
            // 0b. Preview area while dragging to draw a new room area
            if let pa = previewArea {
                drawPreviewArea(pa, context: &ctx)
            }

            // 0c. Furniture items (after room areas, before grid)
            for item in document.furnitureItems {
                let isSelected: Bool
                if case .furniture(let id) = selection { isSelected = item.id == id } else { isSelected = false }
                drawFurnitureItem(item, context: &ctx, selected: isSelected)
            }

            // 1. Grid
            drawGrid(in: CGRect(x: 0, y: 0, width: size, height: size),
                     spacing: DrawingDocument.gridSpacing,
                     context: &ctx)

            // 2. Committed walls — draw order: balcony first, interior, exterior last.
            let wallDrawOrder: [WallKind] = [.balcony, .interior, .exterior]
            for kind in wallDrawOrder {
                for wall in document.walls where wall.kind == kind {
                    let isSelected: Bool
                    if case .wall(let id) = selection { isSelected = wall.id == id } else { isSelected = false }
                    drawWall(wall, context: &ctx, selected: isSelected)
                }
            }

            // 3. Preview wall (in-progress draw stroke)
            if let pw = previewWall {
                let w = DrawingDocument.wallWidth(for: pw.kind)
                var previewPath = Path()
                previewPath.move(to: pw.start)
                previewPath.addLine(to: pw.end)
                if pw.kind == .balcony {
                    ctx.stroke(previewPath,
                               with: .color(DrawingStyle.wallColor.opacity(0.45)),
                               style: StrokeStyle(lineWidth: w, lineCap: .square))
                    ctx.stroke(previewPath,
                               with: .color(Color(.systemBackground).opacity(0.7)),
                               style: StrokeStyle(lineWidth: w * 0.45, lineCap: .square))
                } else {
                    ctx.stroke(previewPath,
                               with: .color(DrawingStyle.wallColor.opacity(0.45)),
                               style: StrokeStyle(lineWidth: w, lineCap: .square, dash: [8, 4]))
                }
            }

            // 4. Openings
            for opening in document.openings {
                guard let wall = document.wall(for: opening.wallID) else { continue }
                let isSelected: Bool
                if case .opening(let id) = selection { isSelected = opening.id == id } else { isSelected = false }
                switch opening.kind {
                case .door:   drawDoor(opening, wall: wall, context: &ctx, selected: isSelected)
                case .window: drawWindow(opening, wall: wall, context: &ctx, selected: isSelected)
                }
            }

            // 4b. Room labels
            for label in document.roomLabels {
                let isSelected: Bool
                if case .roomLabel(let id) = selection { isSelected = label.id == id } else { isSelected = false }
                drawRoomLabel(label, context: &ctx, selected: isSelected)
            }

            // 5. Cursor crosshair (draw mode only)
            let isDrawMode: Bool
            if case .draw = mode { isDrawMode = true } else { isDrawMode = false }
            if isDrawMode, let pt = cursorPoint {
                drawCrosshair(at: pt, context: &ctx)
                if isVertexSnap {
                    drawVertexSnapIndicator(at: pt, context: &ctx)
                }
            }

            // 6. Selection handles
            drawSelectionHandles(selection: selection, document: document, context: &ctx)
        }
        .frame(width: size, height: size)
        .background(Color(.systemBackground))
    }

    // MARK: - Private helpers (editor-only)

    private func drawPreviewArea(_ rect: CGRect, context: inout GraphicsContext) {
        let cornerRadius: CGFloat = 8
        context.fill(
            Path(roundedRect: rect, cornerRadius: cornerRadius),
            with: .color(DrawingStyle.selectionColor.opacity(0.08))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: cornerRadius),
            with: .color(DrawingStyle.selectionColor.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1.5, dash: [8, 5])
        )
    }

    private func drawVertexSnapIndicator(at point: CGPoint, context: inout GraphicsContext) {
        let r: CGFloat = 8
        let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        let circlePath = Path(ellipseIn: rect)
        context.fill(circlePath, with: .color(.green.opacity(0.35)))
        context.stroke(circlePath, with: .color(.green), lineWidth: 2)
    }

    private func drawCrosshair(at point: CGPoint, context: inout GraphicsContext) {
        let arm: CGFloat = 10
        let style = StrokeStyle(lineWidth: 1, lineCap: .round)
        var hPath = Path()
        hPath.move(to: CGPoint(x: point.x - arm, y: point.y))
        hPath.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        var vPath = Path()
        vPath.move(to: CGPoint(x: point.x, y: point.y - arm))
        vPath.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.stroke(hPath, with: .color(DrawingStyle.selectionColor.opacity(0.8)), style: style)
        context.stroke(vPath, with: .color(DrawingStyle.selectionColor.opacity(0.8)), style: style)
    }

    private func drawSelectionHandles(selection: DrawingSelection,
                                      document: DrawingDocument,
                                      context: inout GraphicsContext) {
        switch selection {
        case .wall(let id):
            guard let wall = document.wall(for: id) else { return }
            drawEndpointHandle(at: wall.start, context: &context)
            drawEndpointHandle(at: wall.end, context: &context)
            // Filled midpoint handle: indicates the wall body is draggable
            let mid = CGPoint(x: (wall.start.x + wall.end.x) / 2,
                              y: (wall.start.y + wall.end.y) / 2)
            drawEndpointHandle(at: mid, context: &context, filled: true)

        case .opening(let id):
            guard let opening = document.opening(for: id),
                  let wall = document.wall(for: opening.wallID),
                  let eps = document.openingEndpoints(opening) else { return }
            drawEndpointHandle(at: eps.start, context: &context)
            drawEndpointHandle(at: eps.end, context: &context)
            let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2,
                              y: (eps.start.y + eps.end.y) / 2)
            _ = wall
            drawEndpointHandle(at: mid, context: &context, filled: true)

        case .roomLabel, .roomArea, .furniture, .none:
            break
        }
    }
}

// MARK: - Shared drawing helpers (used by both DrawingCanvasContent and ScaledDrawingView)

func drawRoomLabel(_ label: RoomLabel,
                   context: inout GraphicsContext,
                   selected: Bool) {
    let badgeCGColor = RoomLabelPalette.color(at: label.colorIndex)
    let badgeColor   = Color(cgColor: badgeCGColor)

    let uppercased   = label.name.uppercased()
    let font         = Font.system(size: 13, weight: .bold)
    let resolvedText = context.resolve(
        Text(uppercased).font(font).foregroundColor(.white)
    )
    let textSize = resolvedText.measure(in: CGSize(width: 400, height: 100))

    let hPad: CGFloat = 10
    let vPad: CGFloat = 6
    let pillW = textSize.width  + hPad * 2
    let pillH = textSize.height + vPad * 2
    let pillRect = CGRect(
        x: label.position.x - pillW / 2,
        y: label.position.y - pillH / 2,
        width: pillW,
        height: pillH
    )
    let cornerRadius = pillH / 2

    context.fill(
        Path(roundedRect: pillRect, cornerRadius: cornerRadius),
        with: .color(selected ? DrawingStyle.selectionColor : badgeColor)
    )

    if selected {
        let ringRect = pillRect.insetBy(dx: -3, dy: -3)
        context.stroke(
            Path(roundedRect: ringRect, cornerRadius: cornerRadius + 3),
            with: .color(DrawingStyle.selectionColor),
            style: StrokeStyle(lineWidth: 2, dash: [5, 3])
        )
    }

    context.draw(resolvedText, at: label.position, anchor: .center)
}

func drawRoomArea(_ area: RoomArea,
                  context: inout GraphicsContext,
                  selected: Bool) {
    let cgColor     = RoomLabelPalette.color(at: area.colorIndex)
    let fillColor   = Color(cgColor: cgColor).opacity(0.15)
    let borderColor = Color(cgColor: cgColor).opacity(0.45)
    let textColor   = Color(cgColor: cgColor).opacity(0.7)

    // Build fill path: rounded rect for legacy areas, polygon for promoted ones.
    let fillPath: Path
    let borderPath: Path
    if let pts = area.points, pts.count >= 3 {
        // Polygon mode — use effectivePoints directly
        var p = Path()
        p.move(to: pts[0])
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.closeSubpath()
        fillPath   = p
        borderPath = p
    } else {
        fillPath   = Path(area.rect)
        borderPath = Path(area.rect)
    }

    context.fill(fillPath, with: .color(fillColor))

    if selected {
        context.stroke(borderPath,
                       with: .color(DrawingStyle.selectionColor),
                       style: StrokeStyle(lineWidth: 2))
        // Draw a handle at each effective vertex
        for corner in area.effectivePoints {
            drawEndpointHandle(at: corner, context: &context)
        }
        // Draw a "+" indicator at the midpoint of each edge to hint that tapping adds a vertex
        let pts = area.effectivePoints
        for i in 0 ..< pts.count {
            let a = pts[i]
            let b = pts[(i + 1) % pts.count]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            drawEdgeMidpointIndicator(at: mid, context: &context)
        }
    } else {
        context.stroke(borderPath,
                       with: .color(borderColor),
                       style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
    }

    let font = Font.system(size: 14, weight: .semibold)
    let resolvedText = context.resolve(
        Text(area.name.uppercased())
            .font(font)
            .foregroundColor(selected ? DrawingStyle.selectionColor : textColor)
    )
    let labelPt = area.centroid
    context.draw(resolvedText, at: labelPt, anchor: .center)
}

func drawFurnitureItem(_ item: FurnitureItem,
                       context: inout GraphicsContext,
                       selected: Bool) {
    let cornerRadius: CGFloat = 4

    context.fill(
        Path(roundedRect: item.rect, cornerRadius: cornerRadius),
        with: .color(DrawingStyle.furnitureFill)
    )

    if selected {
        context.stroke(
            Path(roundedRect: item.rect, cornerRadius: cornerRadius),
            with: .color(DrawingStyle.selectionColor),
            style: StrokeStyle(lineWidth: 2)
        )
        let corners: [CGPoint] = [
            CGPoint(x: item.rect.minX, y: item.rect.minY),
            CGPoint(x: item.rect.maxX, y: item.rect.minY),
            CGPoint(x: item.rect.minX, y: item.rect.maxY),
            CGPoint(x: item.rect.maxX, y: item.rect.maxY)
        ]
        for corner in corners {
            drawEndpointHandle(at: corner, context: &context)
        }
    } else {
        context.stroke(
            Path(roundedRect: item.rect, cornerRadius: cornerRadius),
            with: .color(DrawingStyle.furnitureBorder),
            style: StrokeStyle(lineWidth: 1)
        )
    }

    let font = Font.system(size: 12, weight: .medium)
    let textColor = selected ? DrawingStyle.selectionColor : DrawingStyle.furnitureText
    let resolvedText = context.resolve(
        Text(item.name).font(font).foregroundColor(textColor)
    )
    context.draw(resolvedText, at: CGPoint(x: item.rect.midX, y: item.rect.midY), anchor: .center)
}

/// Draws a small "+" circle at a polygon edge midpoint to indicate the edge is tappable
/// for inserting a new vertex.
func drawEdgeMidpointIndicator(at point: CGPoint, context: inout GraphicsContext) {
    let r: CGFloat = 5
    let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
    // White filled circle with selection-color border
    context.fill(Path(ellipseIn: rect), with: .color(Color(.systemBackground)))
    context.stroke(Path(ellipseIn: rect),
                   with: .color(DrawingStyle.selectionColor.opacity(0.6)),
                   lineWidth: 1.5)
    // "+" arms
    let arm: CGFloat = 3
    let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
    var h = Path()
    h.move(to: CGPoint(x: point.x - arm, y: point.y))
    h.addLine(to: CGPoint(x: point.x + arm, y: point.y))
    var v = Path()
    v.move(to: CGPoint(x: point.x, y: point.y - arm))
    v.addLine(to: CGPoint(x: point.x, y: point.y + arm))
    context.stroke(h, with: .color(DrawingStyle.selectionColor.opacity(0.7)), style: style)
    context.stroke(v, with: .color(DrawingStyle.selectionColor.opacity(0.7)), style: style)
}

func drawEndpointHandle(at point: CGPoint,
                        context: inout GraphicsContext,
                        filled: Bool = false) {
    let r: CGFloat = 5
    let rect = CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
    let circlePath = Path(ellipseIn: rect)

    if filled {
        context.fill(circlePath, with: .color(DrawingStyle.selectionColor))
    } else {
        context.fill(circlePath, with: .color(Color(.systemBackground)))
        context.stroke(circlePath,
                       with: .color(DrawingStyle.selectionColor),
                       lineWidth: 2)
    }
}

// MARK: - ScaledDrawingView

/// Read-only render of a `DrawingDocument` at an arbitrary target size.
///
/// Draws directly at `targetSize` using a `CGAffineTransform` scale on the
/// `GraphicsContext` — no SwiftUI `scaleEffect` involved, so the layout frame
/// is exactly `targetSize × targetSize` and aligns perfectly with marker overlays.
struct ScaledDrawingView: View {

    let document: DrawingDocument
    /// Side length of the square output view (canvas is always square).
    let targetSize: CGFloat

    private var scale: CGFloat { targetSize / DrawingDocument.canvasSize }

    var body: some View {
        Canvas { ctx, _ in
            ctx.transform = CGAffineTransform(scaleX: scale, y: scale)

            let canvasSize = DrawingDocument.canvasSize
            let canvasRect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)

            for area in document.roomAreas {
                drawRoomArea(area, context: &ctx, selected: false)
            }
            for item in document.furnitureItems {
                drawFurnitureItem(item, context: &ctx, selected: false)
            }
            drawGrid(in: canvasRect, spacing: DrawingDocument.gridSpacing, context: &ctx)
            for kind in [WallKind.balcony, .interior, .exterior] {
                for wall in document.walls where wall.kind == kind {
                    drawWall(wall, context: &ctx, selected: false)
                }
            }
            for opening in document.openings {
                guard let wall = document.wall(for: opening.wallID) else { continue }
                switch opening.kind {
                case .door:   drawDoor(opening, wall: wall, context: &ctx, selected: false)
                case .window: drawWindow(opening, wall: wall, context: &ctx, selected: false)
                }
            }
            for label in document.roomLabels {
                drawRoomLabel(label, context: &ctx, selected: false)
            }
        }
        .frame(width: targetSize, height: targetSize)
        .background(Color(.systemBackground))
    }
}
