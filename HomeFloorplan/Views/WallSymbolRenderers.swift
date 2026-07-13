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

/// Draws the selection halo under a wall segment on a SwiftUI `GraphicsContext`.
func drawWallSelectionHalo(_ wall: WallSegment, context: inout GraphicsContext) {
    let w = DrawingDocument.wallWidth(for: wall.kind)
    var path = Path()
    path.move(to: wall.start)
    path.addLine(to: wall.end)
    context.stroke(path,
                   with: .color(DrawingStyle.selectionColor),
                   style: StrokeStyle(lineWidth: w + DrawingStyle.selectionWidth * 2,
                                      lineCap: .square))
}

private func wallChainsPath(_ chains: [DrawingDocument.WallChain]) -> Path {
    var path = Path()
    for chain in chains where chain.points.count >= 2 {
        path.move(to: chain.points[0])
        for pt in chain.points.dropFirst() { path.addLine(to: pt) }
        if chain.isClosed { path.closeSubpath() }
    }
    return path
}

/// Draws all walls of `kind` as connected polylines with mitered joins, so
/// corners stay clean at any angle (per-segment square caps only meet cleanly
/// at 90°).
func drawWallChains(_ doc: DrawingDocument,
                    kind: WallKind,
                    context: inout GraphicsContext) {
    let chains = doc.wallChains(for: kind)
    guard !chains.isEmpty else { return }
    let path = wallChainsPath(chains)
    let w = DrawingDocument.wallWidth(for: kind)
    let style = StrokeStyle(lineWidth: w, lineCap: .square, lineJoin: .miter)

    context.stroke(path, with: .color(DrawingStyle.wallColor), style: style)
    if kind == .balcony {
        // Inner line (background color) — creates the hollow / double-line look
        context.stroke(path,
                       with: .color(Color(.systemBackground)),
                       style: StrokeStyle(lineWidth: w * 0.45, lineCap: .square, lineJoin: .miter))
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

/// Draws a sliding door symbol: two parallel leaves offset to opposite sides
/// of the wall axis, overlapping slightly at the centre.
func drawSlidingDoor(_ opening: PlacedOpening,
                     wall: WallSegment,
                     context: inout GraphicsContext,
                     selected: Bool = false) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip, ny = ux * flip

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBand(from: eps.start, to: eps.end, halfWidth: wallW / 2 + 1, context: &context)

    let off = wallW * 0.24
    let overlap = opening.width * 0.08
    let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2, y: (eps.start.y + eps.end.y) / 2)

    var leafA = Path()
    leafA.move(to: CGPoint(x: eps.start.x + nx * off, y: eps.start.y + ny * off))
    leafA.addLine(to: CGPoint(x: mid.x + ux * overlap + nx * off,
                              y: mid.y + uy * overlap + ny * off))
    var leafB = Path()
    leafB.move(to: CGPoint(x: mid.x - ux * overlap - nx * off,
                           y: mid.y - uy * overlap - ny * off))
    leafB.addLine(to: CGPoint(x: eps.end.x - nx * off, y: eps.end.y - ny * off))

    let color: Color = selected ? DrawingStyle.selectionColor : DrawingStyle.doorArcColor
    let style = StrokeStyle(lineWidth: DrawingStyle.doorLineWidth + 0.6, lineCap: .round)
    context.stroke(leafA, with: .color(color), style: style)
    context.stroke(leafB, with: .color(color), style: style)
}

