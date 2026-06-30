import SwiftUI
import CoreGraphics

// MARK: - Wall rendering constants

enum DrawingStyle {
    /// Use DrawingDocument.wallWidth(for:) for per-kind widths.
    /// This fallback is kept for selection highlight math.
    static let wallWidthExterior: CGFloat = 16
    static let wallWidthInterior: CGFloat = 8
    /// Adaptive wall color: near-black in light mode, near-white in dark mode.
    static let wallColor: Color          = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.90, alpha: 1) : UIColor(white: 0.18, alpha: 1) })
    static let wallCGColor: CGColor      = CGColor(gray: 0.18, alpha: 1)  // PNG export only — always light bg

    static let selectionColor: Color     = .blue
    static let selectionWidth: CGFloat   = 3

    /// Adaptive door arc color.
    static let doorArcColor: Color       = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.75, alpha: 1) : UIColor(white: 0.30, alpha: 1) })
    static let doorCGColor: CGColor      = CGColor(gray: 0.30, alpha: 1)  // PNG export only

    static let doorLineWidth: CGFloat    = 2

    /// Adaptive window color.
    static let windowColor: Color        = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.60, alpha: 1) : UIColor(white: 0.45, alpha: 1) })
    static let windowCGColor: CGColor    = CGColor(gray: 0.45, alpha: 1)  // PNG export only

    static let windowLineWidth: CGFloat  = 2
    static let windowPaneCount: Int      = 3       // number of panes between outer lines

    /// Grid lines: subtle in both light and dark mode.
    static let gridColor: Color          = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.22, alpha: 1) : UIColor(white: 0.88, alpha: 1) })
    static let gridMajorColor: Color     = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.30, alpha: 1) : UIColor(white: 0.78, alpha: 1) })
    static let gridLineWidth: CGFloat    = 0.5

    /// Furniture fill: visible against systemBackground in both modes.
    static let furnitureFill: Color      = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : UIColor(white: 0.88, alpha: 1) })
    static let furnitureBorder: Color    = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.55, alpha: 1) : UIColor(white: 0.55, alpha: 1) })
    static let furnitureText: Color      = Color(UIColor { t in t.userInterfaceStyle == .dark ? UIColor(white: 0.80, alpha: 1) : UIColor(white: 0.35, alpha: 1) })
}

// MARK: - Exterior fill palette

enum ExteriorFillPalette: Int, CaseIterable {
    case warmGray = 0
    case tortora  = 1
    case sand     = 2
    case stone    = 3
    case sage     = 4
    case peach    = 5
    case brandGlow = 6

    var cgColor: CGColor {
        switch self {
        case .warmGray: return CGColor(red: 0.91, green: 0.91, blue: 0.88, alpha: 1.0)
        case .tortora:  return CGColor(red: 0.84, green: 0.81, blue: 0.77, alpha: 1.0)
        case .sand:     return CGColor(red: 0.91, green: 0.87, blue: 0.80, alpha: 1.0)
        case .stone:    return CGColor(red: 0.80, green: 0.82, blue: 0.84, alpha: 1.0)
        case .sage:     return CGColor(red: 0.82, green: 0.86, blue: 0.81, alpha: 1.0)
        case .peach:    return CGColor(red: 0.96, green: 0.90, blue: 0.86, alpha: 1.0)
        case .brandGlow: return CGColor(red: 1.00, green: 0.94, blue: 0.86, alpha: 1.0)
        }
    }

    var swiftUIColor: Color { Color(cgColor: cgColor) }

    var localizedName: String {
        switch self {
        case .warmGray: return String(localized: "exterior.fill.warmGray", defaultValue: "Warm Gray")
        case .tortora:  return String(localized: "exterior.fill.tortora",  defaultValue: "Tortora")
        case .sand:     return String(localized: "exterior.fill.sand",     defaultValue: "Sand")
        case .stone:    return String(localized: "exterior.fill.stone",    defaultValue: "Stone")
        case .sage:     return String(localized: "exterior.fill.sage",     defaultValue: "Sage")
        case .peach:    return String(localized: "exterior.fill.peach",    defaultValue: "Peach")
        case .brandGlow: return String(localized: "exterior.fill.brandGlow", defaultValue: "Brand Glow")
        }
    }
}

// MARK: - SwiftUI GraphicsContext renderers

/// Draws a single wall segment on a SwiftUI `GraphicsContext`.
func drawWall(_ wall: WallSegment,
              context: inout GraphicsContext,
              selected: Bool = false) {
    let w = DrawingDocument.wallWidth(for: wall.kind)

    var path = Path()
    path.move(to: wall.start)
    path.addLine(to: wall.end)

    if wall.kind == .balcony {
        // Balcony: double-line effect — dark outer stroke + white inner stroke
        // No selection halo needed (selection ring comes from drawSelectionHandles)
        if selected {
            context.stroke(path,
                           with: .color(DrawingStyle.selectionColor),
                           style: StrokeStyle(lineWidth: w + DrawingStyle.selectionWidth * 2,
                                              lineCap: .square))
        }
        // Outer dark line (same width as exterior wall)
        context.stroke(path,
                       with: .color(DrawingStyle.wallColor),
                       style: StrokeStyle(lineWidth: w, lineCap: .square))
        // Inner line (background color) — creates the hollow / double-line look
        let innerW = w * 0.45
        context.stroke(path,
                       with: .color(Color(.systemBackground)),
                       style: StrokeStyle(lineWidth: innerW, lineCap: .square))
    } else {
        if selected {
            context.stroke(path,
                           with: .color(DrawingStyle.selectionColor),
                           style: StrokeStyle(lineWidth: w + DrawingStyle.selectionWidth * 2,
                                              lineCap: .square))
        }
        context.stroke(path,
                       with: .color(DrawingStyle.wallColor),
                       style: StrokeStyle(lineWidth: w, lineCap: .square))
    }
}

/// Draws a door symbol on a SwiftUI `GraphicsContext`.
/// A door is rendered as:
///   - a gap (white rectangle) in the wall
///   - a thin vertical leaf line at one end
///   - a quarter-circle arc showing the swing arc
func drawDoor(_ opening: PlacedOpening,
              wall: WallSegment,
              context: inout GraphicsContext,
              selected: Bool = false) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len   // unit vector along wall

    // Normal pointing to one side; flipSide inverts it
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip, ny = ux * flip

    let pivot = eps.start
    let tip   = eps.end
    let radius = opening.width

    // White gap to erase wall underneath (sized to the host wall's actual width)
    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBand(from: eps.start, to: eps.end, halfWidth: wallW / 2 + 1, context: &context)

    // Swing arc: quarter circle from the leaf (closed) to perpendicular (open)
    var arcPath = Path()
    let leafAngle = Angle(radians: atan2(Double(uy), Double(ux)))
    let openAngle = Angle(radians: atan2(Double(ny),  Double(nx)))
    arcPath.addArc(center: pivot,
                   radius: radius,
                   startAngle: leafAngle,
                   endAngle: openAngle,
                   clockwise: opening.flipSide)

    // Leaf line (pivot → tip)
    var leafPath = Path()
    leafPath.move(to: pivot)
    leafPath.addLine(to: tip)

    let color: Color = selected ? DrawingStyle.selectionColor : DrawingStyle.doorArcColor
    context.stroke(arcPath,
                   with: .color(color),
                   style: StrokeStyle(lineWidth: DrawingStyle.doorLineWidth, lineCap: .round, dash: [4, 3]))
    context.stroke(leafPath,
                   with: .color(color),
                   style: StrokeStyle(lineWidth: DrawingStyle.doorLineWidth, lineCap: .round))
}

