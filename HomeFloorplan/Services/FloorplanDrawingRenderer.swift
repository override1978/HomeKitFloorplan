import SwiftUI
import UIKit

// MARK: - FloorplanDrawingRenderer

/// Il rendering della planimetria, fuori dalla vista che lo ospitava.
///
/// Stava dentro `DrawingFloorplanSheet` come metodo privato, ed era
/// raggiungibile solo da chi aveva l'editor aperto. Finché l'unico momento in
/// cui serviva un raster era il salvataggio andava bene; con due varianti per
/// planimetria non basta più, perché le planimetrie disegnate prima non hanno
/// la seconda e nessuno può produrgliela senza riaprire l'editor. Chiedere
/// all'utente di riesportare ogni volta che cambia qualcosa dentro non è una
/// migrazione: è un debito girato a chi non l'ha contratto.
///
/// Il documento vettoriale è persistito in `drawingDocumentJSON`, quindi da qui
/// si può ridisegnare qualunque planimetria in qualunque stile, quando serve.
enum FloorplanDrawingRenderer {

    /// La dimensione di riferimento dell'export quando non c'è un editor
    /// aperto a dire quanto è grande la sua area di disegno.
    static let defaultViewportSize = CGSize(width: 390, height: 844)

    static func renderAdaptive(_ doc: DrawingDocument,
                               visualStyle: DrawingVisualExportStyle,
                               exportRotation: DrawingExportRotation,
                               exteriorFillColorIndex: Int,
                               viewportSize: CGSize,
                               transparentBackground: Bool) -> (UIImage, [LinkedRoom]) {
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
            // sRGB esplicito — vedi nota nell'altro renderer.
            fmt.preferredRange = .standard
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
        let rotatedDrawingW = exportRotation.quarterTurns.isMultiple(of: 2) ? drawingW : drawingH
        let rotatedDrawingH = exportRotation.quarterTurns.isMultiple(of: 2) ? drawingH : drawingW
        let longestSide = max(rotatedDrawingW, rotatedDrawingH)
        guard longestSide > 0 else { return (blankImage(), []) }

        let margin = longestSide * marginFraction
        let paddedW = rotatedDrawingW + margin * 2
        let paddedH = rotatedDrawingH + margin * 2
        let scaleFactor = min(outputW / paddedW, outputH / paddedH)

        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let rotationAngle = CGFloat(exportRotation.quarterTurns) * (.pi / 2)

        func projectedPoint(_ point: CGPoint) -> CGPoint {
            let dx = point.x - centerX
            let dy = point.y - centerY
            let rotatedX: CGFloat
            let rotatedY: CGFloat

            switch exportRotation {
            case .asDrawn:
                rotatedX = dx
                rotatedY = dy
            case .clockwise:
                rotatedX = -dy
                rotatedY = dx
            case .upsideDown:
                rotatedX = -dx
                rotatedY = -dy
            case .counterClockwise:
                rotatedX = dy
                rotatedY = -dx
            }

            return CGPoint(
                x: outputW / 2 + rotatedX * scaleFactor,
                y: outputH / 2 + rotatedY * scaleFactor
            )
        }

        func normalizedPoint(_ point: CGPoint) -> CodablePoint {
            let projected = projectedPoint(point)
            return CodablePoint(
                x: Double(projected.x / outputW),
                y: Double(projected.y / outputH)
            )
        }

        func normalizedRect(for points: [CGPoint]) -> CodableRect {
            let projectedPoints = points.map(projectedPoint)
            let xs = projectedPoints.map(\.x)
            let ys = projectedPoints.map(\.y)
            let minPX = xs.min() ?? 0
            let maxPX = xs.max() ?? minPX
            let minPY = ys.min() ?? 0
            let maxPY = ys.max() ?? minPY
            return CodableRect(
                x: Double(minPX / outputW),
                y: Double(minPY / outputH),
                width: Double((maxPX - minPX) / outputW),
                height: Double((maxPY - minPY) / outputH)
            )
        }

        func drawCenteredText(_ text: String,
                              at point: CGPoint,
                              font: UIFont,
                              color: UIColor,
                              uppercased: Bool = false) {
            let value = (uppercased ? text.uppercased() : text) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let textSize = value.size(withAttributes: attributes)
            value.draw(
                at: CGPoint(x: point.x - textSize.width / 2, y: point.y - textSize.height / 2),
                withAttributes: attributes
            )
        }

        func drawUprightExportText(in context: CGContext) {
            guard exportRotation != .asDrawn else { return }

            UIGraphicsPushContext(context)
            let isDark = visualStyle == .architecturalDark

            for area in doc.roomAreas {
                let color: UIColor
                if isDark {
                    color = UIColor(red: 0.78, green: 0.82, blue: 0.86, alpha: 0.72)
                } else {
                    let cgColor = RoomLabelPalette.color(at: area.colorIndex)
                    color = UIColor(cgColor: cgColor.copy(alpha: 0.55) ?? cgColor)
                }

                drawCenteredText(
                    area.name,
                    at: projectedPoint(area.centroid),
                    font: .systemFont(ofSize: (isDark ? 15 : 14) * scaleFactor, weight: .semibold),
                    color: color,
                    uppercased: true
                )
            }

            for item in doc.furnitureItems where item.showsName {
                let color = isDark
                    ? UIColor(red: 0.78, green: 0.82, blue: 0.86, alpha: 0.58)
                    : UIColor(white: 0.35, alpha: 1)
                drawCenteredText(
                    item.name,
                    at: projectedPoint(CGPoint(x: item.rect.midX, y: item.rect.midY)),
                    font: .systemFont(ofSize: (isDark ? 11 : 12) * scaleFactor, weight: .medium),
                    color: color,
                    uppercased: isDark
                )
            }

            for label in doc.roomLabels {
                let center = projectedPoint(label.position)
                let font = UIFont.systemFont(ofSize: 13 * scaleFactor, weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.white
                ]
                let nsString = label.name.uppercased() as NSString
                let textSize = nsString.size(withAttributes: attributes)
                let hPad = 10 * scaleFactor
                let vPad = 6 * scaleFactor
                let pillSize = CGSize(width: textSize.width + hPad * 2, height: textSize.height + vPad * 2)
                let pillRect = CGRect(
                    x: center.x - pillSize.width / 2,
                    y: center.y - pillSize.height / 2,
                    width: pillSize.width,
                    height: pillSize.height
                )
                UIColor(cgColor: RoomLabelPalette.color(at: label.colorIndex)).setFill()
                UIBezierPath(roundedRect: pillRect, cornerRadius: pillSize.height / 2).fill()
                nsString.draw(
                    at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
                    withAttributes: attributes
                )
            }

            UIGraphicsPopContext()
        }

        let linkedRooms: [LinkedRoom] = doc.roomAreas.compactMap { area in
            guard let hmUUID = area.hmRoomUUID else { return nil }
            let normalizedPoints: [CodablePoint]? = area.points.map { pts in
                pts.map(normalizedPoint)
            }
            return LinkedRoom(
                hmRoomUUID: hmUUID,
                name: area.name,
                normalizedRect: normalizedRect(for: area.effectivePoints),
                normalizedPoints: normalizedPoints
            )
        }

        let outputSize = CGSize(width: outputW, height: outputH)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        // sRGB esplicito: i colori baked devono coincidere esattamente con le
        // costanti renderizzate live da SwiftUI (evita la "cucitura" visibile
        // dove lo sfondo della view incontra il bordo immagine).
        fmt.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: fmt)
        let outputBackgroundColor: UIColor = {
            if visualStyle == .architecturalDark {
                return DrawingVisualExportStyle.architecturalDarkBackgroundUIColor
            }
            if exteriorFillColorIndex >= 0,
               let palette = ExteriorFillPalette(rawValue: exteriorFillColorIndex) {
                return UIColor(cgColor: palette.cgColor)
            }
            return UIColor.white
        }()

        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            if !transparentBackground {
                cgCtx.setFillColor(outputBackgroundColor.cgColor)
                cgCtx.fill(CGRect(origin: .zero, size: outputSize))
            }
            cgCtx.saveGState()
            cgCtx.translateBy(x: outputW / 2, y: outputH / 2)
            cgCtx.rotate(by: rotationAngle)
            cgCtx.scaleBy(x: scaleFactor, y: scaleFactor)
            cgCtx.translateBy(x: -centerX, y: -centerY)
            renderDocument(doc,
                           in: cgCtx,
                           canvasSize: DrawingDocument.canvasSize,
                           exteriorFillColorIndex: exteriorFillColorIndex,
                           visualStyle: visualStyle,
                           drawText: exportRotation == .asDrawn,
                           transparentBackground: transparentBackground)
            cgCtx.restoreGState()
            drawUprightExportText(in: cgCtx)
        }
        return (image, linkedRooms)
    }
}
