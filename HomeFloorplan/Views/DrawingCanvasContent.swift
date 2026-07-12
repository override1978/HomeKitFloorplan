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

    /// Guide line shown during axis-snap of a wall endpoint (nil when not active).
    let axisSnapGuide: (from: CGPoint, to: CGPoint)?
    /// When false, dimension labels (wall lengths in metres) are not rendered.
    let showDimensions: Bool

    @AppStorage(DimensionUnit.appStorageKey)
    private var dimensionUnitRaw: String = DimensionUnit.metric.rawValue

    private var dimensionUnit: DimensionUnit {
        DimensionUnit(rawValue: dimensionUnitRaw) ?? .metric
    }

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

            // 4c. Dimension labels for exterior walls (scale: DrawingDocument.ptsPerMeter pt = 1 m)
            if showDimensions {
            for wall in document.walls where wall.kind == .exterior {
                let len = wall.length
                guard len >= 60 else { continue }
                let label = dimensionUnit.format(pt: len)
                let mid = CGPoint(x: (wall.start.x + wall.end.x) / 2,
                                  y: (wall.start.y + wall.end.y) / 2)
                let isHoriz = abs(wall.end.x - wall.start.x) >= abs(wall.end.y - wall.start.y)
                let labelPt = isHoriz
                    ? CGPoint(x: mid.x, y: mid.y - 26)
                    : CGPoint(x: mid.x + 30, y: mid.y)
                ctx.draw(
                    Text(label)
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.secondary),
                    at: labelPt, anchor: .center
                )
            }
            // Also label the preview wall (if exterior) during draw.
            // Non-orthogonal walls get the inclination appended (e.g. "10.0 m · 15°").
            if let pw = previewWall, pw.kind == .exterior, pw.length >= 60 {
                var label = dimensionUnit.format(pt: pw.length)
                let rawDeg = atan2(pw.end.y - pw.start.y, pw.end.x - pw.start.x) * 180 / .pi
                var inclination = rawDeg < 0 ? rawDeg + 180 : rawDeg
                if inclination > 90 { inclination = 180 - inclination }
                if inclination > 0.5, abs(inclination - 90) > 0.5 {
                    label += " · \(Int(inclination.rounded()))°"
                }
                let mid = CGPoint(x: (pw.start.x + pw.end.x) / 2,
                                  y: (pw.start.y + pw.end.y) / 2)
                let isHoriz = abs(pw.end.x - pw.start.x) >= abs(pw.end.y - pw.start.y)
                let labelPt = isHoriz
                    ? CGPoint(x: mid.x, y: mid.y - 26)
                    : CGPoint(x: mid.x + 30, y: mid.y)
                ctx.draw(
                    Text(label)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor.opacity(0.85)),
                    at: labelPt, anchor: .center
                )
            }
            } // end if showDimensions

            // 5. Cursor crosshair (draw mode only)
            let isDrawMode: Bool
            if case .draw = mode { isDrawMode = true } else { isDrawMode = false }
            if isDrawMode, let pt = cursorPoint {
                drawCrosshair(at: pt, context: &ctx)
                if isVertexSnap {
                    drawVertexSnapIndicator(at: pt, context: &ctx)
                }
            }

            // 5b. Axis snap guide line (shown while dragging a wall endpoint)
            if let guide = axisSnapGuide {
                var guidePath = Path()
                guidePath.move(to: guide.from)
                guidePath.addLine(to: guide.to)
                ctx.stroke(guidePath,
                           with: .color(.cyan.opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4]))
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

    if let kind = area.floorKind {
        drawFloorPattern(kind, in: fillPath, bounds: area.boundingRect, context: &context)
    } else {
        context.fill(fillPath, with: .color(fillColor))
    }

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

// MARK: - Floor pattern rendering