/// Draws a window symbol on a SwiftUI `GraphicsContext`.
/// A window is rendered as three thin parallel lines crossing the wall opening.
func drawWindow(_ opening: PlacedOpening,
                wall: WallSegment,
                context: inout GraphicsContext,
                selected: Bool = false) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len, ny = dx / len  // normal

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    let paneHalf: CGFloat = wallW * 0.7  // how far panes extend to each side

    // White gap
    eraseBand(from: eps.start, to: eps.end, halfWidth: wallW / 2 + 1, context: &context)

    let color: Color = selected ? DrawingStyle.selectionColor : DrawingStyle.windowColor
    let style = StrokeStyle(lineWidth: DrawingStyle.windowLineWidth, lineCap: .round)

    // Outer border lines (two parallel strokes along the opening, perpendicular to wall)
    for sign: CGFloat in [-1, 1] {
        var borderPath = Path()
        let offsetX = nx * paneHalf * sign
        let offsetY = ny * paneHalf * sign
        borderPath.move(to: CGPoint(x: eps.start.x + offsetX, y: eps.start.y + offsetY))
        borderPath.addLine(to: CGPoint(x: eps.end.x + offsetX, y: eps.end.y + offsetY))
        context.stroke(borderPath, with: .color(color), style: style)
    }

    // Center line (the "glass")
    var centerPath = Path()
    centerPath.move(to: eps.start)
    centerPath.addLine(to: eps.end)
    context.stroke(centerPath,
                   with: .color(color),
                   style: StrokeStyle(lineWidth: DrawingStyle.windowLineWidth * 2, lineCap: .round))
}

/// Draws the light gray grid on a SwiftUI `GraphicsContext`.
func drawGrid(in rect: CGRect,
              spacing: CGFloat,
              context: inout GraphicsContext) {
    let majorEvery: Int = 5   // every 5 cells draw a major line

    var x = (floor(rect.minX / spacing) * spacing)
    var col = Int(floor(rect.minX / spacing))
    while x <= rect.maxX {
        let isMajor = col % majorEvery == 0
        var path = Path()
        path.move(to: CGPoint(x: x, y: rect.minY))
        path.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.stroke(path,
                       with: .color(isMajor ? DrawingStyle.gridMajorColor : DrawingStyle.gridColor),
                       lineWidth: DrawingStyle.gridLineWidth)
        x += spacing
        col += 1
    }

    var y = (floor(rect.minY / spacing) * spacing)
    var row = Int(floor(rect.minY / spacing))
    while y <= rect.maxY {
        let isMajor = row % majorEvery == 0
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.stroke(path,
                       with: .color(isMajor ? DrawingStyle.gridMajorColor : DrawingStyle.gridColor),
                       lineWidth: DrawingStyle.gridLineWidth)
        y += spacing
        row += 1
    }
}

// MARK: - CGContext renderers (for PNG export)

/// Renders the full `DrawingDocument` into a `CGContext` for PNG export.
/// The export has a plain white background — no grid — so the result is clean
/// when used as a floorplan background image.
/// Call from inside a `UIGraphicsImageRenderer` block.
func renderDocument(_ doc: DrawingDocument,
                    in cgContext: CGContext,
                    canvasSize: CGFloat,
                    exteriorFillColorIndex: Int = -1,
                    visualStyle: DrawingVisualExportStyle = .standard,
                    drawText: Bool = true) {
    if visualStyle == .architecturalDark {
        renderDarkArchitecturalDocument(doc, in: cgContext, canvasSize: canvasSize, drawText: drawText)
        return
    }

    // White background only — no grid in the exported image
    cgContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    cgContext.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    if exteriorFillColorIndex >= 0 {
        drawExteriorFillCG(doc, context: cgContext, canvasSize: canvasSize, colorIndex: exteriorFillColorIndex)
    }

    // Room areas (behind walls and depth shadow)
    for area in doc.roomAreas {
        drawRoomAreaCG(area, context: cgContext, drawText: drawText)
    }

    // Furniture items (after room areas, before walls)
    for item in doc.furnitureItems {
        drawFurnitureItemCG(item, context: cgContext, drawText: drawText)
    }

    // Wall depth shadow: inner shadow on the interior side of perimeter walls,
    // drawn on top of room colors so it darkens the area near each wall.
    drawWallDepthShadowCG(doc, context: cgContext)
    if visualStyle == .architectural {
        drawWallCastShadowsCG(doc, context: cgContext)
    }

    // Walls — draw order: balcony first, interior, exterior last.
    // Exterior walls paint over any overlapping balcony/interior segments.
    let wallDrawOrder: [WallKind] = [.balcony, .interior, .exterior]
    for kind in wallDrawOrder {
        for wall in doc.walls where wall.kind == kind {
            drawWallCG(wall, context: cgContext)
        }
    }
    if visualStyle == .architectural {
        drawWallBevelsCG(doc, context: cgContext)
    }

    // Openings
    for opening in doc.openings {
        guard let wall = doc.wall(for: opening.wallID) else { continue }
        switch opening.kind {
        case .door:   drawDoorCG(opening, wall: wall, context: cgContext)
        case .window: drawWindowCG(opening, wall: wall, context: cgContext)
        }
    }

    if drawText {
        // Room labels
        for label in doc.roomLabels {
            drawRoomLabelCG(label, context: cgContext)
        }
    }
}

private enum DarkArchitecturalPalette {
    static let background = UIColor(red: 0.075, green: 0.095, blue: 0.120, alpha: 1)
    static let roomFill = UIColor(red: 0.115, green: 0.145, blue: 0.180, alpha: 0.92)
    static let roomAlternateFill = UIColor(red: 0.095, green: 0.125, blue: 0.160, alpha: 0.92)
    static let roomStroke = UIColor(red: 0.42, green: 0.50, blue: 0.58, alpha: 0.22)
    static let wallExterior = UIColor(red: 0.45, green: 0.53, blue: 0.62, alpha: 1)
    static let wallInterior = UIColor(red: 0.36, green: 0.43, blue: 0.51, alpha: 1)
    static let wallBalcony = UIColor(red: 0.35, green: 0.43, blue: 0.51, alpha: 0.82)
    static let openingLine = UIColor(red: 0.72, green: 0.78, blue: 0.84, alpha: 0.62)
    static let furnitureStroke = UIColor(red: 0.62, green: 0.69, blue: 0.76, alpha: 0.52)
    static let furnitureFill = UIColor(red: 0.10, green: 0.125, blue: 0.155, alpha: 0.62)
    static let text = UIColor(red: 0.78, green: 0.82, blue: 0.86, alpha: 0.72)
}