/// Draws a French door symbol: two leaves swinging from the jambs and meeting
/// at the centre, plus a thin glazing line across the gap.
func drawFrenchDoor(_ opening: PlacedOpening,
                    wall: WallSegment,
                    context: inout GraphicsContext,
                    selected: Bool = false) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip, ny = ux * flip

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseBand(from: eps.start, to: eps.end, halfWidth: wallW / 2 + 1, context: &context)

    let half = opening.width / 2
    let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2, y: (eps.start.y + eps.end.y) / 2)
    let color: Color = selected ? DrawingStyle.selectionColor : DrawingStyle.doorArcColor

    var arcs = Path()
    arcs.addArc(center: eps.start, radius: half,
                startAngle: Angle(radians: atan2(Double(uy), Double(ux))),
                endAngle: Angle(radians: atan2(Double(ny), Double(nx))),
                clockwise: opening.flipSide)
    arcs.move(to: eps.end)
    arcs.addArc(center: eps.end, radius: half,
                startAngle: Angle(radians: atan2(Double(-uy), Double(-ux))),
                endAngle: Angle(radians: atan2(Double(ny), Double(nx))),
                clockwise: !opening.flipSide)
    context.stroke(arcs, with: .color(color),
                   style: StrokeStyle(lineWidth: DrawingStyle.doorLineWidth, lineCap: .round, dash: [4, 3]))

    var leaves = Path()
    leaves.move(to: eps.start)
    leaves.addLine(to: mid)
    leaves.move(to: eps.end)
    leaves.addLine(to: mid)
    context.stroke(leaves, with: .color(color),
                   style: StrokeStyle(lineWidth: DrawingStyle.doorLineWidth, lineCap: .round))

    // Glazing line across the gap
    var sill = Path()
    sill.move(to: eps.start)
    sill.addLine(to: eps.end)
    context.stroke(sill, with: .color(selected ? DrawingStyle.selectionColor : DrawingStyle.windowColor),
                   style: StrokeStyle(lineWidth: DrawingStyle.windowLineWidth, lineCap: .round))
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

    // Furniture items (after room areas, before walls; rugs always first)
    for item in doc.furnitureDrawOrder {
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
        drawWallChainsCG(doc, kind: kind, context: cgContext)
    }
    if visualStyle == .architectural {
        drawWallBevelsCG(doc, context: cgContext)
    }

    // Openings
    for opening in doc.openings {
        guard let wall = doc.wall(for: opening.wallID) else { continue }
        let wallHalf = DrawingDocument.wallWidth(for: wall.kind) / 2 + 1
        switch opening.kind {
        case .door:   drawDoorCG(opening, wall: wall, context: cgContext)
        case .window: drawWindowCG(opening, wall: wall, context: cgContext)
        case .slidingDoor:
            if let eps = endpointsOf(opening: opening, wall: wall) {
                eraseBandCG(from: eps.start, to: eps.end, halfWidth: wallHalf, context: cgContext)
            }
            drawSlidingDoorCG(opening, wall: wall,
                              strokeColor: DrawingStyle.doorCGColor, context: cgContext)
        case .frenchDoor:
            if let eps = endpointsOf(opening: opening, wall: wall) {
                eraseBandCG(from: eps.start, to: eps.end, halfWidth: wallHalf, context: cgContext)
            }
            drawFrenchDoorCG(opening, wall: wall,
                             strokeColor: DrawingStyle.doorCGColor,
                             glazingColor: DrawingStyle.windowCGColor, context: cgContext)
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
    static let roomFill = UIColor(red: 0.140, green: 0.170, blue: 0.205, alpha: 0.94)
    static let roomAlternateFill = UIColor(red: 0.120, green: 0.150, blue: 0.185, alpha: 0.94)
    static let roomStroke = UIColor(red: 0.42, green: 0.50, blue: 0.58, alpha: 0.22)
    static let wallExterior = UIColor(red: 0.84, green: 0.87, blue: 0.90, alpha: 1)
    static let wallInterior = UIColor(red: 0.62, green: 0.68, blue: 0.74, alpha: 1)
    static let wallBalcony = UIColor(red: 0.55, green: 0.61, blue: 0.68, alpha: 0.85)
    static let openingLine = UIColor(red: 0.72, green: 0.78, blue: 0.84, alpha: 0.62)
    static let furnitureStroke = UIColor(red: 0.74, green: 0.79, blue: 0.84, alpha: 0.60)
    static let furnitureFill = UIColor(red: 0.30, green: 0.33, blue: 0.37, alpha: 0.90)
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

    for item in doc.furnitureDrawOrder {
        drawDarkFurnitureItemCG(item, context: context, drawText: drawText)
    }

    drawWallDepthShadowCG(doc, context: context, tightAlpha: 0.55, ambientAlpha: 0.35)
    drawDarkWallShadowsCG(doc, context: context)

    let wallDrawOrder: [WallKind] = [.balcony, .interior, .exterior]
    for kind in wallDrawOrder {
        drawDarkWallChainsCG(doc, kind: kind, context: context)
    }
    for wall in doc.walls where wall.kind != .balcony {
        drawDarkWallHighlightCG(wall, context: context)
    }

    for opening in doc.openings {
        guard let wall = doc.wall(for: opening.wallID) else { continue }
        let wallHalf = DrawingDocument.wallWidth(for: wall.kind) / 2 + 1
        switch opening.kind {
        case .door:
            drawDarkDoorCG(opening, wall: wall, doc: doc, context: context)
        case .window:
            drawDarkWindowCG(opening, wall: wall, doc: doc, context: context)
        case .slidingDoor:
            if let eps = endpointsOf(opening: opening, wall: wall) {
                eraseOpeningBandDarkCG(doc, from: eps.start, to: eps.end,
                                       halfWidth: wallHalf, context: context)
            }
            drawSlidingDoorCG(opening, wall: wall,
                              strokeColor: DarkArchitecturalPalette.openingLine.cgColor,
                              context: context)
        case .frenchDoor:
            if let eps = endpointsOf(opening: opening, wall: wall) {
                eraseOpeningBandDarkCG(doc, from: eps.start, to: eps.end,
                                       halfWidth: wallHalf, context: context)
            }
            drawFrenchDoorCG(opening, wall: wall,
                             strokeColor: DarkArchitecturalPalette.openingLine.cgColor,
                             glazingColor: DarkArchitecturalPalette.openingLine.withAlphaComponent(0.45).cgColor,
                             context: context)
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

// CGContext shadows are specified in base (device) space and ignore the CTM,
// so canvas-unit blur/offset values must be converted or shadows shrink
// relative to walls as the export scale factor decreases.
private func shadowDeviceScale(_ context: CGContext) -> CGFloat {
    let t = context.userSpaceToDeviceSpaceTransform
    let s = hypot(t.a, t.b)
    return s.isFinite && s > 0 ? s : 1
}

private func shadowDeviceOffset(_ context: CGContext, _ canvasOffset: CGSize) -> CGSize {
    let t = context.userSpaceToDeviceSpaceTransform
    return CGSize(width: canvasOffset.width * t.a + canvasOffset.height * t.c,
                  height: canvasOffset.width * t.b + canvasOffset.height * t.d)
}

/// Approximate silhouette of the furniture's dominant drawn shape, used as the
/// shadow caster: shadows must follow what is visibly drawn, not the bounding
/// rect (a chair casting a rectangle reads as a stain on patterned floors).
/// Subpaths must not overlap — the even-odd clip in the shadow pass would
/// otherwise paint the source through the overlap region.
private func furnitureShadowPath(_ item: FurnitureItem) -> UIBezierPath {
    let rect = item.rect
    func rounded(_ r: CGRect, _ radius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: r, cornerRadius: min(radius, min(r.width, r.height) / 2))
    }
    let path: UIBezierPath
    switch item.kind {
    case .sofa:
        path = rounded(rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.10), 10)
    case .armchair:
        path = rounded(rect.insetBy(dx: rect.width * 0.11, dy: rect.height * 0.10), 10)
    case .diningTable:
        path = UIBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.14))
    case .chair:
        let seat = CGRect(x: rect.minX + rect.width * 0.23, y: rect.minY + rect.height * 0.34,
                          width: rect.width * 0.54, height: rect.height * 0.42)
        let back = CGRect(x: seat.minX - rect.width * 0.03, y: rect.minY + rect.height * 0.15,
                          width: seat.width + rect.width * 0.06, height: rect.height * 0.16)
        path = rounded(seat, 4)
        path.append(rounded(back, 3))
    case .bed:
        path = rounded(rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.06), 7)
    case .wardrobe:
        path = rounded(rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.10), 4)
    case .toilet:
        let tank = CGRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.12,
                          width: rect.width * 0.56, height: rect.height * 0.22)
        let bowl = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.34,
                          width: rect.width * 0.64, height: rect.height * 0.46)
        path = rounded(tank, 3)
        path.append(UIBezierPath(ovalIn: bowl))
    case .sink:
        path = UIBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.18))
    case .inductionCooktop:
        path = rounded(rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.10), 5)
    case .washingMachine:
        path = rounded(rect.insetBy(dx: rect.width * 0.10, dy: rect.height * 0.08), 6)
    case .bathtub:
        let tub = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.18)
        path = rounded(tub, tub.height / 2)
    case .shower:
        path = rounded(rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12), 4)
    case .kitchenCounter:
        path = rounded(rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.08), 4)
    case .tvUnit:
        path = rounded(rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.18), 4)
    case .plant:
        let side = min(rect.width, rect.height)
        let r = side * 0.52
        path = UIBezierPath(ovalIn: CGRect(x: rect.midX - r, y: rect.midY - r,
                                           width: r * 2, height: r * 2))
    case .rug:
        // Flat on the floor: the path exists for completeness but rug is skipped
        // by the shadow and sheen passes.
        path = rounded(rect, 8)
    case .kitchenSink:
        path = rounded(rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.08), 3)
    case .stairs:
        path = rounded(rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04), 3)
    case .spiralStairs:
        let side = min(rect.width, rect.height)
        let r = side * 0.48
        path = UIBezierPath(ovalIn: CGRect(x: rect.midX - r, y: rect.midY - r,
                                           width: r * 2, height: r * 2))
    case .generic:
        path = rounded(rect, 4)
    }
    let rotation = CGAffineTransform(translationX: rect.midX, y: rect.midY)
        .rotated(by: CGFloat(item.rotationDegrees * .pi / 180))
        .translatedBy(x: -rect.midX, y: -rect.midY)
    path.apply(rotation)
    return path
}

