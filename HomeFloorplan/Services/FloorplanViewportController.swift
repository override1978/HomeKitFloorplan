import SwiftUI

struct FloorplanViewportController {
    @Binding var viewport: FloorplanViewportState
    let floorplanID: UUID

    var effectiveScale: CGFloat {
        viewport.effectiveScale
    }

    var effectiveOffset: CGSize {
        viewport.effectiveOffset
    }

    func restore() {
        viewport.restore(floorplanID: floorplanID)
    }

    func reset() {
        viewport.reset(floorplanID: floorplanID)
    }

    /// Zoom semantico su una stanza (redesign iPhone).
    func focus(on rect: CGRect, in container: CGSize) {
        viewport.focus(on: rect, in: container, floorplanID: floorplanID)
    }

    func zoomPanGesture(in container: CGSize) -> some Gesture {
        let magnify = MagnificationGesture()
            .onChanged { value in
                viewport.updateLiveScale(value)
            }
            .onEnded { value in
                viewport.finishMagnification(value, floorplanID: floorplanID)
            }

        let drag = DragGesture(minimumDistance: 10)
            .onChanged { value in
                viewport.updateLiveOffset(value.translation)
            }
            .onEnded { value in
                viewport.finishDrag(value.translation, container: container, floorplanID: floorplanID)
            }

        return magnify.simultaneously(with: drag)
    }
}
