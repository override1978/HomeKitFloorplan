import SwiftUI

// MARK: - NormalizedPoint (type alias used across the overlay system)

// NormalizedPoint is already defined in the project (MarkerSizePreference.swift or similar).
// This file only defines FloorplanCoordinateHelper.

// MARK: - FloorplanCoordinateHelper

/// Converts between normalized [0, 1] coordinates (stored in `LinkedRoom` and
/// `PlacedAccessory`) and screen-space points/rects within a given `imageRect`.
///
/// Promoted from the private `imageRect(imageSize:container:)` function that
/// already lives in `FloorplanEditorView`. All overlay views share this
/// single source of truth so room polygons always align with the PNG.
struct FloorplanCoordinateHelper {

    /// The screen-space rectangle the floorplan image occupies (aspect-fitted,
    /// centred inside the container). Matches what `FloorplanEditorView` renders.
    let imageRect: CGRect

    // MARK: Point / Rect conversion

    /// Converts a normalized point `[0, 1]` to a screen-space `CGPoint`.
    func screenPoint(from normalized: CodablePoint) -> CGPoint {
        CGPoint(
            x: imageRect.origin.x + normalized.x * imageRect.width,
            y: imageRect.origin.y + normalized.y * imageRect.height
        )
    }

    /// Converts a `NormalizedPoint` (positionX / positionY on `PlacedAccessory`)
    /// to a screen-space `CGPoint`.
    func screenPoint(from normalized: NormalizedPoint) -> CGPoint {
        CGPoint(
            x: imageRect.origin.x + normalized.x * imageRect.width,
            y: imageRect.origin.y + normalized.y * imageRect.height
        )
    }

    /// Converts a normalized `CodableRect` to a screen-space `CGRect`.
    func screenRect(from normalized: CodableRect) -> CGRect {
        CGRect(
            x: imageRect.origin.x + normalized.x * imageRect.width,
            y: imageRect.origin.y + normalized.y * imageRect.height,
            width: normalized.width  * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }

    // MARK: Room polygon path

    /// Builds a SwiftUI `Path` that traces the room boundary in screen space.
    /// Uses `normalizedPoints` when available (polygon), falls back to
    /// `normalizedRect` (rectangle) for legacy rooms.
    func overlayPath(for room: LinkedRoom) -> Path {
        if let pts = room.normalizedPoints, pts.count >= 3 {
            var path = Path()
            path.move(to: screenPoint(from: pts[0]))
            for pt in pts.dropFirst() {
                path.addLine(to: screenPoint(from: pt))
            }
            path.closeSubpath()
            return path
        } else {
            return Path(screenRect(from: room.normalizedRect))
        }
    }

    /// Returns the centroid of the room shape in screen space,
    /// used to position badges / labels over each room.
    func centroid(for room: LinkedRoom) -> CGPoint {
        if let pts = room.normalizedPoints, pts.count >= 3 {
            let sumX = pts.reduce(0.0) { $0 + $1.x }
            let sumY = pts.reduce(0.0) { $0 + $1.y }
            let n = Double(pts.count)
            return screenPoint(from: CodablePoint(x: sumX / n, y: sumY / n))
        } else {
            let r = room.normalizedRect
            return screenPoint(from: CodablePoint(
                x: r.x + r.width  / 2,
                y: r.y + r.height / 2
            ))
        }
    }

    // MARK: Factory

    /// Computes `imageRect` from an image size and container size using
    /// the same aspect-fit algorithm as `FloorplanEditorView.imageRect(imageSize:container:)`.
    static func make(imageSize: CGSize, container: CGSize) -> FloorplanCoordinateHelper {
        let imageAspect     = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        var size = container
        if imageAspect > containerAspect {
            size.height = container.width / imageAspect
        } else {
            size.width  = container.height * imageAspect
        }
        let origin = CGPoint(
            x: (container.width  - size.width)  / 2,
            y: (container.height - size.height) / 2
        )
        return FloorplanCoordinateHelper(imageRect: CGRect(origin: origin, size: size))
    }
}
