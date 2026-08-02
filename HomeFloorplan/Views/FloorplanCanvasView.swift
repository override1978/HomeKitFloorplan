import SwiftUI

struct FloorplanCanvasView<OverlayLayer: View, EditLayer: View, MarkerContent: View, EmptyContent: View>: View {
    let image: UIImage
    let containerSize: CGSize
    let showOverlayLayer: Bool
    let showEditLayer: Bool
    let showMarkers: Bool
    let markerItems: [FloorplanMarkerRenderItem]
    let collisionOffsets: [UUID: CGSize]
    let overlayLayer: (CGSize, CGRect) -> OverlayLayer
    let editLayer: (CGSize, CGRect) -> EditLayer
    let markerContent: (FloorplanMarkerRenderItem, CGRect, CGSize) -> MarkerContent
    let emptyContent: () -> EmptyContent

    init(
        image: UIImage,
        containerSize: CGSize,
        showOverlayLayer: Bool,
        showEditLayer: Bool,
        showMarkers: Bool,
        markerItems: [FloorplanMarkerRenderItem],
        collisionOffsets: [UUID: CGSize],
        @ViewBuilder overlayLayer: @escaping (CGSize, CGRect) -> OverlayLayer,
        @ViewBuilder editLayer: @escaping (CGSize, CGRect) -> EditLayer,
        @ViewBuilder markerContent: @escaping (FloorplanMarkerRenderItem, CGRect, CGSize) -> MarkerContent,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent
    ) {
        self.image = image
        self.containerSize = containerSize
        self.showOverlayLayer = showOverlayLayer
        self.showEditLayer = showEditLayer
        self.showMarkers = showMarkers
        self.markerItems = markerItems
        self.collisionOffsets = collisionOffsets
        self.overlayLayer = overlayLayer
        self.editLayer = editLayer
        self.markerContent = markerContent
        self.emptyContent = emptyContent
    }

    var body: some View {
        let rect = FloorplanCanvasGeometry.imageRect(
            imageSize: image.size,
            container: containerSize
        )

        ZStack(alignment: .topLeading) {
            Color.clear

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if showOverlayLayer {
                overlayLayer(containerSize, rect)
            }

            if showEditLayer {
                editLayer(containerSize, rect)
            }

            Group {
                if showMarkers {
                    FloorplanMarkerLayer(
                        items: markerItems,
                        imageRect: rect,
                        collisionOffsets: collisionOffsets
                    ) { item, collisionOffset in
                        markerContent(item, rect, collisionOffset)
                    } emptyContent: {
                        emptyContent()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showMarkers)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }
}

enum FloorplanCanvasGeometry {

    /// Spazio riservato in alto alla chrome flottante.
    ///
    /// Serve perché in Ambiente e Sicurezza sotto la barra compaiono altre
    /// superfici — chip filtro, pill antifurto — che finivano sopra il disegno.
    /// È una **costante**, non una misura: applicata qui dentro non cambia mai a
    /// runtime, quindi non invalida nulla e non ricrea l'anello che avevamo
    /// appena smontato con `topBarHeight`. È costante anche fra le modalità di
    /// proposito: farla dipendere dalla modalità attiva significherebbe far
    /// cambiare dimensione alla planimetria a ogni cambio, un movimento in più
    /// da guardare per un guadagno nullo.
    ///
    /// Unico numero da ritoccare se il margine risulta troppo o troppo poco:
    /// la barra da sola misura una sessantina di punti, un banner ne aggiunge
    /// una quarantina.
    static let chromeTopInset: CGFloat = 88

    /// Inscrive l'immagine nel contenitore, riservando `topInset` in alto.
    ///
    /// Il margine è un parametro con valore di default, non un termine che i
    /// chiamanti sommano per conto loro: renderer, marker, overlay, collisioni e
    /// risolutore dei tap passano tutti di qui, quindi lo ereditano senza poter
    /// divergere. È la differenza con `topBarHeight`, che viveva sommato in un
    /// punto e sottratto in un altro. Passare `topInset: 0` isola l'inscrizione
    /// pura, che è come i test la verificano.
    static func imageRect(imageSize: CGSize,
                          container: CGSize,
                          topInset: CGFloat = chromeTopInset) -> CGRect {
        let available = CGSize(width: container.width,
                               height: max(container.height - topInset, 1))
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = available.width / available.height
        var size = available
        if imageAspect > containerAspect {
            size.height = available.width / imageAspect
        } else {
            size.width = available.height * imageAspect
        }
        let origin = CGPoint(
            x: (available.width - size.width) / 2,
            y: topInset + (available.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }
}