/// Directional sheen on the furniture silhouette (dark style only): a light rim
/// on the lit side and a dark rim on the shaded side, matching the wall bevels'
/// global light vector so furniture reads as raised, not cut out.
private func drawDarkFurnitureSheenCG(_ item: FurnitureItem, context: CGContext) {
    guard item.kind != .rug else { return }
    let path = furnitureShadowPath(item)
    let litShift = CGSize(width: 1.9, height: 2.2)   // toward light direction opposite

    context.saveGState()
    context.addPath(path.cgPath)
    context.clip()

    var toward = CGAffineTransform(translationX: litShift.width, y: litShift.height)
    if let shifted = path.cgPath.copy(using: &toward) {
        context.addPath(shifted)
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(3.6)
        context.strokePath()
    }

    var away = CGAffineTransform(translationX: -litShift.width, y: -litShift.height)
    if let shifted = path.cgPath.copy(using: &away) {
        context.addPath(shifted)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(3.6)
        context.strokePath()
    }
    context.restoreGState()
}

private func drawDarkFurnitureShadowsCG(_ doc: DrawingDocument, context: CGContext) {
    for item in doc.furnitureItems where item.kind != .rug {
        let path = furnitureShadowPath(item)
        // Shadow reach scales with the object footprint: a chair must not cast
        // the same shadow as a sofa.
        let ref = min(item.rect.width, item.rect.height)
        let offset = CGSize(width: min(5, ref * 0.07), height: min(8, ref * 0.11))
        let blur = min(12, max(4, ref * 0.14))

        context.saveGState()
        // Shadow strength is multiplied by the source alpha, so the silhouette must
        // be painted opaque; clipping it out keeps only the outer shadow visible.
        context.addRect(CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5))
        context.addPath(path.cgPath)
        context.clip(using: .evenOdd)
        context.setShadow(offset: shadowDeviceOffset(context, offset),
                          blur: blur * shadowDeviceScale(context),
                          color: UIColor.black.withAlphaComponent(0.40).cgColor)
        context.setFillColor(UIColor.black.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.restoreGState()
    }
}

private func drawDarkFurnitureItemCG(_ item: FurnitureItem, context: CGContext, drawText: Bool = true) {
    let fill: UIColor = {
        if let tint = item.tint, item.kind.supportsTint {
            return UIColor(cgColor: tint.darkCGColor).withAlphaComponent(0.90)
        }
        return DarkArchitecturalPalette.furnitureFill
    }()
    UIGraphicsPushContext(context)
    drawFurnitureBlueprintCG(
        item,
        context: context,
        fillColor: fill,
        strokeColor: DarkArchitecturalPalette.furnitureStroke,
        detailColor: DarkArchitecturalPalette.text.withAlphaComponent(0.50),
        lineWidth: 1.4
    )
    drawDarkFurnitureSheenCG(item, context: context)

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
    context.setLineJoin(.miter)
    context.setLineDash(phase: 0, lengths: [])

    for kind in [WallKind.interior, .exterior] {
        let chains = doc.wallChains(for: kind)
        guard !chains.isEmpty else { continue }
        let width = DrawingDocument.wallWidth(for: kind)
        let isExterior = kind == .exterior
        context.saveGState()
        context.setShadow(offset: shadowDeviceOffset(context, CGSize(width: width * 0.45, height: width * 0.55)),
                          blur: width * 2.2 * shadowDeviceScale(context),
                          color: UIColor.black.withAlphaComponent(isExterior ? 0.55 : 0.38).cgColor)
        // Opaque source: shadow strength is multiplied by the source alpha, and the
        // stroke itself is fully covered when the walls are painted afterwards.
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(width)
        addWallChainsPath(chains, to: context)
        context.strokePath()
        context.restoreGState()
    }

    context.restoreGState()
}