private func renderDarkArchitecturalDocument(_ doc: DrawingDocument,
                                             in context: CGContext,
                                             canvasSize: CGFloat,
                                             drawText: Bool = true) {
    context.setFillColor(DarkArchitecturalPalette.background.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))

    for (index, area) in doc.roomAreas.enumerated() {
        drawDarkRoomAreaCG(area, index: index, context: context, drawText: drawText)
    }

    drawDarkFurnitureShadowsCG(doc, context: context)

    for item in doc.furnitureItems {
        drawDarkFurnitureItemCG(item, context: context, drawText: drawText)
    }

    drawDarkWallShadowsCG(doc, context: context)

    let wallDrawOrder: [WallKind] = [.balcony, .interior, .exterior]
    for kind in wallDrawOrder {
        for wall in doc.walls where wall.kind == kind {
            drawDarkWallCG(wall, context: context)
        }
    }

    for opening in doc.openings {
        guard let wall = doc.wall(for: opening.wallID) else { continue }
        switch opening.kind {
        case .door:
            drawDarkDoorCG(opening, wall: wall, context: context)
        case .window:
            drawDarkWindowCG(opening, wall: wall, context: context)
        }
    }

    if drawText {
        for label in doc.roomLabels {
            drawDarkRoomLabelCG(label, context: context)
        }
    }
}

private func drawDarkRoomAreaCG(_ area: RoomArea, index: Int, context: CGContext, drawText: Bool = true) {
    let path = roomAreaPath(area)

    UIGraphicsPushContext(context)

    if let kind = area.floorKind {
        drawFloorPatternCG(kind, path: path, bounds: area.boundingRect, context: context, dark: true)
    } else {
        let fillColor = index.isMultiple(of: 2)
            ? DarkArchitecturalPalette.roomFill
            : DarkArchitecturalPalette.roomAlternateFill
        fillColor.setFill()
        path.fill()
    }

    DarkArchitecturalPalette.roomStroke.setStroke()
    path.lineWidth = 1
    path.stroke()

    if drawText {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: DarkArchitecturalPalette.text
        ]
        let nsString = area.name.uppercased() as NSString
        let textSize = nsString.size(withAttributes: attributes)
        let center = polygonCentroid(area.effectivePoints) ?? CGPoint(x: area.rect.midX, y: area.rect.midY)
        nsString.draw(at: CGPoint(x: center.x - textSize.width / 2,
                                  y: center.y - textSize.height / 2),
                      withAttributes: attributes)
    }
    UIGraphicsPopContext()
}

private func drawDarkFurnitureShadowsCG(_ doc: DrawingDocument, context: CGContext) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 4, height: 7),
                      blur: 9,
                      color: UIColor.black.withAlphaComponent(0.34).cgColor)
    context.setFillColor(UIColor.black.withAlphaComponent(0.12).cgColor)
    for item in doc.furnitureItems {
        let path = UIBezierPath(roundedRect: item.rect, cornerRadius: 3)
        context.addPath(path.cgPath)
        context.fillPath()
    }
    context.restoreGState()
}

private func drawDarkFurnitureItemCG(_ item: FurnitureItem, context: CGContext, drawText: Bool = true) {
    UIGraphicsPushContext(context)
    drawFurnitureBlueprintCG(
        item,
        context: context,
        fillColor: DarkArchitecturalPalette.furnitureFill,
        strokeColor: DarkArchitecturalPalette.furnitureStroke,
        detailColor: DarkArchitecturalPalette.text.withAlphaComponent(0.44)
    )

    if drawText, item.showsName {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: DarkArchitecturalPalette.text.withAlphaComponent(0.58)
        ]
        let nsString = item.name.uppercased() as NSString
        let textSize = nsString.size(withAttributes: attributes)
        nsString.draw(at: CGPoint(x: item.rect.midX - textSize.width / 2,
                                  y: item.rect.midY - textSize.height / 2),
                      withAttributes: attributes)
    }
    UIGraphicsPopContext()
}

private func drawDarkWallShadowsCG(_ doc: DrawingDocument, context: CGContext) {
    context.saveGState()
    context.setLineCap(.square)
    context.setLineDash(phase: 0, lengths: [])

    for wall in doc.walls where wall.kind != .balcony {
        let width = DrawingDocument.wallWidth(for: wall.kind)
        context.saveGState()
        context.setShadow(offset: CGSize(width: width * 0.26, height: width * 0.30),
                          blur: wall.kind == .exterior ? 10 : 6,
                          color: UIColor.black.withAlphaComponent(wall.kind == .exterior ? 0.52 : 0.34).cgColor)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.10).cgColor)
        context.setLineWidth(width)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()
        context.restoreGState()
    }

    context.restoreGState()
}

private func drawDarkWallCG(_ wall: WallSegment, context: CGContext) {
    let width = DrawingDocument.wallWidth(for: wall.kind)
    context.setLineDash(phase: 0, lengths: [])
    context.setLineCap(.square)

    if wall.kind == .balcony {
        context.setStrokeColor(DarkArchitecturalPalette.wallBalcony.cgColor)
        context.setLineWidth(width)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()

        context.setStrokeColor(DarkArchitecturalPalette.background.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(width * 0.48)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()
        return
    }

    context.setStrokeColor((wall.kind == .exterior
                            ? DarkArchitecturalPalette.wallExterior
                            : DarkArchitecturalPalette.wallInterior).cgColor)
    context.setLineWidth(width)
    context.move(to: wall.start)
    context.addLine(to: wall.end)
    context.strokePath()

    drawDarkWallHighlightCG(wall, context: context)
}

private func drawDarkWallHighlightCG(_ wall: WallSegment, context: CGContext) {
    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let length = hypot(dx, dy)
    guard length > 0 else { return }

    let width = DrawingDocument.wallWidth(for: wall.kind)
    let unitX = dx / length
    let unitY = dy / length
    let normal = CGPoint(x: -unitY, y: unitX)
    let lightVector = CGPoint(x: -0.65, y: -0.76)
    let litNormal = normal.x * lightVector.x + normal.y * lightVector.y >= 0
        ? normal
        : CGPoint(x: -normal.x, y: -normal.y)
    let edgeOffset = width * 0.34
    let inset = width * 0.16
    let start = CGPoint(x: wall.start.x + unitX * inset, y: wall.start.y + unitY * inset)
    let end = CGPoint(x: wall.end.x - unitX * inset, y: wall.end.y - unitY * inset)

    context.setLineCap(.butt)
    context.setLineWidth(max(1, width * 0.08))
    context.setStrokeColor(UIColor.white.withAlphaComponent(wall.kind == .exterior ? 0.24 : 0.16).cgColor)
    context.move(to: CGPoint(x: start.x + litNormal.x * edgeOffset,
                             y: start.y + litNormal.y * edgeOffset))
    context.addLine(to: CGPoint(x: end.x + litNormal.x * edgeOffset,
                                y: end.y + litNormal.y * edgeOffset))
    context.strokePath()
}

private func drawDarkDoorCG(_ opening: PlacedOpening, wall: WallSegment, context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len
    let uy = dy / len
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip
    let ny = ux * flip

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBandCG(from: eps.start,
                to: eps.end,
                halfWidth: wallW / 2 + 1,
                fillColor: DarkArchitecturalPalette.roomFill.cgColor,
                context: context)

    context.setStrokeColor(DarkArchitecturalPalette.openingLine.cgColor)
    context.setLineWidth(1.8)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [4, 3])

    context.addArc(center: eps.start,
                   radius: opening.width,
                   startAngle: atan2(uy, ux),
                   endAngle: atan2(ny, nx),
                   clockwise: opening.flipSide)
    context.strokePath()

    context.setLineDash(phase: 0, lengths: [])
    context.move(to: eps.start)
    context.addLine(to: eps.end)
    context.strokePath()
}

