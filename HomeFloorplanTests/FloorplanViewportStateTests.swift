import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Characterization test della matematica di zoom/pan in `FloorplanViewportState`.
/// I metodi persistono su UserDefaults (chiave per-floorplan): ogni test usa un
/// UUID nuovo per restare isolato.
@Suite("FloorplanViewportState — clamp e composizione scala/offset")
struct FloorplanViewportStateTests {

    @Test("Stato di default: scala 1, offset zero")
    func defaults() {
        let state = FloorplanViewportState()
        #expect(state.effectiveScale == 1)
        #expect(state.effectiveOffset == .zero)
    }

    @Test("effectiveScale e effectiveOffset compongono live + committed")
    func effectiveValuesCompose() {
        var state = FloorplanViewportState()
        state.zoomScale = 2
        state.liveScale = 1.5
        state.zoomOffset = CGSize(width: 10, height: 5)
        state.liveOffset = CGSize(width: 3, height: 4)
        #expect(state.effectiveScale == 3)                       // 2 * 1.5
        #expect(state.effectiveOffset == CGSize(width: 13, height: 9))
    }

    @Test("finishMagnification applica la scala e azzera la live")
    func finishMagnificationCommitsScale() {
        var state = FloorplanViewportState()
        state.finishMagnification(2, floorplanID: UUID())
        #expect(state.zoomScale == 2)
        #expect(state.liveScale == 1)
        #expect(state.effectiveScale == 2)
    }

    @Test("La scala è clampata a un massimo di 4×")
    func scaleIsClampedToMax() {
        var state = FloorplanViewportState()
        state.finishMagnification(10, floorplanID: UUID())
        #expect(state.zoomScale == 4)
    }

    @Test("Scendere a scala ~1 resetta anche l'offset")
    func collapsingToOneResetsOffset() {
        var state = FloorplanViewportState()
        state.zoomOffset = CGSize(width: 30, height: 30)
        state.zoomScale = 2
        state.finishMagnification(0.1, floorplanID: UUID()) // 2*0.1=0.2 → clamp a 1
        #expect(state.zoomScale == 1)
        #expect(state.zoomOffset == .zero)
    }

    @Test("updateLiveOffset viene ignorato quando non c'è zoom")
    func liveOffsetIgnoredWithoutZoom() {
        var state = FloorplanViewportState()
        state.updateLiveOffset(CGSize(width: 50, height: 50))
        #expect(state.liveOffset == .zero)
    }

    @Test("updateLiveOffset viene applicato quando c'è zoom attivo")
    func liveOffsetAppliedWithZoom() {
        var state = FloorplanViewportState()
        state.zoomScale = 2
        state.updateLiveOffset(CGSize(width: 50, height: 50))
        #expect(state.liveOffset == CGSize(width: 50, height: 50))
    }

    @Test("reset riporta tutto ai valori di default")
    func resetClearsEverything() {
        var state = FloorplanViewportState()
        state.zoomScale = 3
        state.zoomOffset = CGSize(width: 20, height: 20)
        state.liveScale = 1.2
        state.liveOffset = CGSize(width: 5, height: 5)
        state.reset(floorplanID: UUID())
        #expect(state.zoomScale == 1)
        #expect(state.zoomOffset == .zero)
        #expect(state.liveScale == 1)
        #expect(state.liveOffset == .zero)
    }

    @Test("finishDrag senza zoom non muove l'offset committed")
    func finishDragWithoutZoomKeepsOffset() {
        var state = FloorplanViewportState()
        state.finishDrag(CGSize(width: 40, height: 40), container: CGSize(width: 100, height: 100), floorplanID: UUID())
        #expect(state.zoomOffset == .zero)
        #expect(state.liveOffset == .zero)
    }
}