private func drawDarkWallChainsCG(_ doc: DrawingDocument, kind: WallKind, context: CGContext) {
    let chains = doc.wallChains(for: kind)
    guard !chains.isEmpty else { return }
    let width = DrawingDocument.wallWidth(for: kind)
    context.setLineDash(phase: 0, lengths: [])
    context.setLineCap(.square)
    context.setLineJoin(.miter)

    if kind == .balcony {
        context.setStrokeColor(DarkArchitecturalPalette.wallBalcony.cgColor)
        context.setLineWidth(width)
        addWallChainsPath(chains, to: context)
        context.strokePath()

        context.setStrokeColor(DarkArchitecturalPalette.background.withAlphaComponent(0.88).cgColor)
        context.setLineWidth(width * 0.48)
        addWallChainsPath(chains, to: context)
        context.strokePath()
        return
    }

    context.setStrokeColor((kind == .exterior
                            ? DarkArchitecturalPalette.wallExterior
                            : DarkArchitecturalPalette.wallInterior).cgColor)
    context.setLineWidth(width)
    addWallChainsPath(chains, to: context)
    context.strokePath()
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
    let shadedNormal = CGPoint(x: -litNormal.x, y: -litNormal.y)
    let edgeOffset = width * 0.36
    let inset = width * 0.16
    let start = CGPoint(x: wall.start.x + unitX * inset, y: wall.start.y + unitY * inset)
    let end = CGPoint(x: wall.end.x - unitX * inset, y: wall.end.y - unitY * inset)

    context.setLineCap(.butt)
    context.setLineWidth(max(1.5, width * 0.14))

    context.setStrokeColor(UIColor.white.withAlphaComponent(wall.kind == .exterior ? 0.55 : 0.38).cgColor)
    context.move(to: CGPoint(x: start.x + litNormal.x * edgeOffset,
                             y: start.y + litNormal.y * edgeOffset))
    context.addLine(to: CGPoint(x: end.x + litNormal.x * edgeOffset,
                                y: end.y + litNormal.y * edgeOffset))
    context.strokePath()

    context.setStrokeColor(UIColor.black.withAlphaComponent(wall.kind == .exterior ? 0.38 : 0.28).cgColor)
    context.move(to: CGPoint(x: start.x + shadedNormal.x * edgeOffset,
                             y: start.y + shadedNormal.y * edgeOffset))
    context.addLine(to: CGPoint(x: end.x + shadedNormal.x * edgeOffset,
                                y: end.y + shadedNormal.y * edgeOffset))
    context.strokePath()
}

/// Erases the wall under an opening by re-painting what lies beneath —
/// background, the floors of the rooms crossing the band, and the depth
/// gradient — so textured floors continue through the gap instead of
/// showing a flat patch of `roomFill`.
private func eraseOpeningBandDarkCG(_ doc: DrawingDocument,
                                    from p1: CGPoint, to p2: CGPoint,
                                    halfWidth: CGFloat,
                                    context: CGContext) {
    let dx = p2.x - p1.x, dy = p2.y - p1.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len * halfWidth, ny = dx / len * halfWidth

    let band = UIBezierPath()
    band.move(to: CGPoint(x: p1.x + nx, y: p1.y + ny))
    band.addLine(to: CGPoint(x: p2.x + nx, y: p2.y + ny))
    band.addLine(to: CGPoint(x: p2.x - nx, y: p2.y - ny))
    band.addLine(to: CGPoint(x: p1.x - nx, y: p1.y - ny))
    band.close()

    context.saveGState()
    context.addPath(band.cgPath)
    context.clip()

    context.setFillColor(DarkArchitecturalPalette.background.cgColor)
    context.fill(band.bounds.insetBy(dx: -2, dy: -2))

    UIGraphicsPushContext(context)
    for (index, area) in doc.roomAreas.enumerated()
    where area.boundingRect.intersects(band.bounds.insetBy(dx: -1, dy: -1)) {
        let path = roomAreaPath(area)
        if let kind = area.floorKind {
            drawFloorPatternCG(kind, path: path, bounds: area.boundingRect,
                               context: context, dark: true)
        } else {
            (index.isMultiple(of: 2) ? DarkArchitecturalPalette.roomFill
                                     : DarkArchitecturalPalette.roomAlternateFill).setFill()
            path.fill()
        }
    }
    UIGraphicsPopContext()

    drawWallDepthShadowCG(doc, context: context, tightAlpha: 0.55, ambientAlpha: 0.35)

    context.restoreGState()
}