private func drawDarkWindowCG(_ opening: PlacedOpening, wall: WallSegment, context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len
    let ny = dx / len

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBandCG(from: eps.start,
                to: eps.end,
                halfWidth: wallW / 2 + 1,
                fillColor: DarkArchitecturalPalette.roomFill.cgColor,
                context: context)

    context.setStrokeColor(DarkArchitecturalPalette.openingLine.cgColor)
    context.setLineCap(.round)
    let paneHalf = wallW * 0.62
    for sign: CGFloat in [-1, 1] {
        context.setLineWidth(1.6)
        let ox = nx * paneHalf * sign
        let oy = ny * paneHalf * sign
        context.move(to: CGPoint(x: eps.start.x + ox, y: eps.start.y + oy))
        context.addLine(to: CGPoint(x: eps.end.x + ox, y: eps.end.y + oy))
        context.strokePath()
    }
    context.setLineWidth(2.4)
    context.move(to: eps.start)
    context.addLine(to: eps.end)
    context.strokePath()
}

private func drawDarkRoomLabelCG(_ label: RoomLabel, context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: DarkArchitecturalPalette.text
    ]
    let nsString = label.name.uppercased() as NSString
    let textSize = nsString.size(withAttributes: attributes)

    UIGraphicsPushContext(context)
    nsString.draw(at: CGPoint(x: label.position.x - textSize.width / 2,
                              y: label.position.y - textSize.height / 2),
                  withAttributes: attributes)
    UIGraphicsPopContext()
}

private func roomAreaPath(_ area: RoomArea) -> UIBezierPath {
    let points = area.effectivePoints
    guard points.count >= 3 else {
        return UIBezierPath(roundedRect: area.rect, cornerRadius: 4)
    }

    let path = UIBezierPath()
    path.move(to: points[0])
    for point in points.dropFirst() {
        path.addLine(to: point)
    }
    path.close()
    return path
}

private func polygonCentroid(_ points: [CGPoint]) -> CGPoint? {
    guard points.count >= 3 else { return nil }

    var signedArea: CGFloat = 0
    var centroidX: CGFloat = 0
    var centroidY: CGFloat = 0

    for index in points.indices {
        let current = points[index]
        let next = points[(index + 1) % points.count]
        let cross = current.x * next.y - next.x * current.y
        signedArea += cross
        centroidX += (current.x + next.x) * cross
        centroidY += (current.y + next.y) * cross
    }

    signedArea *= 0.5
    guard abs(signedArea) > 0.001 else { return nil }

    return CGPoint(x: centroidX / (6 * signedArea),
                   y: centroidY / (6 * signedArea))
}

// MARK: - Floor pattern (CG)

private func drawFloorPatternCG(_ kind: FloorKind,
                                 path: UIBezierPath,
                                 bounds: CGRect,
                                 context: CGContext,
                                 dark: Bool = false) {
    // Caller must have already called UIGraphicsPushContext.
    // saveGState/restoreGState isolates the clip region.
    context.saveGState()
    context.addPath(path.cgPath)
    context.clip()

    switch kind {
    case .legno:
        UIColor(red: dark ? 0.55 : 0.85,
                green: dark ? 0.40 : 0.72,
                blue:  dark ? 0.22 : 0.52,
                alpha: dark ? 0.45 : 0.28).setFill()
        path.fill()
        UIColor(red: 0.58, green: 0.40, blue: 0.22,
                alpha: dark ? 0.30 : 0.22).setStroke()
        var y = (bounds.minY / 12).rounded(.down) * 12
        while y <= bounds.maxY {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: bounds.minX, y: y))
            line.addLine(to: CGPoint(x: bounds.maxX, y: y))
            line.lineWidth = 0.8
            line.stroke()
            y += 12
        }

    case .piastrelle:
        UIColor(red: 0.93, green: 0.91, blue: 0.87,
                alpha: dark ? 0.30 : 0.40).setFill()
        path.fill()
        drawFloorGridCG(bounds: bounds, spacing: 30,
                        color: dark ? UIColor.white.withAlphaComponent(0.18)
                                    : UIColor.gray.withAlphaComponent(0.28))

    case .gres:
        UIColor(red: 0.87, green: 0.85, blue: 0.80,
                alpha: dark ? 0.28 : 0.38).setFill()
        path.fill()
        drawFloorGridCG(bounds: bounds, spacing: 60,
                        color: dark ? UIColor.white.withAlphaComponent(0.20)
                                    : UIColor.gray.withAlphaComponent(0.32))

    case .marmo:
        UIColor(red: 0.96, green: 0.95, blue: 0.92,
                alpha: dark ? 0.30 : 0.45).setFill()
        path.fill()
        UIColor(red: 0.68, green: 0.65, blue: 0.62,
                alpha: dark ? 0.22 : 0.18).setStroke()
        let diag = max(bounds.width, bounds.height) * 2
        var offset: CGFloat = -diag
        while offset <= diag {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: bounds.midX + offset - diag, y: bounds.midY - diag))
            line.addLine(to: CGPoint(x: bounds.midX + offset + diag, y: bounds.midY + diag))
            line.lineWidth = 0.7
            line.stroke()
            offset += 40
        }

    case .cemento:
        UIColor(red: 0.70, green: 0.69, blue: 0.67,
                alpha: dark ? 0.45 : 0.32).setFill()
        path.fill()
    }

    context.restoreGState()
}

private func drawFloorGridCG(bounds: CGRect, spacing: CGFloat, color: UIColor) {
    color.setStroke()
    var x = (bounds.minX / spacing).rounded(.down) * spacing
    while x <= bounds.maxX {
        let line = UIBezierPath()
        line.move(to: CGPoint(x: x, y: bounds.minY))
        line.addLine(to: CGPoint(x: x, y: bounds.maxY))
        line.lineWidth = 0.8
        line.stroke()
        x += spacing
    }
    var y = (bounds.minY / spacing).rounded(.down) * spacing
    while y <= bounds.maxY {
        let line = UIBezierPath()
        line.move(to: CGPoint(x: bounds.minX, y: y))
        line.addLine(to: CGPoint(x: bounds.maxX, y: y))
        line.lineWidth = 0.8
        line.stroke()
        y += spacing
    }
}

private func drawRoomAreaCG(_ area: RoomArea, context: CGContext, drawText: Bool = true) {
    let cgColor  = RoomLabelPalette.color(at: area.colorIndex)
    let areaPath = roomAreaPath(area)

    UIGraphicsPushContext(context)

    if let kind = area.floorKind {
        drawFloorPatternCG(kind, path: areaPath, bounds: area.boundingRect, context: context, dark: false)
    } else if let fillColor = cgColor.copy(alpha: 0.12) {
        context.setFillColor(fillColor)
        UIBezierPath(roundedRect: area.rect, cornerRadius: 8).fill()
    }

    if drawText {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: UIColor(cgColor: cgColor.copy(alpha: 0.55) ?? cgColor)
        ]
        let nsString = area.name.uppercased() as NSString
        let textSize = nsString.size(withAttributes: attributes)
        let center = polygonCentroid(area.effectivePoints)
            ?? CGPoint(x: area.rect.midX, y: area.rect.midY)
        nsString.draw(at: CGPoint(x: center.x - textSize.width / 2,
                                   y: center.y - textSize.height / 2),
                      withAttributes: attributes)
    }
    UIGraphicsPopContext()
}

