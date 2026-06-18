import SwiftUI
import HomeKit

/// Sheet per scegliere uno o più accessori HomeKit da aggiungere al floorplan.
struct AccessoryPickerSheet: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(\.dismiss) private var dismiss

    /// UUID degli accessori già piazzati: vengono mostrati ma disabilitati.
    let alreadyPlaced: Set<UUID>

    /// Optional: UUIDs of HMRooms drawn on this floorplan — shown first under a dedicated header.
    var preferredRoomUUIDs: Set<UUID> = []

    /// Optional contextual title, used when the picker is opened from a specific room.
    var title: String = "Aggiungi accessori"

    /// Callback con gli accessori scelti (uno o più).
    let onPick: ([HMAccessory]) -> Void

    @State private var searchText: String = ""
    @State private var selected: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                // Preferred rooms (linked to floorplan areas) shown first
                ForEach(preferredRooms, id: \.0.uniqueIdentifier) { room, accessories in
                    Section("★ \(room.name)") {
                        ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                            row(for: accessory)
                        }
                    }
                }
                // Remaining rooms
                ForEach(otherRooms, id: \.0.uniqueIdentifier) { room, accessories in
                    Section(room.name) {
                        ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                            row(for: accessory)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Cerca accessorio")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let accessories = collectSelected()
                        onPick(accessories)
                        dismiss()
                    } label: {
                        if selected.isEmpty {
                            Text("Aggiungi")
                        } else {
                            Text("Aggiungi (\(selected.count))")
                        }
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
    }

    private func row(for accessory: HMAccessory) -> some View {
        // Capture only the stable values outside; read reactive state inside the label
        let isPlaced = alreadyPlaced.contains(accessory.uniqueIdentifier)
        let adapter  = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
        let uuid     = accessory.uniqueIdentifier
        let displayName = Self.strippedName(accessory.name, roomName: accessory.room?.name)
        let appearance = AccessoryAppearance.from(adapter)
        let iconColor: AnyShapeStyle = isPlaced
            ? AnyShapeStyle(Color.secondary)
            : AnyShapeStyle(appearance.statusColor)

        return Button {
            guard !isPlaced else { return }
            if selected.contains(uuid) {
                selected.remove(uuid)
            } else {
                selected.insert(uuid)
            }
        } label: {
            // Read `selected` inside the label closure so SwiftUI tracks the dependency
            let isSelected = selected.contains(uuid)
            HStack {
                AccessoryIconView(iconName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading) {
                    Text(displayName)
                        .foregroundStyle(isPlaced ? .secondary : .primary)
                    Text(accessory.category.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPlaced {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BrandColor.primary)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(isPlaced)
    }

    /// Risolve i UUID selezionati in accessori HomeKit nell'ordine in cui compaiono nella lista.
    private func collectSelected() -> [HMAccessory] {
        guard let home = homeKit.currentHome else { return [] }
        return home.accessories.filter { selected.contains($0.uniqueIdentifier) }
    }

    /// All rooms that have placeable accessories, with search filtering applied.
    private var allRoomsWithAccessories: [(HMRoom, [HMAccessory])] {
        guard let home = homeKit.currentHome else { return [] }

        let filtered: (HMAccessory) -> Bool = { acc in
            // Filtro 1: deve essere piazzabile sul floorplan
            let adapter = AccessoryAdapterFactory.adapter(for: acc, homeKit: homeKit)
            guard adapter.supportsFloorplanPlacement else { return false }

            // Filtro 2: matcha il search
            guard !searchText.isEmpty else { return true }
            return acc.name.localizedCaseInsensitiveContains(searchText)
        }

        return home.rooms.map { room in
            let accs = home.accessories
                .filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
                .filter(filtered)
            return (room, accs)
        }
        .filter { !$0.1.isEmpty }
    }

    /// Rooms whose UUID is in `preferredRoomUUIDs` (floorplan areas).
    private var preferredRooms: [(HMRoom, [HMAccessory])] {
        guard !preferredRoomUUIDs.isEmpty else { return [] }
        return allRoomsWithAccessories.filter { preferredRoomUUIDs.contains($0.0.uniqueIdentifier) }
    }

    /// Rooms not in `preferredRoomUUIDs`.
    private var otherRooms: [(HMRoom, [HMAccessory])] {
        if preferredRoomUUIDs.isEmpty { return allRoomsWithAccessories }
        return allRoomsWithAccessories.filter { !preferredRoomUUIDs.contains($0.0.uniqueIdentifier) }
    }

    /// Rimuove il nome della stanza dal nome dell'accessorio (suffisso o prefisso con trattino).
    static func strippedName(_ name: String, roomName: String?) -> String {
        guard let roomName else { return name }
        let suffix = " " + roomName
        if name.hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        let prefix = roomName + " - "
        if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) }
        return name
    }
}
