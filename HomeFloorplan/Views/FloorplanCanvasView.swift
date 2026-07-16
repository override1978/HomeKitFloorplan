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
    static func imageRect(imageSize: CGSize, container: CGSize) -> CGRect {
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        var size = container
        if imageAspect > containerAspect {
            size.height = container.width / imageAspect
        } else {
            size.width = container.height * imageAspect
        }
        let origin = CGPoint(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2
        )
        return CGRect(origin: origin, size: size)
    }
}
