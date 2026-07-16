import SwiftUI

struct FloorplanMarkerCollisionResolver {
    let markers: [PlacedAccessory]
    let isEditing: Bool
    let effectiveScale: CGFloat

    func offsets(in imageRect: CGRect) -> [UUID: CGSize] {
        guard !isEditing, markers.count > 1 else { return [:] }

        let scale = max(effectiveScale, 0.01)
        let threshold = 32 / scale
        let markerPoints = markers.map { marker in
            (
                marker: marker,
                point: CGPoint(
                    x: imageRect.origin.x + marker.position.x * imageRect.width,
                    y: imageRect.origin.y + marker.position.y * imageRect.height
                )
            )
        }
        var offsets: [UUID: CGSize] = [:]

        for entry in markerPoints {
            let nearbyMarkers = markerPoints
                .filter { candidate in
                    hypot(candidate.point.x - entry.point.x, candidate.point.y - entry.point.y) <= threshold
                }
                .map(\.marker)
                .sorted { $0.id.uuidString < $1.id.uuidString }

            guard nearbyMarkers.count > 1,
                  let index = nearbyMarkers.firstIndex(where: { $0.id == entry.marker.id }) else {
                continue
            }

            let count = CGFloat(nearbyMarkers.count)
            let angle = (2 * CGFloat.pi * CGFloat(index) / count) - (.pi / 2)
            let radius = min(24, 10 + count * 3) / scale

            offsets[entry.marker.id] = CGSize(
                width: cos(angle) * radius,
                height: sin(angle) * radius
            )
        }

        return offsets
    }
}
