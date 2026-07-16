import SwiftUI

struct FloorplanViewportState {
    var zoomScale: CGFloat = 1.0
    var zoomOffset: CGSize = .zero
    var liveScale: CGFloat = 1.0
    var liveOffset: CGSize = .zero

    var effectiveScale: CGFloat {
        zoomScale * liveScale
    }

    var effectiveOffset: CGSize {
        CGSize(
            width: zoomOffset.width + liveOffset.width,
            height: zoomOffset.height + liveOffset.height
        )
    }

    mutating func updateLiveScale(_ value: CGFloat) {
        liveScale = value
    }

    mutating func finishMagnification(_ value: CGFloat, floorplanID: UUID) {
        zoomScale = clampedScale(zoomScale * value)
        liveScale = 1.0
        if zoomScale <= 1.01 {
            withAnimation(.spring(response: 0.4)) {
                zoomScale = 1.0
                zoomOffset = .zero
            }
        }
        save(floorplanID: floorplanID)
    }

    mutating func updateLiveOffset(_ translation: CGSize) {
        guard effectiveScale > 1.01 else { return }
        liveOffset = translation
    }

    mutating func finishDrag(_ translation: CGSize, container: CGSize, floorplanID: UUID) {
        guard zoomScale > 1.01 else {
            liveOffset = .zero
            return
        }
        zoomOffset = CGSize(
            width: zoomOffset.width + translation.width,
            height: zoomOffset.height + translation.height
        )
        liveOffset = .zero
        clampOffset(in: container)
        save(floorplanID: floorplanID)
    }

    mutating func reset(floorplanID: UUID) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            zoomScale = 1.0
            zoomOffset = .zero
            liveScale = 1.0
            liveOffset = .zero
        }
        save(floorplanID: floorplanID)
    }

    mutating func restore(floorplanID: UUID) {
        let ud = UserDefaults.standard
        guard ud.object(forKey: Self.zoomScaleKey(floorplanID: floorplanID)) != nil else { return }
        withTransaction(Transaction(animation: nil)) {
            zoomScale = CGFloat(ud.double(forKey: Self.zoomScaleKey(floorplanID: floorplanID)))
            zoomOffset = CGSize(
                width: CGFloat(ud.double(forKey: Self.zoomOffsetXKey(floorplanID: floorplanID))),
                height: CGFloat(ud.double(forKey: Self.zoomOffsetYKey(floorplanID: floorplanID)))
            )
        }
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, 1.0), 4.0)
    }

    private mutating func clampOffset(in container: CGSize) {
        let extraW = container.width * (zoomScale - 1) / 2
        let extraH = container.height * (zoomScale - 1) / 2
        let maxX = max(0, extraW)
        let maxY = max(0, extraH)

        let clampedX = min(maxX, max(-maxX, zoomOffset.width))
        let clampedY = min(maxY, max(-maxY, zoomOffset.height))

        if clampedX != zoomOffset.width || clampedY != zoomOffset.height {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                zoomOffset = CGSize(width: clampedX, height: clampedY)
            }
        }
    }

    private func save(floorplanID: UUID) {
        let ud = UserDefaults.standard
        ud.set(Double(zoomScale), forKey: Self.zoomScaleKey(floorplanID: floorplanID))
        ud.set(Double(zoomOffset.width), forKey: Self.zoomOffsetXKey(floorplanID: floorplanID))
        ud.set(Double(zoomOffset.height), forKey: Self.zoomOffsetYKey(floorplanID: floorplanID))
    }

    private static func zoomScaleKey(floorplanID: UUID) -> String {
        "zoom_scale_\(floorplanID.uuidString)"
    }

    private static func zoomOffsetXKey(floorplanID: UUID) -> String {
        "zoom_offsetX_\(floorplanID.uuidString)"
    }

    private static func zoomOffsetYKey(floorplanID: UUID) -> String {
        "zoom_offsetY_\(floorplanID.uuidString)"
    }
}
