import SwiftUI

struct FloorplanEmptyMarkersHint: View {
    let hasAreas: Bool
    let onAddAccessory: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: hasAreas ? "rectangle.dashed" : "plus.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text(String(localized: "floorplan.emptyMarkers.title", defaultValue: "No accessories placed"))
                .font(.headline)

            if hasAreas {
                Text(String(localized: "floorplan.emptyMarkers.roomHint", defaultValue: "Tap a room area on the floorplan to add the first HomeKit accessory."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            } else {
                Text(String(localized: "floorplan.emptyMarkers.freeHint", defaultValue: "Tap + in the top-right corner to add the first HomeKit accessory to the floorplan."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "leaf.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.top, 1)
                    Text(String(localized: "floorplan.editor.hint.ambiente",
                                defaultValue: "Draw room areas (pencil → Room Area) and link them to HomeKit to unlock the **Environment** layer."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.08))
                )
                .padding(.horizontal, 4)

                Button {
                    onAddAccessory()
                } label: {
                    Label(String(localized: "floorplan.addAccessory", defaultValue: "Add accessory"), systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(.tint)
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
    }
}