func drawFloorPattern(_ kind: FloorKind,
                      in clipPath: Path,
                      bounds: CGRect,
                      context: inout GraphicsContext) {
    // Copy context so the clip region stays local to this function.
    var ctx = context
    ctx.clip(to: clipPath)

    switch kind {
    case .legno:
        ctx.fill(clipPath, with: .color(Color(red: 0.85, green: 0.72, blue: 0.52).opacity(0.28)))
        var y = (bounds.minY / 12).rounded(.down) * 12
        while y <= bounds.maxY {
            var p = Path()
            p.move(to: CGPoint(x: bounds.minX, y: y))
            p.addLine(to: CGPoint(x: bounds.maxX, y: y))
            ctx.stroke(p, with: .color(Color(red: 0.58, green: 0.40, blue: 0.22).opacity(0.22)), lineWidth: 0.8)
            y += 12
        }

    case .piastrelle:
        ctx.fill(clipPath, with: .color(Color(red: 0.93, green: 0.91, blue: 0.87).opacity(0.40)))
        drawFloorGrid(bounds: bounds, spacing: 30, color: Color.gray.opacity(0.28), context: &ctx)

    case .gres:
        ctx.fill(clipPath, with: .color(Color(red: 0.87, green: 0.85, blue: 0.80).opacity(0.38)))
        drawFloorGrid(bounds: bounds, spacing: 60, color: Color.gray.opacity(0.32), context: &ctx)

    case .marmo:
        ctx.fill(clipPath, with: .color(Color(red: 0.96, green: 0.95, blue: 0.92).opacity(0.45)))
        let diag = max(bounds.width, bounds.height) * 2
        var offset: CGFloat = -diag
        while offset <= diag {
            var p = Path()
            p.move(to: CGPoint(x: bounds.midX + offset - diag, y: bounds.midY - diag))
            p.addLine(to: CGPoint(x: bounds.midX + offset + diag, y: bounds.midY + diag))
            ctx.stroke(p, with: .color(Color(red: 0.68, green: 0.65, blue: 0.62).opacity(0.18)), lineWidth: 0.7)
            offset += 40
        }

    case .cemento:
        ctx.fill(clipPath, with: .color(Color(red: 0.70, green: 0.69, blue: 0.67).opacity(0.32)))
    }
}

func drawFloorGrid(bounds: CGRect, spacing: CGFloat, color: Color, context: inout GraphicsContext) {
    var x = (bounds.minX / spacing).rounded(.down) * spacing
    while x <= bounds.maxX {
        var p = Path()
        p.move(to: CGPoint(x: x, y: bounds.minY))
        p.addLine(to: CGPoint(x: x, y: bounds.maxY))
        context.stroke(p, with: .color(color), lineWidth: 0.8)
        x += spacing
    }
    var y = (bounds.minY / spacing).rounded(.down) * spacing
    while y <= bounds.maxY {
        var p = Path()
        p.move(to: CGPoint(x: bounds.minX, y: y))
        p.addLine(to: CGPoint(x: bounds.maxX, y: y))
        context.stroke(p, with: .color(color), lineWidth: 0.8)
        y += spacing
    }
}

func drawFurnitureItem(_ item: FurnitureItem,
                       context: inout GraphicsContext,
                       selected: Bool) {
    var rotatedContext = context
    rotatedContext.translateBy(x: item.rect.midX, y: item.rect.midY)
    rotatedContext.rotate(by: .degrees(item.rotationDegrees))
    rotatedContext.translateBy(x: -item.rect.midX, y: -item.rect.midY)
    drawFurnitureShape(item, context: &rotatedContext)

    if selected {
        context.stroke(
            furnitureSelectionPath(item),
            with: .color(DrawingStyle.selectionColor),
            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
        )
        for corner in item.visualCorners {
            drawEndpointHandle(at: corner, context: &context)
        }
    } else {
        context.stroke(
            furnitureSelectionPath(item),
            with: .color(DrawingStyle.furnitureBorder.opacity(0.28)),
            style: StrokeStyle(lineWidth: 0.75, dash: [4, 4])
        )
    }

    if item.showsName {
        let font = Font.system(size: 12, weight: .medium)
        let textColor = selected ? DrawingStyle.selectionColor : DrawingStyle.furnitureText
        let resolvedText = context.resolve(
            Text(item.name).font(font).foregroundColor(textColor)
        )
        context.draw(resolvedText, at: CGPoint(x: item.rect.midX, y: item.rect.midY), anchor: .center)
    }
}