private func drawFurnitureItemCG(_ item: FurnitureItem, context: CGContext, drawText: Bool = true) {
    UIGraphicsPushContext(context)
    drawFurnitureBlueprintCG(
        item,
        context: context,
        fillColor: UIColor(white: 0.92, alpha: 1),
        strokeColor: UIColor(white: 0.55, alpha: 1),
        detailColor: UIColor(white: 0.35, alpha: 0.46)
    )

    if drawText, item.showsName {
        // Name label centered in rect
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor(white: 0.35, alpha: 1)
        ]
        let nsString = item.name as NSString
        let textSize = nsString.size(withAttributes: attributes)
        let drawPoint = CGPoint(
            x: item.rect.midX - textSize.width / 2,
            y: item.rect.midY - textSize.height / 2
        )
        nsString.draw(at: drawPoint, withAttributes: attributes)
    }

    UIGraphicsPopContext()
}

private func drawFurnitureBlueprintCG(_ item: FurnitureItem,
                                      context: CGContext,
                                      fillColor: UIColor,
                                      strokeColor: UIColor,
                                      detailColor: UIColor) {
    let rect = item.rect
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: CGFloat(item.rotationDegrees * .pi / 180))
    context.translateBy(x: -rect.midX, y: -rect.midY)
    defer { context.restoreGState() }

    func rounded(_ r: CGRect, radius: CGFloat = 5) -> UIBezierPath {
        UIBezierPath(roundedRect: r, cornerRadius: min(radius, min(r.width, r.height) / 2))
    }

    func fillStroke(_ path: UIBezierPath) {
        fillColor.setFill()
        path.fill()
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func line(_ a: CGPoint, _ b: CGPoint, color: UIColor = detailColor) {
        color.setStroke()
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        path.lineWidth = 1
        path.lineCapStyle = .round
        path.stroke()
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
        let structuralFill = strokeColor.withAlphaComponent(0.20)
        let cushionStroke = strokeColor.withAlphaComponent(0.58)

        func fillStrokeCustom(_ path: UIBezierPath, fill: UIColor, stroke: UIColor) {
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let back = CGRect(x: frame.minX + armWidth * 0.20, y: frame.minY, width: frame.width - armWidth * 0.40, height: backHeight)
        let leftArm = CGRect(x: frame.minX, y: frame.minY + backHeight * 0.30, width: armWidth, height: frame.height - backHeight * 0.55)
        let rightArm = CGRect(x: frame.maxX - armWidth, y: leftArm.minY, width: armWidth, height: leftArm.height)
        fillStrokeCustom(rounded(back, radius: 6), fill: structuralFill, stroke: cushionStroke)
        fillStrokeCustom(rounded(leftArm, radius: 8), fill: structuralFill, stroke: cushionStroke)
        fillStrokeCustom(rounded(rightArm, radius: 8), fill: structuralFill, stroke: cushionStroke)

        let pillowY = frame.minY + backHeight * 0.72
        let pillowW = innerW / 2
        let leftPillow = CGRect(x: innerX, y: pillowY, width: pillowW, height: pillowHeight)
        let rightPillow = CGRect(x: innerX + pillowW, y: pillowY, width: pillowW, height: pillowHeight)
        fillStroke(rounded(leftPillow, radius: 7))
        fillStroke(rounded(rightPillow, radius: 7))

        let leftSeat = CGRect(x: innerX, y: seatY, width: pillowW, height: seatHeight)
        let rightSeat = CGRect(x: innerX + pillowW, y: seatY, width: pillowW, height: seatHeight)
        fillStroke(rounded(leftSeat, radius: 6))
        fillStroke(rounded(rightSeat, radius: 6))
        line(CGPoint(x: innerX + pillowW, y: pillowY), CGPoint(x: innerX + pillowW, y: frame.maxY))
        strokeColor.withAlphaComponent(0.42).setStroke()
        let framePath = rounded(frame, radius: 10)
        framePath.lineWidth = 1
        framePath.stroke()

    case .armchair:
        let frame = rect.insetBy(dx: rect.width * 0.11, dy: rect.height * 0.10)
        let armWidth = frame.width * 0.22
        let backHeight = frame.height * 0.20
        let pillowHeight = frame.height * 0.26
        let seatY = frame.minY + backHeight + pillowHeight * 0.58
        let seatHeight = frame.maxY - seatY
        let innerX = frame.minX + armWidth
        let innerW = frame.width - armWidth * 2
        let structuralFill = strokeColor.withAlphaComponent(0.20)
        let cushionStroke = strokeColor.withAlphaComponent(0.58)

        func fillStrokeCustom(_ path: UIBezierPath, fill: UIColor, stroke: UIColor) {
            fill.setFill()
            path.fill()
            stroke.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        let back = CGRect(x: frame.minX + armWidth * 0.18, y: frame.minY, width: frame.width - armWidth * 0.36, height: backHeight)
        let leftArm = CGRect(x: frame.minX, y: frame.minY + backHeight * 0.30, width: armWidth, height: frame.height - backHeight * 0.55)
        let rightArm = CGRect(x: frame.maxX - armWidth, y: leftArm.minY, width: armWidth, height: leftArm.height)
        fillStrokeCustom(rounded(back, radius: 6), fill: structuralFill, stroke: cushionStroke)
        fillStrokeCustom(rounded(leftArm, radius: 8), fill: structuralFill, stroke: cushionStroke)
        fillStrokeCustom(rounded(rightArm, radius: 8), fill: structuralFill, stroke: cushionStroke)

        let pillow = CGRect(x: innerX, y: frame.minY + backHeight * 0.72, width: innerW, height: pillowHeight)
        let seat = CGRect(x: innerX, y: seatY, width: innerW, height: seatHeight)
        fillStroke(rounded(pillow, radius: 7))
        fillStroke(rounded(seat, radius: 6))
        line(CGPoint(x: innerX, y: seatY), CGPoint(x: innerX + innerW, y: seatY))
        strokeColor.withAlphaComponent(0.42).setStroke()
        let framePath = rounded(frame, radius: 10)
        framePath.lineWidth = 1
        framePath.stroke()

    case .diningTable:
        let table = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.14)
        fillStroke(UIBezierPath(ovalIn: table))
        line(CGPoint(x: table.minX + table.width * 0.22, y: table.midY), CGPoint(x: table.maxX - table.width * 0.22, y: table.midY))
        line(CGPoint(x: table.midX, y: table.minY + table.height * 0.22), CGPoint(x: table.midX, y: table.maxY - table.height * 0.22))

    case .chair:
        let seat = CGRect(x: rect.minX + rect.width * 0.23, y: rect.minY + rect.height * 0.34, width: rect.width * 0.54, height: rect.height * 0.42)
        let back = CGRect(x: seat.minX - rect.width * 0.03, y: rect.minY + rect.height * 0.15, width: seat.width + rect.width * 0.06, height: rect.height * 0.16)
        fillStroke(rounded(seat, radius: 4))
        strokeColor.withAlphaComponent(0.22).setFill()
        rounded(back, radius: 3).fill()
        strokeColor.setStroke()
        let backPath = rounded(back, radius: 3)
        backPath.lineWidth = 1
        backPath.stroke()
        line(CGPoint(x: back.minX + back.width * 0.14, y: back.maxY), CGPoint(x: seat.minX + seat.width * 0.18, y: seat.minY))
        line(CGPoint(x: back.maxX - back.width * 0.14, y: back.maxY), CGPoint(x: seat.maxX - seat.width * 0.18, y: seat.minY))
        line(CGPoint(x: seat.minX + 3, y: seat.maxY), CGPoint(x: seat.minX - rect.width * 0.08, y: rect.maxY - rect.height * 0.10), color: strokeColor.withAlphaComponent(0.65))
        line(CGPoint(x: seat.maxX - 3, y: seat.maxY), CGPoint(x: seat.maxX + rect.width * 0.08, y: rect.maxY - rect.height * 0.10), color: strokeColor.withAlphaComponent(0.65))

    case .bed:
        let body = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.06)
        fillStroke(rounded(body, radius: 7))
        fillStroke(rounded(CGRect(x: body.minX + body.width * 0.08, y: body.minY + body.height * 0.07, width: body.width * 0.36, height: body.height * 0.22), radius: 4))
        fillStroke(rounded(CGRect(x: body.maxX - body.width * 0.44, y: body.minY + body.height * 0.07, width: body.width * 0.36, height: body.height * 0.22), radius: 4))
        line(CGPoint(x: body.minX, y: body.minY + body.height * 0.36), CGPoint(x: body.maxX, y: body.minY + body.height * 0.36))

    case .wardrobe:
        let body = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.10)
        fillStroke(rounded(body, radius: 4))
        line(CGPoint(x: body.midX, y: body.minY), CGPoint(x: body.midX, y: body.maxY))
        detailColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: body.midX - 6, y: body.midY - 2, width: 4, height: 4)).fill()
        UIBezierPath(ovalIn: CGRect(x: body.midX + 2, y: body.midY - 2, width: 4, height: 4)).fill()

    case .toilet:
        let tank = CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.12, width: rect.width * 0.56, height: rect.height * 0.24)
        let bowl = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.34, width: rect.width * 0.64, height: rect.height * 0.46)
        fillStroke(rounded(tank, radius: 3))
        fillStroke(UIBezierPath(ovalIn: bowl))
        detailColor.setStroke()
        UIBezierPath(ovalIn: bowl.insetBy(dx: bowl.width * 0.23, dy: bowl.height * 0.22)).stroke()

    case .sink:
        let basin = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.18)
        fillStroke(UIBezierPath(ovalIn: basin))
        detailColor.setStroke()
        UIBezierPath(ovalIn: basin.insetBy(dx: basin.width * 0.22, dy: basin.height * 0.22)).stroke()
        line(CGPoint(x: rect.midX, y: basin.minY), CGPoint(x: rect.midX, y: basin.minY - rect.height * 0.12), color: strokeColor)

    case .inductionCooktop:
        let cooktop = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.10)
        fillStroke(rounded(cooktop, radius: 5))

        let zoneRadius = min(cooktop.width, cooktop.height) * 0.15
        let zoneCenters = [
            CGPoint(x: cooktop.minX + cooktop.width * 0.30, y: cooktop.minY + cooktop.height * 0.34),
            CGPoint(x: cooktop.maxX - cooktop.width * 0.30, y: cooktop.minY + cooktop.height * 0.34),
            CGPoint(x: cooktop.minX + cooktop.width * 0.30, y: cooktop.maxY - cooktop.height * 0.34),
            CGPoint(x: cooktop.maxX - cooktop.width * 0.30, y: cooktop.maxY - cooktop.height * 0.34)
        ]
        detailColor.setStroke()
        for center in zoneCenters {
            let zone = CGRect(x: center.x - zoneRadius, y: center.y - zoneRadius, width: zoneRadius * 2, height: zoneRadius * 2)
            let zonePath = UIBezierPath(ovalIn: zone)
            zonePath.lineWidth = 1
            zonePath.stroke()
            let innerPath = UIBezierPath(ovalIn: zone.insetBy(dx: zoneRadius * 0.38, dy: zoneRadius * 0.38))
            innerPath.lineWidth = 1
            innerPath.stroke()
        }
        line(
            CGPoint(x: cooktop.midX - cooktop.width * 0.18, y: cooktop.maxY - cooktop.height * 0.12),
            CGPoint(x: cooktop.midX + cooktop.width * 0.18, y: cooktop.maxY - cooktop.height * 0.12)
        )

    case .washingMachine:
        let body = rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.08)
        let panel = CGRect(x: body.minX, y: body.minY, width: body.width, height: body.height * 0.22)
        let doorRadius = min(body.width, body.height) * 0.24
        let doorCenter = CGPoint(x: body.midX, y: body.minY + body.height * 0.58)
        let door = CGRect(x: doorCenter.x - doorRadius, y: doorCenter.y - doorRadius, width: doorRadius * 2, height: doorRadius * 2)

        fillStroke(rounded(body, radius: 6))
        detailColor.setStroke()
        let panelPath = rounded(panel, radius: 3)
        panelPath.lineWidth = 1
        panelPath.stroke()
        strokeColor.setStroke()
        let doorPath = UIBezierPath(ovalIn: door)
        doorPath.lineWidth = 1
        doorPath.stroke()
        detailColor.setStroke()
        let innerDoor = UIBezierPath(ovalIn: door.insetBy(dx: doorRadius * 0.28, dy: doorRadius * 0.28))
        innerDoor.lineWidth = 1
        innerDoor.stroke()
        detailColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: panel.maxX - panel.width * 0.20, y: panel.midY - 3, width: 6, height: 6)).fill()
        line(CGPoint(x: panel.minX + panel.width * 0.12, y: panel.midY), CGPoint(x: panel.minX + panel.width * 0.34, y: panel.midY))

    case .bathtub:
        let tub = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.18)
        fillStroke(rounded(tub, radius: tub.height / 2))
        detailColor.setStroke()
        rounded(tub.insetBy(dx: tub.width * 0.10, dy: tub.height * 0.20), radius: tub.height / 3).stroke()
        line(CGPoint(x: tub.minX + tub.width * 0.12, y: tub.minY), CGPoint(x: tub.minX + tub.width * 0.12, y: tub.minY - rect.height * 0.10), color: strokeColor)

    case .shower:
        let base = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
        fillStroke(rounded(base, radius: 4))
        line(CGPoint(x: base.minX, y: base.minY), CGPoint(x: base.maxX, y: base.maxY))
        line(CGPoint(x: base.maxX, y: base.minY), CGPoint(x: base.minX, y: base.maxY))
        detailColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: base.midX - 4, y: base.midY - 4, width: 8, height: 8)).fill()

    case .generic:
        fillStroke(rounded(rect, radius: 4))
    }
}