private func drawDarkDoorCG(_ opening: PlacedOpening, wall: WallSegment, doc: DrawingDocument, context: CGContext) {
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
    eraseOpeningBandDarkCG(doc,
                           from: eps.start,
                           to: eps.end,
                           halfWidth: wallW / 2 + 1,
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

private func drawDarkWindowCG(_ opening: PlacedOpening, wall: WallSegment, doc: DrawingDocument, context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }

    let dx = wall.end.x - wall.start.x
    let dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let nx = -dy / len
    let ny = dx / len

    let wallW = DrawingDocument.wallWidth(for: wall.kind)
    eraseOpeningBandDarkCG(doc,
                           from: eps.start,
                           to: eps.end,
                           halfWidth: wallW / 2 + 1,
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
        if dark {
            drawDarkWoodPlanksCG(bounds: bounds)
        } else {
            UIColor(red: 0.85, green: 0.72, blue: 0.52, alpha: 0.28).setFill()
            path.fill()
            UIColor(red: 0.58, green: 0.40, blue: 0.22, alpha: 0.22).setStroke()
            var y = (bounds.minY / 12).rounded(.down) * 12
            while y <= bounds.maxY {
                let line = UIBezierPath()
                line.move(to: CGPoint(x: bounds.minX, y: y))
                line.addLine(to: CGPoint(x: bounds.maxX, y: y))
                line.lineWidth = 0.8
                line.stroke()
                y += 12
            }
        }

    case .piastrelle:
        if dark {
            drawDarkTileFloorCG(bounds: bounds, spacing: 30,
                                base: (red: 0.60, green: 0.62, blue: 0.65),
                                alpha: 0.32)
        } else {
            UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 0.40).setFill()
            path.fill()
            drawFloorGridCG(bounds: bounds, spacing: 30,
                            color: UIColor.gray.withAlphaComponent(0.28))
        }

    case .gres:
        if dark {
            drawDarkTileFloorCG(bounds: bounds, spacing: 60,
                                base: (red: 0.58, green: 0.57, blue: 0.54),
                                alpha: 0.30)
        } else {
            UIColor(red: 0.87, green: 0.85, blue: 0.80, alpha: 0.38).setFill()
            path.fill()
            drawFloorGridCG(bounds: bounds, spacing: 60,
                            color: UIColor.gray.withAlphaComponent(0.32))
        }

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

/// Deterministic per-cell hash in [0, 1) so pattern variation is stable across
/// exports (same document → same PNG). Never use randomness here.
private func floorPatternHash(_ x: Int, _ y: Int) -> CGFloat {
    var h: UInt64 = 0x9E3779B97F4A7C15
    h ^= UInt64(bitPattern: Int64(x)) &* 0xBF58476D1CE4E5B9
    h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
    h ^= UInt64(bitPattern: Int64(y)) &* 0xD6E8FEB86659FD93
    h ^= h >> 31
    return CGFloat(h % 4096) / 4096
}

/// Staggered wood planks with per-plank tone variation (dark export style).
/// Geometry is anchored to absolute canvas coordinates so the pattern does not
/// shift when a room is moved or resized, and adjacent wood rooms stay aligned.
private func drawDarkWoodPlanksCG(bounds: CGRect) {
    let plankH: CGFloat = 12    // 12 cm at 100 pt/m
    let plankW: CGFloat = 84
    let joint: CGFloat = 0.7

    // Joint/base layer, visible only in the gaps between planks
    UIColor(red: 0.14, green: 0.11, blue: 0.08, alpha: 0.60).setFill()
    UIBezierPath(rect: bounds).fill()

    let tones: [(red: CGFloat, green: CGFloat, blue: CGFloat)] = [
        (0.40, 0.31, 0.22),
        (0.35, 0.27, 0.19),
        (0.44, 0.34, 0.24),
        (0.31, 0.24, 0.17)
    ]

    var row = Int((bounds.minY / plankH).rounded(.down))
    while CGFloat(row) * plankH <= bounds.maxY {
        let y = CGFloat(row) * plankH
        let rowOffset = floorPatternHash(row, 7391) * plankW
        var col = Int(((bounds.minX - rowOffset) / plankW).rounded(.down))
        while CGFloat(col) * plankW + rowOffset <= bounds.maxX {
            let x = CGFloat(col) * plankW + rowOffset
            let tone = tones[Int(floorPatternHash(col, row) * CGFloat(tones.count)) % tones.count]
            UIColor(red: tone.red, green: tone.green, blue: tone.blue, alpha: 0.55).setFill()
            UIBezierPath(rect: CGRect(x: x + joint, y: y + joint,
                                      width: plankW - joint * 2,
                                      height: plankH - joint * 2)).fill()
            col += 1
        }
        row += 1
    }
}

/// Tile floor with dark grout lines and subtle per-tile luminance variation
/// (dark export style). Anchored to absolute canvas coordinates like the planks.
private func drawDarkTileFloorCG(bounds: CGRect, spacing: CGFloat,
                                 base: (red: CGFloat, green: CGFloat, blue: CGFloat),
                                 alpha: CGFloat) {
    let grout: CGFloat = 0.6

    // Grout layer, visible only in the gaps between tiles
    UIColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 0.50).setFill()
    UIBezierPath(rect: bounds).fill()

    var row = Int((bounds.minY / spacing).rounded(.down))
    while CGFloat(row) * spacing <= bounds.maxY {
        var col = Int((bounds.minX / spacing).rounded(.down))
        while CGFloat(col) * spacing <= bounds.maxX {
            let delta = (floorPatternHash(col, row) - 0.5) * 0.10
            UIColor(red: base.red + delta,
                    green: base.green + delta,
                    blue: base.blue + delta,
                    alpha: alpha).setFill()
            UIBezierPath(rect: CGRect(x: CGFloat(col) * spacing + grout,
                                      y: CGFloat(row) * spacing + grout,
                                      width: spacing - grout * 2,
                                      height: spacing - grout * 2)).fill()
            col += 1
        }
        row += 1
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
    let fill: UIColor = {
        if let tint = item.tint, item.kind.supportsTint {
            return UIColor(cgColor: tint.lightCGColor)
        }
        return UIColor(white: 0.92, alpha: 1)
    }()
    UIGraphicsPushContext(context)
    drawFurnitureBlueprintCG(
        item,
        context: context,
        fillColor: fill,
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
                                      detailColor: UIColor,
                                      lineWidth: CGFloat = 1) {
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
        path.lineWidth = lineWidth
        path.stroke()
    }

    func line(_ a: CGPoint, _ b: CGPoint, color: UIColor = detailColor) {
        color.setStroke()
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        path.lineWidth = lineWidth
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
            path.lineWidth = lineWidth
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
        framePath.lineWidth = lineWidth
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
            path.lineWidth = lineWidth
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
        framePath.lineWidth = lineWidth
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
        backPath.lineWidth = lineWidth
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
        let bowlDetail = UIBezierPath(ovalIn: bowl.insetBy(dx: bowl.width * 0.23, dy: bowl.height * 0.22))
        bowlDetail.lineWidth = lineWidth
        bowlDetail.stroke()

    case .sink:
        let basin = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.18)
        fillStroke(UIBezierPath(ovalIn: basin))
        detailColor.setStroke()
        let basinDetail = UIBezierPath(ovalIn: basin.insetBy(dx: basin.width * 0.22, dy: basin.height * 0.22))
        basinDetail.lineWidth = lineWidth
        basinDetail.stroke()
        line(CGPoint(x: rect.midX, y: basin.minY), CGPoint(x: rect.midX, y: basin.minY - rect.height * 0.12), color: strokeColor)

    case .inductionCooktop:
        // Induction glass is always near-black, regardless of style or tint.
        let glass = UIColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 0.94)
        let ring = UIColor(white: 0.78, alpha: 0.75)
        let cooktop = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.10)
        glass.setFill()
        rounded(cooktop, radius: 5).fill()
        strokeColor.setStroke()
        let body = rounded(cooktop, radius: 5)
        body.lineWidth = lineWidth
        body.stroke()

        let zoneRadius = min(cooktop.width, cooktop.height) * 0.15
        let zoneCenters = [
            CGPoint(x: cooktop.minX + cooktop.width * 0.30, y: cooktop.minY + cooktop.height * 0.34),
            CGPoint(x: cooktop.maxX - cooktop.width * 0.30, y: cooktop.minY + cooktop.height * 0.34),
            CGPoint(x: cooktop.minX + cooktop.width * 0.30, y: cooktop.maxY - cooktop.height * 0.34),
            CGPoint(x: cooktop.maxX - cooktop.width * 0.30, y: cooktop.maxY - cooktop.height * 0.34)
        ]
        ring.setStroke()
        for center in zoneCenters {
            let zone = CGRect(x: center.x - zoneRadius, y: center.y - zoneRadius, width: zoneRadius * 2, height: zoneRadius * 2)
            let zonePath = UIBezierPath(ovalIn: zone)
            zonePath.lineWidth = lineWidth
            zonePath.stroke()
            let innerPath = UIBezierPath(ovalIn: zone.insetBy(dx: zoneRadius * 0.38, dy: zoneRadius * 0.38))
            innerPath.lineWidth = lineWidth
            innerPath.stroke()
        }
        line(
            CGPoint(x: cooktop.midX - cooktop.width * 0.18, y: cooktop.maxY - cooktop.height * 0.12),
            CGPoint(x: cooktop.midX + cooktop.width * 0.18, y: cooktop.maxY - cooktop.height * 0.12),
            color: ring.withAlphaComponent(0.55)
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
        panelPath.lineWidth = lineWidth
        panelPath.stroke()
        strokeColor.setStroke()
        let doorPath = UIBezierPath(ovalIn: door)
        doorPath.lineWidth = lineWidth
        doorPath.stroke()
        detailColor.setStroke()
        let innerDoor = UIBezierPath(ovalIn: door.insetBy(dx: doorRadius * 0.28, dy: doorRadius * 0.28))
        innerDoor.lineWidth = lineWidth
        innerDoor.stroke()
        detailColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: panel.maxX - panel.width * 0.20, y: panel.midY - 3, width: 6, height: 6)).fill()
        line(CGPoint(x: panel.minX + panel.width * 0.12, y: panel.midY), CGPoint(x: panel.minX + panel.width * 0.34, y: panel.midY))

    case .bathtub:
        let tub = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.18)
        fillStroke(rounded(tub, radius: tub.height / 2))
        detailColor.setStroke()
        let tubDetail = rounded(tub.insetBy(dx: tub.width * 0.10, dy: tub.height * 0.20), radius: tub.height / 3)
        tubDetail.lineWidth = lineWidth
        tubDetail.stroke()
        line(CGPoint(x: tub.minX + tub.width * 0.12, y: tub.minY), CGPoint(x: tub.minX + tub.width * 0.12, y: tub.minY - rect.height * 0.10), color: strokeColor)

    case .shower:
        let base = rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12)
        fillStroke(rounded(base, radius: 4))
        line(CGPoint(x: base.minX, y: base.minY), CGPoint(x: base.maxX, y: base.maxY))
        line(CGPoint(x: base.maxX, y: base.minY), CGPoint(x: base.minX, y: base.maxY))
        detailColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: base.midX - 4, y: base.midY - 4, width: 8, height: 8)).fill()

    case .kitchenCounter:
        let body = rect.insetBy(dx: rect.width * 0.03, dy: rect.height * 0.08)
        fillStroke(rounded(body, radius: 4))
        detailColor.setStroke()
        let inner = rounded(body.insetBy(dx: min(6, body.width * 0.06), dy: min(6, body.height * 0.14)), radius: 3)
        inner.lineWidth = lineWidth
        inner.stroke()

    case .tvUnit:
        let cabinet = rect.insetBy(dx: rect.width * 0.05, dy: rect.height * 0.18)
        fillStroke(rounded(cabinet, radius: 4))
        let tv = CGRect(x: rect.midX - rect.width * 0.35,
                        y: cabinet.minY + cabinet.height * 0.18,
                        width: rect.width * 0.70,
                        height: max(3, cabinet.height * 0.20))
        strokeColor.withAlphaComponent(0.65).setFill()
        rounded(tv, radius: 2).fill()

    case .plant:
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let leafW = side * 0.42, leafH = side * 0.22
        UIColor(red: 0.45, green: 0.62, blue: 0.45, alpha: 0.35).setFill()
        UIColor(red: 0.38, green: 0.55, blue: 0.40, alpha: 0.70).setStroke()
        for i in 0 ..< 6 {
            let angle = CGFloat(Double(i) * 60.0 * .pi / 180)
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle)
            let leaf = UIBezierPath(ovalIn: CGRect(x: side * 0.10, y: -leafH / 2, width: leafW, height: leafH))
            leaf.lineWidth = lineWidth
            leaf.fill()
            leaf.stroke()
            context.restoreGState()
        }
        let potR = side * 0.16
        fillStroke(UIBezierPath(ovalIn: CGRect(x: center.x - potR, y: center.y - potR,
                                               width: potR * 2, height: potR * 2)))

    case .rug:
        fillColor.withAlphaComponent(fillColor.cgColor.alpha * 0.40).setFill()
        rounded(rect, radius: 8).fill()
        strokeColor.withAlphaComponent(0.80).setStroke()
        let outer = rounded(rect, radius: 8)
        outer.lineWidth = lineWidth
        outer.stroke()
        detailColor.setStroke()
        let innerRug = rounded(rect.insetBy(dx: min(9, rect.width * 0.08), dy: min(9, rect.height * 0.08)), radius: 5)
        innerRug.lineWidth = lineWidth
        innerRug.setLineDash([5, 4], count: 2, phase: 0)
        innerRug.stroke()

    case .kitchenSink:
        let body = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.08)
        fillStroke(rounded(body, radius: 3))
        detailColor.setStroke()
        let basin = CGRect(x: body.minX + body.width * 0.12,
                           y: body.minY + body.height * 0.26,
                           width: body.width * 0.76,
                           height: body.height * 0.60)
        let basinPath = rounded(basin, radius: 4)
        basinPath.lineWidth = lineWidth
        basinPath.stroke()
        detailColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: basin.midX - 3, y: basin.midY - 3, width: 6, height: 6)).fill()
        strokeColor.setFill()
        let faucet = CGPoint(x: body.midX, y: body.minY + body.height * 0.13)
        UIBezierPath(ovalIn: CGRect(x: faucet.x - 3, y: faucet.y - 3, width: 6, height: 6)).fill()
        line(faucet, CGPoint(x: faucet.x, y: basin.minY), color: strokeColor)

    case .stairs:
        let body = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04)
        fillStroke(rounded(body, radius: 3))
        // Treads: ~26 pt each (≈26 cm at 100 pt/m)
        let count = max(3, Int(body.height / 26))
        let step = body.height / CGFloat(count)
        for i in 1 ..< count {
            let y = body.minY + CGFloat(i) * step
            line(CGPoint(x: body.minX, y: y), CGPoint(x: body.maxX, y: y))
        }
        // Walkline: circle at the base, arrow pointing up (climb direction)
        let cx = body.midX
        let tipY = body.minY + step * 0.6
        line(CGPoint(x: cx, y: body.maxY - step * 0.5), CGPoint(x: cx, y: tipY), color: strokeColor)
        let ah = min(8, body.width * 0.14)
        line(CGPoint(x: cx - ah, y: tipY + ah), CGPoint(x: cx, y: tipY), color: strokeColor)
        line(CGPoint(x: cx + ah, y: tipY + ah), CGPoint(x: cx, y: tipY), color: strokeColor)
        strokeColor.setFill()
        UIBezierPath(ovalIn: CGRect(x: cx - 3, y: body.maxY - step * 0.5 - 3, width: 6, height: 6)).fill()

    case .spiralStairs:
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerR = side * 0.48
        fillStroke(UIBezierPath(ovalIn: CGRect(x: center.x - outerR, y: center.y - outerR,
                                               width: outerR * 2, height: outerR * 2)))
        let poleR = side * 0.07
        for i in 0 ..< 10 {
            let a = CGFloat(i) * (.pi * 2 / 10)
            line(CGPoint(x: center.x + cos(a) * poleR, y: center.y + sin(a) * poleR),
                 CGPoint(x: center.x + cos(a) * outerR, y: center.y + sin(a) * outerR))
        }
        strokeColor.withAlphaComponent(0.70).setFill()
        UIBezierPath(ovalIn: CGRect(x: center.x - poleR, y: center.y - poleR,
                                    width: poleR * 2, height: poleR * 2)).fill()

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

