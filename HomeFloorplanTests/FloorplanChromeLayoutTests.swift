import Foundation
import CoreGraphics
import Testing
@testable import HomeFloorplan

/// Bloccano il contratto di `FloorplanChromeLayout`: il margine superiore è
/// una costante composta di costanti, il legacy coincide col vecchio
/// `chromeTopInset`, e la geometria eredita il margine del layout senza
/// poter divergere dal renderer.
@Suite("FloorplanChromeLayout — margine per configurazione")
struct FloorplanChromeLayoutTests {

    @Test("Il layout legacy coincide col margine base storico")
    func legacyMatchesBaseInset() {
        #expect(FloorplanChromeLayout.legacy.topInset == FloorplanCanvasGeometry.chromeTopInset)
        #expect(FloorplanChromeLayout.legacy.topInset == 88)
    }

    @Test("La barra di stato unificata aggiunge la propria altezza al margine")
    func statusStripAddsHeight() {
        var layout = FloorplanChromeLayout.legacy
        layout.hasUnifiedStatusStrip = true
        #expect(layout.topInset ==
                FloorplanCanvasGeometry.chromeTopInset + FloorplanChromeLayout.statusStripHeight)
    }

    @Test("imageRect col margine del layout sposta l'origine di conseguenza")
    func imageRectHonorsLayoutInset() {
        let imageSize = CGSize(width: 200, height: 100)
        let container = CGSize(width: 400, height: 400)

        var layout = FloorplanChromeLayout.legacy
        layout.hasUnifiedStatusStrip = true

        let legacyRect = FloorplanCanvasGeometry.imageRect(
            imageSize: imageSize,
            container: container,
            topInset: FloorplanChromeLayout.legacy.topInset
        )
        let stripRect = FloorplanCanvasGeometry.imageRect(
            imageSize: imageSize,
            container: container,
            topInset: layout.topInset
        )

        // Stessa inscrizione, area disponibile ridotta dell'altezza della
        // barra: l'immagine non può che stare più in basso e (se vincolata
        // in altezza) essere non più grande.
        #expect(stripRect.origin.y > legacyRect.origin.y)
        #expect(stripRect.origin.y >= layout.topInset)
        #expect(stripRect.width <= legacyRect.width)
    }

    @Test("Il tap resolver col margine del layout combacia col renderer")
    func tapResolverMatchesRenderer() {
        let imageSize = CGSize(width: 200, height: 100)
        let container = CGSize(width: 400, height: 400)

        var layout = FloorplanChromeLayout.legacy
        layout.hasUnifiedStatusStrip = true

        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: imageSize,
            container: container,
            topInset: layout.topInset
        )

        // Tap esattamente al centro dell'immagine renderizzata → il resolver
        // deve restituire il punto normalizzato (0.5, 0.5).
        let resolver = FloorplanRoomTapResolver(
            linkedRooms: [],
            imageSize: imageSize,
            containerSize: container,
            effectiveScale: 1,
            effectiveOffset: .zero,
            topInset: layout.topInset
        )
        let resolution = resolver.resolve(tapLocation: CGPoint(x: rect.midX, y: rect.midY))
        #expect(resolution != nil)
        #expect(abs((resolution?.markerPosition.x ?? 0) - 0.5) < 0.001)
        #expect(abs((resolution?.markerPosition.y ?? 0) - 0.5) < 0.001)
    }
}
