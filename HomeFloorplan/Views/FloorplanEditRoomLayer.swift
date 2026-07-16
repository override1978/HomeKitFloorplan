import SwiftUI

struct FloorplanEditRoomLayer: View {
    let rooms: [LinkedRoom]
    let containerSize: CGSize
    let imageRect: CGRect
    let highlightedRoomID: UUID?

    var body: some View {
        let helper = FloorplanCoordinateHelper(imageRect: imageRect)

        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for room in rooms {
                    let path = helper.overlayPath(for: room)
                    let isHighlighted = room.hmRoomUUID == highlightedRoomID
                    let fill = isHighlighted
                        ? BrandColor.primary.opacity(0.18)
                        : BrandColor.primary.opacity(0.055)
                    let stroke = isHighlighted
                        ? BrandColor.primary.opacity(0.72)
                        : BrandColor.primary.opacity(0.24)

                    context.fill(path, with: .color(fill))
                    context.stroke(
                        path,
                        with: .color(stroke),
                        style: StrokeStyle(lineWidth: isHighlighted ? 2.0 : 1.0, dash: [6, 5])
                    )
                }
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .allowsHitTesting(false)

            ForEach(rooms, id: \.hmRoomUUID) { room in
                let center = helper.centroid(for: room)
                let isHighlighted = room.hmRoomUUID == highlightedRoomID

                Text(room.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(isHighlighted ? .white : BrandColor.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isHighlighted ? BrandColor.primary.opacity(0.92) : Color(.systemBackground).opacity(0.78))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(BrandColor.primary.opacity(isHighlighted ? 0.0 : 0.24), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    .position(center)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }
}