private func furnitureSelectionPath(_ item: FurnitureItem) -> Path {
    let corners = item.visualCorners
    var path = Path()
    path.move(to: corners[0])
    path.addLine(to: corners[1])
    path.addLine(to: corners[3])
    path.addLine(to: corners[2])
    path.closeSubpath()
    return path
}

private func drawFurnitureShape(_ item: FurnitureItem, context: inout GraphicsContext) {
    let rect = item.rect
    let fill: Color
    if let tint = item.tint, item.kind.supportsTint {
        fill = Color(UIColor { t in
            UIColor(cgColor: t.userInterfaceStyle == .dark ? tint.darkCGColor : tint.lightCGColor)
        }).opacity(0.85)
    } else {
        fill = DrawingStyle.furnitureFill
    }
    let stroke = DrawingStyle.furnitureBorder
    let detail = DrawingStyle.furnitureText.opacity(0.55)
    let style = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)

    func rounded(_ r: CGRect, radius: CGFloat = 5) -> Path {
        Path(roundedRect: r, cornerRadius: min(radius, min(r.width, r.height) / 2))
    }

    func strokeLine(_ a: CGPoint, _ b: CGPoint, color: Color = DrawingStyle.furnitureText.opacity(0.45)) {
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        context.stroke(path, with: .color(color), style: style)
    }

    switch item.kind {
    case .sofa:
        let frame = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.10)
        let armWidth = frame.width * 0.15
        let backHeight = frame.height * 0.18
        let pillowHeight = frame.height * 0.28
        let seatY = frame.minY + backHeight + pillowHeight * 0.62
        let seatHeight = frame.maxY - seatY
        let innerX = frame.minX + armWidth
        let innerW = frame.width - armWidth * 2
        let structuralFill = stroke.opacity(0.20)
        let cushionStroke = stroke.opacity(0.58)

        let back = CGRect(x: frame.minX + armWidth * 0.20, y: frame.minY, width: frame.width - armWidth * 0.40, height: backHeight)
        let leftArm = CGRect(x: frame.minX, y: frame.minY + backHeight * 0.30, width: armWidth, height: frame.height - backHeight * 0.55)
        let rightArm = CGRect(x: frame.maxX - armWidth, y: leftArm.minY, width: armWidth, height: leftArm.height)
        context.fill(rounded(back, radius: 6), with: .color(structuralFill))
        context.stroke(rounded(back, radius: 6), with: .color(cushionStroke), style: style)
        context.fill(rounded(leftArm, radius: 8), with: .color(structuralFill))
        context.stroke(rounded(leftArm, radius: 8), with: .color(cushionStroke), style: style)
        context.fill(rounded(rightArm, radius: 8), with: .color(structuralFill))
        context.stroke(rounded(rightArm, radius: 8), with: .color(cushionStroke), style: style)

        let pillowY = frame.minY + backHeight * 0.72
        let pillowW = innerW / 2
        let leftPillow = CGRect(x: innerX, y: pillowY, width: pillowW, height: pillowHeight)
        let rightPillow = CGRect(x: innerX + pillowW, y: pillowY, width: pillowW, height: pillowHeight)
        context.fill(rounded(leftPillow, radius: 7), with: .color(fill))
        context.stroke(rounded(leftPillow, radius: 7), with: .color(stroke), style: style)
        context.fill(rounded(rightPillow, radius: 7), with: .color(fill))
        context.stroke(rounded(rightPillow, radius: 7), with: .color(stroke), style: style)

        let leftSeat = CGRect(x: innerX, y: seatY, width: pillowW, height: seatHeight)
        let rightSeat = CGRect(x: innerX + pillowW, y: seatY, width: pillowW, height: seatHeight)
        context.fill(rounded(leftSeat, radius: 6), with: .color(fill))
        context.stroke(rounded(leftSeat, radius: 6), with: .color(stroke), style: style)
        context.fill(rounded(rightSeat, radius: 6), with: .color(fill))
        context.stroke(rounded(rightSeat, radius: 6), with: .color(stroke), style: style)
        strokeLine(CGPoint(x: innerX + pillowW, y: pillowY), CGPoint(x: innerX + pillowW, y: frame.maxY), color: detail)
        context.stroke(rounded(frame, radius: 10), with: .color(stroke.opacity(0.42)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

    case .armchair:
        let frame = rect.insetBy(dx: rect.width * 0.11, dy: rect.height * 0.10)
        let armWidth = frame.width * 0.22
        let backHeight = frame.height * 0.20
        let pillowHeight = frame.height * 0.26
        let seatY = frame.minY + backHeight + pillowHeight * 0.58
        let seatHeight = frame.maxY - seatY
        let innerX = frame.minX + armWidth
        let innerW = frame.width - armWidth * 2
        let structuralFill = stroke.opacity(0.20)
        let cushionStroke = stroke.opacity(0.58)

        let back = CGRect(x: frame.minX + armWidth * 0.18, y: frame.minY, width: frame.width - armWidth * 0.36, height: backHeight)
        let leftArm = CGRect(x: frame.minX, y: frame.minY + backHeight * 0.30, width: armWidth, height: frame.height - backHeight * 0.55)
        let rightArm = CGRect(x: frame.maxX - armWidth, y: leftArm.minY, width: armWidth, height: leftArm.height)
        context.fill(rounded(back, radius: 6), with: .color(structuralFill))
        context.stroke(rounded(back, radius: 6), with: .color(cushionStroke), style: style)
        context.fill(rounded(leftArm, radius: 8), with: .color(structuralFill))
        context.stroke(rounded(leftArm, radius: 8), with: .color(cushionStroke), style: style)
        context.fill(rounded(rightArm, radius: 8), with: .color(structuralFill))
        context.stroke(rounded(rightArm, radius: 8), with: .color(cushionStroke), style: style)

        let pillow = CGRect(x: innerX, y: frame.minY + backHeight * 0.72, width: innerW, height: pillowHeight)
        let seat = CGRect(x: innerX, y: seatY, width: innerW, height: seatHeight)
        context.fill(rounded(pillow, radius: 7), with: .color(fill))
        context.stroke(rounded(pillow, radius: 7), with: .color(stroke), style: style)
        context.fill(rounded(seat, radius: 6), with: .color(fill))
        context.stroke(rounded(seat, radius: 6), with: .color(stroke), style: style)
        strokeLine(CGPoint(x: innerX, y: seatY), CGPoint(x: innerX + innerW, y: seatY), color: detail)
        context.stroke(rounded(frame, radius: 10), with: .color(stroke.opacity(0.42)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

    case .diningTable:
        let table = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.14)
        context.fill(Path(ellipseIn: table), with: .color(fill))
        context.stroke(Path(ellipseIn: table), with: .color(stroke), style: style)
        strokeLine(CGPoint(x: table.minX + table.width * 0.22, y: table.midY), CGPoint(x: table.maxX - table.width * 0.22, y: table.midY), color: detail)
        strokeLine(CGPoint(x: table.midX, y: table.minY + table.height * 0.22), CGPoint(x: table.midX, y: table.maxY - table.height * 0.22), color: detail)

    case .chair:
        let seat = CGRect(x: rect.minX + rect.width * 0.23, y: rect.minY + rect.height * 0.34, width: rect.width * 0.54, height: rect.height * 0.42)
        let back = CGRect(x: seat.minX - rect.width * 0.03, y: rect.minY + rect.height * 0.15, width: seat.width + rect.width * 0.06, height: rect.height * 0.16)
        context.fill(rounded(seat, radius: 4), with: .color(fill))
        context.stroke(rounded(seat, radius: 4), with: .color(stroke), style: style)
        context.fill(rounded(back, radius: 3), with: .color(stroke.opacity(0.22)))
        context.stroke(rounded(back, radius: 3), with: .color(stroke), style: style)
        strokeLine(CGPoint(x: back.minX + back.width * 0.14, y: back.maxY), CGPoint(x: seat.minX + seat.width * 0.18, y: seat.minY), color: detail)
        strokeLine(CGPoint(x: back.maxX - back.width * 0.14, y: back.maxY), CGPoint(x: seat.maxX - seat.width * 0.18, y: seat.minY), color: detail)
        let legColor = stroke.opacity(0.65)
        strokeLine(CGPoint(x: seat.minX + 3, y: seat.maxY), CGPoint(x: seat.minX - rect.width * 0.08, y: rect.maxY - rect.height * 0.10), color: legColor)
        strokeLine(CGPoint(x: seat.maxX - 3, y: seat.maxY), CGPoint(x: seat.maxX + rect.width * 0.08, y: rect.maxY - rect.height * 0.10), color: legColor)

    case .bed:
        let body = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.06)
        context.fill(rounded(body, radius: 7), with: .color(fill))
        context.stroke(rounded(body, radius: 7), with: .color(stroke), style: style)
        let pillowH = body.height * 0.22
        context.fill(rounded(CGRect(x: body.minX + body.width * 0.08, y: body.minY + body.height * 0.07, width: body.width * 0.36, height: pillowH), radius: 4), with: .color(Color(.systemBackground).opacity(0.65)))
        context.fill(rounded(CGRect(x: body.maxX - body.width * 0.44, y: body.minY + body.height * 0.07, width: body.width * 0.36, height: pillowH), radius: 4), with: .color(Color(.systemBackground).opacity(0.65)))
        strokeLine(CGPoint(x: body.minX, y: body.minY + body.height * 0.36), CGPoint(x: body.maxX, y: body.minY + body.height * 0.36), color: detail)

    case .wardrobe:
        let body = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.10)
        context.fill(rounded(body, radius: 4), with: .color(fill))
        context.stroke(rounded(body, radius: 4), with: .color(stroke), style: style)
        strokeLine(CGPoint(x: body.midX, y: body.minY), CGPoint(x: body.midX, y: body.maxY), color: detail)
        context.fill(Path(ellipseIn: CGRect(x: body.midX - 6, y: body.midY - 2, width: 4, height: 4)), with: .color(detail))
        context.fill(Path(ellipseIn: CGRect(x: body.midX + 2, y: body.midY - 2, width: 4, height: 4)), with: .color(detail))

    case .toilet:
        let tank = CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.12, width: rect.width * 0.56, height: rect.height * 0.24)
        let bowl = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.34, width: rect.width * 0.64, height: rect.height * 0.46)
        context.fill(rounded(tank, radius: 3), with: .color(fill))
        context.stroke(rounded(tank, radius: 3), with: .color(stroke), style: style)
        context.fill(Path(ellipseIn: bowl), with: .color(fill))
        context.stroke(Path(ellipseIn: bowl), with: .color(stroke), style: style)
        context.stroke(Path(ellipseIn: bowl.insetBy(dx: bowl.width * 0.23, dy: bowl.height * 0.22)), with: .color(detail), style: style)

    case .sink:
        let basin = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.18)
        context.fill(Path(ellipseIn: basin), with: .color(fill))
        context.stroke(Path(ellipseIn: basin), with: .color(stroke), style: style)
        context.stroke(Path(ellipseIn: basin.insetBy(dx: basin.width * 0.22, dy: basin.height * 0.22)), with: .color(detail), style: style)
        strokeLine(CGPoint(x: rect.midX, y: basin.minY), CGPoint(x: rect.midX, y: basin.minY - rect.height * 0.12), color: stroke)

    case .inductionCooktop:
        let cooktop = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.10)
        context.fill(rounded(cooktop, radius: 5), with: .color(fill))
        context.stroke(rounded(cooktop, radius: 5), with: .color(stroke), style: style)

        let zoneRadius = min(cooktop.width, cooktop.height) * 0.15
        let zoneCenters = [
            CGPoint(x: cooktop.minX + cooktop.width * 0.30, y: cooktop.minY + cooktop.height * 0.34),
            CGPoint(x: cooktop.maxX - cooktop.width * 0.30, y: cooktop.minY + cooktop.height * 0.34),
            CGPoint(x: cooktop.minX + cooktop.width * 0.30, y: cooktop.maxY - cooktop.height * 0.34),
            CGPoint(x: cooktop.maxX - cooktop.width * 0.30, y: cooktop.maxY - cooktop.height * 0.34)
        ]
        for center in zoneCenters {
            let zone = CGRect(x: center.x - zoneRadius, y: center.y - zoneRadius, width: zoneRadius * 2, height: zoneRadius * 2)
            context.stroke(Path(ellipseIn: zone), with: .color(detail), style: style)
            context.stroke(Path(ellipseIn: zone.insetBy(dx: zoneRadius * 0.38, dy: zoneRadius * 0.38)), with: .color(detail.opacity(0.7)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        strokeLine(
            CGPoint(x: cooktop.midX - cooktop.width * 0.18, y: cooktop.maxY - cooktop.height * 0.12),
            CGPoint(x: cooktop.midX + cooktop.width * 0.18, y: cooktop.maxY - cooktop.height * 0.12),
            color: detail
        )

    case .washingMachine:
        let body = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.08)
        let panel = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.22)
        let doorRadius = min(body.width, body.height) * 0.24
        let doorCenter = CGPoint(x: body.midX, y: body.minY + body.height * 0.58)
        let door = CGRect(x: doorCenter.x - doorRadius, y: doorCenter.y - doorRadius, width: doorRadius * 2, height: doorRadius * 2)

        context.fill(rounded(body, radius: 6), with: .color(fill))
        context.stroke(rounded(body, radius: 6), with: .color(stroke), style: style)
        context.stroke(rounded(panel, radius: 3), with: .color(detail), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        context.stroke(Path(ellipseIn: door), with: .color(stroke), style: style)
        context.stroke(Path(ellipseIn: door.insetBy(dx: doorRadius * 0.28, dy: doorRadius * 0.28)), with: .color(detail), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        context.fill(Path(ellipseIn: CGRect(x: panel.maxX - panel.width * 0.20, y: panel.midY - 3, width: 6, height: 6)), with: .color(detail))
        strokeLine(CGPoint(x: panel.minX + panel.width * 0.12, y: panel.midY), CGPoint(x: panel.minX + panel.width * 0.34, y: panel.midY), color: detail)

    case .bathtub:
        let tub = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.18)
        context.fill(rounded(tub, radius: tub.height / 2), with: .color(fill))
        context.stroke(rounded(tub, radius: tub.height / 2), with: .color(stroke), style: style)
        context.stroke(rounded(tub.insetBy(dx: tub.width * 0.10, dy: tub.height * 0.20), radius: tub.height / 3), with: .color(detail), style: style)
        strokeLine(CGPoint(x: tub.minX + tub.width * 0.12, y: tub.minY), CGPoint(x: tub.minX + tub.width * 0.12, y: tub.minY - rect.height * 0.10), color: stroke)

    case .shower:
        let base = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
        context.fill(rounded(base, radius: 4), with: .color(fill))
        context.stroke(rounded(base, radius: 4), with: .color(stroke), style: style)
        strokeLine(CGPoint(x: base.minX, y: base.minY), CGPoint(x: base.maxX, y: base.maxY), color: detail)
        strokeLine(CGPoint(x: base.maxX, y: base.minY), CGPoint(x: base.minX, y: base.maxY), color: detail)
        context.fill(Path(ellipseIn: CGRect(x: base.midX - 4, y: base.midY - 4, width: 8, height: 8)), with: .color(detail))

    case .kitchenCounter:
        let body = rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.08)
        context.fill(rounded(body, radius: 4), with: .color(fill))
        context.stroke(rounded(body, radius: 4), with: .color(stroke), style: style)
        let inner = body.insetBy(dx: min(6, body.width * 0.06), dy: min(6, body.height * 0.14))
        context.stroke(rounded(inner, radius: 3), with: .color(detail), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

    case .tvUnit:
        let cabinet = rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.18)
        context.fill(rounded(cabinet, radius: 4), with: .color(fill))
        context.stroke(rounded(cabinet, radius: 4), with: .color(stroke), style: style)
        let tv = CGRect(x: rect.midX - rect.width * 0.35,
                        y: cabinet.minY + cabinet.height * 0.18,
                        width: rect.width * 0.70,
                        height: max(3, cabinet.height * 0.20))
        context.fill(rounded(tv, radius: 2), with: .color(stroke.opacity(0.65)))

    case .plant:
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let leafW = side * 0.42, leafH = side * 0.22
        for i in 0 ..< 6 {
            let angle = Double(i) * 60.0
            var leafCtx = context
            leafCtx.translateBy(x: center.x, y: center.y)
            leafCtx.rotate(by: .degrees(angle))
            let leafRect = CGRect(x: side * 0.10, y: -leafH / 2, width: leafW, height: leafH)
            leafCtx.fill(Path(ellipseIn: leafRect), with: .color(Color(red: 0.45, green: 0.62, blue: 0.45).opacity(0.35)))
            leafCtx.stroke(Path(ellipseIn: leafRect), with: .color(Color(red: 0.38, green: 0.55, blue: 0.40).opacity(0.7)), style: StrokeStyle(lineWidth: 1))
        }
        let potR = side * 0.16
        let pot = CGRect(x: center.x - potR, y: center.y - potR, width: potR * 2, height: potR * 2)
        context.fill(Path(ellipseIn: pot), with: .color(fill))
        context.stroke(Path(ellipseIn: pot), with: .color(stroke), style: style)

    case .rug:
        context.fill(rounded(rect, radius: 8), with: .color(fill.opacity(0.35)))
        context.stroke(rounded(rect, radius: 8), with: .color(stroke.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2))
        let inner = rect.insetBy(dx: min(9, rect.width * 0.08), dy: min(9, rect.height * 0.08))
        context.stroke(rounded(inner, radius: 5), with: .color(detail), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

    case .stairs:
        let body = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04)
        context.fill(rounded(body, radius: 3), with: .color(fill))
        context.stroke(rounded(body, radius: 3), with: .color(stroke), style: style)
        // Treads: ~26 pt each (≈26 cm at 100 pt/m)
        let count = max(3, Int(body.height / 26))
        let step = body.height / CGFloat(count)
        for i in 1 ..< count {
            let y = body.minY + CGFloat(i) * step
            strokeLine(CGPoint(x: body.minX, y: y), CGPoint(x: body.maxX, y: y))
        }
        // Walkline: circle at the base, arrow pointing up (climb direction)
        let cx = body.midX
        let tipY = body.minY + step * 0.6
        strokeLine(CGPoint(x: cx, y: body.maxY - step * 0.5), CGPoint(x: cx, y: tipY), color: stroke)
        let ah = min(8, body.width * 0.14)
        strokeLine(CGPoint(x: cx - ah, y: tipY + ah), CGPoint(x: cx, y: tipY), color: stroke)
        strokeLine(CGPoint(x: cx + ah, y: tipY + ah), CGPoint(x: cx, y: tipY), color: stroke)
        context.fill(Path(ellipseIn: CGRect(x: cx - 3, y: body.maxY - step * 0.5 - 3, width: 6, height: 6)),
                     with: .color(stroke))

    case .spiralStairs:
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerR = side * 0.48
        let outer = CGRect(x: center.x - outerR, y: center.y - outerR,
                           width: outerR * 2, height: outerR * 2)
        context.fill(Path(ellipseIn: outer), with: .color(fill))
        context.stroke(Path(ellipseIn: outer), with: .color(stroke), style: style)
        let poleR = side * 0.07
        for i in 0 ..< 10 {
            let a = CGFloat(i) * (.pi * 2 / 10)
            strokeLine(CGPoint(x: center.x + cos(a) * poleR, y: center.y + sin(a) * poleR),
                       CGPoint(x: center.x + cos(a) * outerR, y: center.y + sin(a) * outerR))
        }
        context.fill(Path(ellipseIn: CGRect(x: center.x - poleR, y: center.y - poleR,
                                            width: poleR * 2, height: poleR * 2)),
                     with: .color(stroke.opacity(0.7)))

    case .generic:
        context.fill(rounded(rect, radius: 4), with: .color(fill))
        context.stroke(rounded(rect, radius: 4), with: .color(stroke), style: style)
    }
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