private func drawGridCG(in rect: CGRect, spacing: CGFloat, context: CGContext) {
    context.setLineWidth(0.5)
    let majorEvery: Int = 5
    var x = (floor(rect.minX / spacing) * spacing)
    var col = Int(floor(rect.minX / spacing))
    while x <= rect.maxX {
        let isMajor = col % majorEvery == 0
        context.setStrokeColor(isMajor ? CGColor(gray: 0.78, alpha: 1) : CGColor(gray: 0.88, alpha: 1))
        context.move(to: CGPoint(x: x, y: rect.minY))
        context.addLine(to: CGPoint(x: x, y: rect.maxY))
        context.strokePath()
        x += spacing; col += 1
    }
    var y = (floor(rect.minY / spacing) * spacing)
    var row = Int(floor(rect.minY / spacing))
    while y <= rect.maxY {
        let isMajor = row % majorEvery == 0
        context.setStrokeColor(isMajor ? CGColor(gray: 0.78, alpha: 1) : CGColor(gray: 0.88, alpha: 1))
        context.move(to: CGPoint(x: rect.minX, y: y))
        context.addLine(to: CGPoint(x: rect.maxX, y: y))
        context.strokePath()
        y += spacing; row += 1
    }
}

private func drawWallCG(_ wall: WallSegment, context: CGContext) {
    let w = DrawingDocument.wallWidth(for: wall.kind)
    context.setLineDash(phase: 0, lengths: [])
    context.setLineCap(.square)

    if wall.kind == .balcony {
        // Outer dark stroke (same width as exterior walls)
        context.setStrokeColor(DrawingStyle.wallCGColor)
        context.setLineWidth(w)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()
        // Inner white stroke — creates the hollow / double-line look
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(w * 0.45)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()
    } else {
        context.setStrokeColor(DrawingStyle.wallCGColor)
        context.setLineWidth(w)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()
    }
}