private func addWallChainsPath(_ chains: [DrawingDocument.WallChain], to context: CGContext) {
    for chain in chains where chain.points.count >= 2 {
        context.move(to: chain.points[0])
        for pt in chain.points.dropFirst() { context.addLine(to: pt) }
        if chain.isClosed { context.closePath() }
    }
}

private func drawWallChainsCG(_ doc: DrawingDocument, kind: WallKind, context: CGContext) {
    let chains = doc.wallChains(for: kind)
    guard !chains.isEmpty else { return }
    let w = DrawingDocument.wallWidth(for: kind)
    context.setLineDash(phase: 0, lengths: [])
    context.setLineCap(.square)
    context.setLineJoin(.miter)

    context.setStrokeColor(DrawingStyle.wallCGColor)
    context.setLineWidth(w)
    addWallChainsPath(chains, to: context)
    context.strokePath()

    if kind == .balcony {
        // Inner white stroke — creates the hollow / double-line look
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(w * 0.45)
        addWallChainsPath(chains, to: context)
        context.strokePath()
    }
}

private func drawWallCastShadowsCG(_ doc: DrawingDocument, context: CGContext) {
    context.saveGState()
    context.setLineCap(.square)
    context.setLineJoin(.miter)
    context.setLineDash(phase: 0, lengths: [])

    for kind in [WallKind.interior, .exterior] {
        let chains = doc.wallChains(for: kind)
        guard !chains.isEmpty else { continue }
        let width = DrawingDocument.wallWidth(for: kind)
        let isExterior = kind == .exterior
        let offset = CGSize(width: width * 0.16, height: width * 0.20)

        context.saveGState()
        context.setShadow(offset: offset,
                          blur: isExterior ? 5.5 : 3.5,
                          color: UIColor.black.withAlphaComponent(isExterior ? 0.16 : 0.10).cgColor)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.03).cgColor)
        context.setLineWidth(width)
        addWallChainsPath(chains, to: context)
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

