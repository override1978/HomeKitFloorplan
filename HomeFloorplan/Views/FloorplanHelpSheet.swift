import SwiftUI

struct FloorplanHelpSheet: View {
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(String(localized: "floorplan.help.subtitle",
                                defaultValue: "Use the floorplan as a live map for HomeKit controls, scenes, overlays, and setup."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 12) {
                        helpRow(
                            icon: "pencil",
                            title: String(localized: "floorplan.help.edit.title", defaultValue: "Edit mode"),
                            message: String(localized: "floorplan.help.edit.message", defaultValue: "Tap Edit to place and manage accessory markers on the floorplan.")
                        )
                        helpRow(
                            icon: "rectangle.dashed",
                            title: String(localized: "floorplan.help.add.title", defaultValue: "Add markers"),
                            message: String(localized: "floorplan.help.add.message", defaultValue: "In edit mode, tap a room area to add an accessory there. If no room areas exist, use + in the top-right corner.")
                        )
                        helpRow(
                            icon: "hand.tap",
                            title: String(localized: "floorplan.help.editMarker.title", defaultValue: "Edit a marker"),
                            message: String(localized: "floorplan.help.editMarker.message", defaultValue: "In edit mode, tap a marker to rename it, change its icon, recenter it, or remove it from the floorplan.")
                        )
                        helpRow(
                            icon: "bolt.fill",
                            title: String(localized: "floorplan.help.action.title", defaultValue: "Run quick actions"),
                            message: String(localized: "floorplan.help.action.message", defaultValue: "Outside edit mode, tap a marker to run its primary action when supported.")
                        )
                        helpRow(
                            icon: "rectangle.expand.vertical",
                            title: String(localized: "floorplan.help.detail.title", defaultValue: "Open details"),
                            message: String(localized: "floorplan.help.detail.message", defaultValue: "Long-press a marker to open the full accessory control view.")
                        )
                        helpRow(
                            icon: "ipad",
                            title: String(localized: "floorplan.help.foreground.title", defaultValue: "When to keep it open"),
                            message: String(localized: "floorplan.help.foreground.message", defaultValue: "Keep HomeFloorplan in the foreground while editing, monitoring live dashboards, collecting sensor context, or letting AI suggestions and habits learn from recent activity. HomeKit automations saved to Apple Home continue to run without keeping the app open.")
                        )
                    }
                }
                .padding(24)
            }
            .navigationTitle(String(localized: "floorplan.help.title", defaultValue: "Floorplan basics"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "common.done", defaultValue: "Done")) {
                        onDone()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func helpRow(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(BrandColor.primary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