private func drawWallCastShadowsCG(_ doc: DrawingDocument, context: CGContext) {
    context.saveGState()
    context.setLineCap(.square)
    context.setLineJoin(.bevel)
    context.setLineDash(phase: 0, lengths: [])

    for wall in doc.walls where wall.kind != .balcony {
        let width = DrawingDocument.wallWidth(for: wall.kind)
        let alpha: CGFloat = wall.kind == .exterior ? 0.16 : 0.10
        let blur: CGFloat = wall.kind == .exterior ? 5.5 : 3.5
        let offset = CGSize(width: width * 0.16, height: width * 0.20)

        context.saveGState()
        context.setShadow(offset: offset,
                          blur: blur,
                          color: UIColor.black.withAlphaComponent(alpha).cgColor)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.03).cgColor)
        context.setLineWidth(width)
        context.move(to: wall.start)
        context.addLine(to: wall.end)
        context.strokePath()
        context.restoreGState()
    }

    context.restoreGState()
}

private func drawWallBevelsCG(_ doc: DrawingDocument, context: CGContext) {
    for wall in doc.walls where wall.kind != .balcony {
        drawWallBevelCG(wall, context: context)
    }
}

private func drawWallBevelCG(_ wall: WallSegment, context: CGContext) {
    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let length = hypot(dx, dy)
    guard length > 0 else { return }

    let width = DrawingDocument.wallWidth(for: wall.kind)
    let unitX = dx / length
    let unitY = dy / length
    let normal = CGPoint(x: -unitY, y: unitX)
    let lightVector = CGPoint(x: -0.65, y: -0.76)
    let firstSideLit = normal.x * lightVector.x + normal.y * lightVector.y >= 0
    let litNormal = firstSideLit ? normal : CGPoint(x: -normal.x, y: -normal.y)
    let shadedNormal = CGPoint(x: -litNormal.x, y: -litNormal.y)

    let edgeOffset = width * 0.39
    let lineWidth = max(1.0, width * 0.10)
    let inset = width * 0.18
    let start = CGPoint(x: wall.start.x + unitX * inset, y: wall.start.y + unitY * inset)
    let end = CGPoint(x: wall.end.x - unitX * inset, y: wall.end.y - unitY * inset)

    context.saveGState()
    context.setLineCap(.butt)
    context.setLineDash(phase: 0, lengths: [])
    context.setLineWidth(lineWidth)

    context.setStrokeColor(UIColor.white.withAlphaComponent(wall.kind == .exterior ? 0.34 : 0.26).cgColor)
    context.move(to: CGPoint(x: start.x + litNormal.x * edgeOffset,
                             y: start.y + litNormal.y * edgeOffset))
    context.addLine(to: CGPoint(x: end.x + litNormal.x * edgeOffset,
                                y: end.y + litNormal.y * edgeOffset))
    context.strokePath()

    context.setStrokeColor(UIColor.black.withAlphaComponent(wall.kind == .exterior ? 0.30 : 0.20).cgColor)
    context.move(to: CGPoint(x: start.x + shadedNormal.x * edgeOffset,
                             y: start.y + shadedNormal.y * edgeOffset))
    context.addLine(to: CGPoint(x: end.x + shadedNormal.x * edgeOffset,
                                y: end.y + shadedNormal.y * edgeOffset))
    context.strokePath()
    context.restoreGState()
}

private func drawDoorCG(_ opening: PlacedOpening, wall: WallSegment, context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip, ny = ux * flip

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBandCG(from: eps.start, to: eps.end, halfWidth: wallW / 2 + 1, context: context)

    context.setStrokeColor(DrawingStyle.doorCGColor)
    context.setLineWidth(DrawingStyle.doorLineWidth)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [4, 3])

    let leafAngle = atan2(uy, ux)
    let openAngle = atan2(ny, nx)
    context.addArc(center: eps.start,
                   radius: opening.width,
                   startAngle: leafAngle,
                   endAngle: openAngle,
                   clockwise: opening.flipSide)
    context.strokePath()

    context.setLineDash(phase: 0, lengths: [])
    context.move(to: eps.start)
    context.addLine(to: eps.end)
    context.strokePath()
    _ = (ux, nx)  // suppress unused warnings
}

private func drawWindowCG(_ opening: PlacedOpening, wall: WallSegment, context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len, ny = dx / len

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBandCG(from: eps.start, to: eps.end, halfWidth: wallW / 2 + 1, context: context)

    context.setStrokeColor(DrawingStyle.windowCGColor)
    context.setLineCap(.round)

    let paneHalf: CGFloat = wallW * 0.7
    for sign: CGFloat in [-1, 1] {
        context.setLineWidth(DrawingStyle.windowLineWidth)
        let ox = nx * paneHalf * sign
        let oy = ny * paneHalf * sign
        context.move(to: CGPoint(x: eps.start.x + ox, y: eps.start.y + oy))
        context.addLine(to: CGPoint(x: eps.end.x + ox, y: eps.end.y + oy))
        context.strokePath()
    }
    context.setLineWidth(DrawingStyle.windowLineWidth * 2)
    context.move(to: eps.start)
    context.addLine(to: eps.end)
    context.strokePath()
}