/// Shared geometry for sliding/French door symbols on a CGContext.
/// `strokeColor` draws the leaves/arcs; `glazingColor` the French sill line.
private func drawSlidingDoorCG(_ opening: PlacedOpening, wall: WallSegment,
                               strokeColor: CGColor, context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }
    let dx = wall.end.x - wall.start.x, dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip, ny = ux * flip

    let off = DrawingDocument.wallWidth(for: wall.kind) * 0.24
    let overlap = opening.width * 0.08
    let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2, y: (eps.start.y + eps.end.y) / 2)

    context.setStrokeColor(strokeColor)
    context.setLineWidth(DrawingStyle.doorLineWidth + 0.6)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [])
    context.move(to: CGPoint(x: eps.start.x + nx * off, y: eps.start.y + ny * off))
    context.addLine(to: CGPoint(x: mid.x + ux * overlap + nx * off,
                                y: mid.y + uy * overlap + ny * off))
    context.strokePath()
    context.move(to: CGPoint(x: mid.x - ux * overlap - nx * off,
                             y: mid.y - uy * overlap - ny * off))
    context.addLine(to: CGPoint(x: eps.end.x - nx * off, y: eps.end.y - ny * off))
    context.strokePath()
}

private func drawFrenchDoorCG(_ opening: PlacedOpening, wall: WallSegment,
                              strokeColor: CGColor, glazingColor: CGColor,
                              context: CGContext) {
    guard let eps = endpointsOf(opening: opening, wall: wall) else { return }
    let dx = wall.end.x - wall.start.x, dy = wall.end.y - wall.start.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len, uy = dy / len
    let flip: CGFloat = opening.flipSide ? -1 : 1
    let nx = -uy * flip, ny = ux * flip

    let half = opening.width / 2
    let mid = CGPoint(x: (eps.start.x + eps.end.x) / 2, y: (eps.start.y + eps.end.y) / 2)

    context.setStrokeColor(strokeColor)
    context.setLineWidth(DrawingStyle.doorLineWidth)
    context.setLineCap(.round)
    context.setLineDash(phase: 0, lengths: [4, 3])
    context.addArc(center: eps.start, radius: half,
                   startAngle: atan2(uy, ux), endAngle: atan2(ny, nx),
                   clockwise: opening.flipSide)
    context.strokePath()
    context.addArc(center: eps.end, radius: half,
                   startAngle: atan2(-uy, -ux), endAngle: atan2(ny, nx),
                   clockwise: !opening.flipSide)
    context.strokePath()

    context.setLineDash(phase: 0, lengths: [])
    context.move(to: eps.start)
    context.addLine(to: mid)
    context.strokePath()
    context.move(to: eps.end)
    context.addLine(to: mid)
    context.strokePath()

    context.setStrokeColor(glazingColor)
    context.setLineWidth(DrawingStyle.windowLineWidth)
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
/// For walls-only documents the closed exterior wall chains describe the real
/// outline (correct for slanted perimeters); the wall bounding box remains the
/// last-resort fallback when the perimeter is not closed.
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
        let closedChains = doc.wallChains(for: .exterior)
            .filter { $0.isClosed && $0.points.count >= 3 }
        if !closedChains.isEmpty {
            for chain in closedChains {
                path.move(to: chain.points[0])
                for pt in chain.points.dropFirst() { path.addLine(to: pt) }
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
private func drawWallDepthShadowCG(_ doc: DrawingDocument,
                                   context: CGContext,
                                   tightAlpha: CGFloat = 0.88,
                                   ambientAlpha: CGFloat = 0.55) {
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

    // Shadow source: big rect with the footprint as an even-odd hole.
    // With room areas the hole stays the footprint bbox: individual room subpaths
    // would cast spurious shadow at internal boundaries where rooms touch or
    // overlap, and the clip above already constrains to the real building shape.
    // For walls-only documents the footprint polygons are disjoint closed chains,
    // so the actual outline is used and the gradient follows slanted perimeters.
    let expand: CGFloat = 2000
    let bigRect = UIBezierPath(rect: CGRect(
        x: bounds.minX - expand, y: bounds.minY - expand,
        width: bounds.width + expand * 2, height: bounds.height + expand * 2
    ))
    if doc.roomAreas.isEmpty {
        bigRect.append(footprint)
    } else {
        bigRect.append(UIBezierPath(rect: bounds))   // single clean rectangular hole
    }
    bigRect.usesEvenOddFillRule = true

    UIGraphicsPushContext(context)

    // Pass 1 — sharp layer: strong, tight shadow right at the wall edge
    context.saveGState()
    context.setShadow(offset: .zero, blur: blurTight,
                      color: UIColor.black.withAlphaComponent(tightAlpha).cgColor)
    UIColor.black.setFill()
    bigRect.fill()
    context.restoreGState()

    // Pass 2 — ambient layer: softer, wider depth gradient
    context.saveGState()
    context.setShadow(offset: .zero, blur: blurAmbient,
                      color: UIColor.black.withAlphaComponent(ambientAlpha).cgColor)
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