private func drawRoomLabelCG(_ label: RoomLabel, context: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 13, weight: .bold),
        .foregroundColor: UIColor.white
    ]
    let nsString = label.name.uppercased() as NSString
    let textSize = nsString.size(withAttributes: attributes)

    // Pill geometry (mirrors DrawingCanvasContent)
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
    let radius = pillH / 2

    // Draw pill background
    let badgeColor = RoomLabelPalette.color(at: label.colorIndex)
    context.setFillColor(badgeColor)
    let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: radius)
    UIGraphicsPushContext(context)
    pillPath.fill()

    // Draw text centered
    let drawPoint = CGPoint(
        x: label.position.x - textSize.width / 2,
        y: label.position.y - textSize.height / 2
    )
    nsString.draw(at: drawPoint, withAttributes: attributes)
    UIGraphicsPopContext()
}

// MARK: - Wall depth shadow helpers (PNG export only)

/// Fills the area outside the building footprint with a soft tint.
/// Even-odd clipping makes the footprint a transparent hole so only the exterior gets colored.
private func drawExteriorFillCG(_ doc: DrawingDocument, context: CGContext, canvasSize: CGFloat, colorIndex: Int) {
    guard let palette = ExteriorFillPalette(rawValue: colorIndex) else { return }
    let footprint = buildFootprintPath(for: doc)
    guard footprint.bounds.width > 0 else { return }
    context.saveGState()
    let canvasPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    canvasPath.append(footprint)
    context.addPath(canvasPath.cgPath)
    context.clip(using: .evenOdd)
    context.setFillColor(palette.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
    context.restoreGState()
}

/// Builds a `UIBezierPath` from all room areas in the document.
/// Falls back to the wall bounding box when no room areas exist.
/// `effectivePoints` handles both rect-only and polygon rooms.
private func buildFootprintPath(for doc: DrawingDocument) -> UIBezierPath {
    let path = UIBezierPath()

    if !doc.roomAreas.isEmpty {
        for area in doc.roomAreas {
            let pts = area.effectivePoints
            guard pts.count >= 3 else { continue }
            path.move(to: pts[0])
            for pt in pts.dropFirst() { path.addLine(to: pt) }
            path.close()
        }
    } else {
        // Fallback: bounding box of all wall endpoints
        let allPts = doc.walls.flatMap { [$0.start, $0.end] }
        guard !allPts.isEmpty else { return path }
        let minX = allPts.map(\.x).min()!
        let maxX = allPts.map(\.x).max()!
        let minY = allPts.map(\.y).min()!
        let maxY = allPts.map(\.y).max()!
        path.append(UIBezierPath(rect: CGRect(x: minX, y: minY,
                                              width: maxX - minX,
                                              height: maxY - minY)))
    }

    // Non-zero winding: adjacent rooms merge into a single solid shape.
    path.usesEvenOddFillRule = false
    return path
}

/// Renders an inner shadow on the interior side of the building perimeter.
///
/// Technique — "big rect with hole":
///   1. Clip to the footprint so nothing draws outside the building.
///   2. Fill a huge rect that has the footprint as an even-odd hole.
///   3. The shadow of the hole edges bleeds inward from ALL sides equally,
///      darkening the area near every perimeter wall while leaving the
///      room centres bright.
///
/// Zero offset → shadow spreads uniformly inward (no directional bias).
/// Parameters scale with the footprint so depth is proportional to building size.
private func drawWallDepthShadowCG(_ doc: DrawingDocument, context: CGContext) {
    let footprint = buildFootprintPath(for: doc)
    let bounds = footprint.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }

    let ref  = min(bounds.width, bounds.height)
    // With a single bbox hole the blur must reach rooms that sit away from the edge.
    // Two-pass: a sharp near-wall layer + a soft ambient layer.
    let blurTight   = max(10, ref * 0.05)
    let blurAmbient = max(20, ref * 0.10)

    context.saveGState()
    // Clip uses non-zero winding → correctly unions all room areas (including overlaps).
    context.addPath(footprint.cgPath)
    context.clip()

    // Shadow source: big rect with a single rectangular hole (the footprint bbox).
    // Using the bbox instead of individual room subpaths avoids spurious shadow at
    // internal room boundaries where rooms touch or overlap.
    // The clip above already constrains the shadow to the real building shape.
    let expand: CGFloat = 2000
    let bigRect = UIBezierPath(rect: CGRect(
        x: bounds.minX - expand, y: bounds.minY - expand,
        width: bounds.width + expand * 2, height: bounds.height + expand * 2
    ))
    bigRect.append(UIBezierPath(rect: bounds))   // single clean rectangular hole
    bigRect.usesEvenOddFillRule = true

    UIGraphicsPushContext(context)

    // Pass 1 — sharp layer: strong, tight shadow right at the wall edge
    context.saveGState()
    context.setShadow(offset: .zero, blur: blurTight,
                      color: UIColor.black.withAlphaComponent(0.88).cgColor)
    UIColor.black.setFill()
    bigRect.fill()
    context.restoreGState()

    // Pass 2 — ambient layer: softer, wider depth gradient
    context.saveGState()
    context.setShadow(offset: .zero, blur: blurAmbient,
                      color: UIColor.black.withAlphaComponent(0.55).cgColor)
    UIColor.black.setFill()
    bigRect.fill()
    context.restoreGState()

    UIGraphicsPopContext()
    context.restoreGState()
}

// MARK: - Shared helpers

/// Returns (start, end) canvas points for a `PlacedOpening` on `wall`.
private func endpointsOf(opening: PlacedOpening, wall: WallSegment) -> (start: CGPoint, end: CGPoint)? {
    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return nil }
    let ux = dx / len, uy = dy / len
    let mid = CGPoint(x: wall.start.x + opening.t * dx,
                      y: wall.start.y + opening.t * dy)
    let half = opening.width / 2
    return (
        start: CGPoint(x: mid.x - ux * half, y: mid.y - uy * half),
        end:   CGPoint(x: mid.x + ux * half, y: mid.y + uy * half)
    )
}

/// Draws a white filled rectangle over the wall gap where an opening sits (SwiftUI).
private func eraseBand(from p1: CGPoint, to p2: CGPoint,
                        halfWidth: CGFloat,
                        context: inout GraphicsContext) {
    let dx = p2.x - p1.x, dy = p2.y - p1.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len * halfWidth, ny = dx / len * halfWidth

    var path = Path()
    path.move(to: CGPoint(x: p1.x + nx, y: p1.y + ny))
    path.addLine(to: CGPoint(x: p2.x + nx, y: p2.y + ny))
    path.addLine(to: CGPoint(x: p2.x - nx, y: p2.y - ny))
    path.addLine(to: CGPoint(x: p1.x - nx, y: p1.y - ny))
    path.closeSubpath()
    context.fill(path, with: .color(Color(.systemBackground)))
}

/// Draws a white filled rectangle over the wall gap where an opening sits (CGContext).
private func eraseBandCG(from p1: CGPoint, to p2: CGPoint,
                          halfWidth: CGFloat,
                          fillColor: CGColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                          context: CGContext) {
    let dx = p2.x - p1.x, dy = p2.y - p1.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len * halfWidth, ny = dx / len * halfWidth

    context.setFillColor(fillColor)
    context.beginPath()
    context.move(to: CGPoint(x: p1.x + nx, y: p1.y + ny))
    context.addLine(to: CGPoint(x: p2.x + nx, y: p2.y + ny))
    context.addLine(to: CGPoint(x: p2.x - nx, y: p2.y - ny))
    context.addLine(to: CGPoint(x: p1.x - nx, y: p1.y - ny))
    context.closePath()
    context.fillPath()
}
