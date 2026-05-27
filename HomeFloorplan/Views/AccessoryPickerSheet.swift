import SwiftUI
import HomeKit

/// Sheet per scegliere un accessorio HomeKit da aggiungere al floorplan.
struct AccessoryPickerSheet: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    @Environment(\.dismiss) private var dismiss
    
    /// UUID degli accessori già piazzati: vengono mostrati ma disabilitati.
    let alreadyPlaced: Set<UUID>
    
    /// Callback con l'accessorio scelto.
    let onPick: (HMAccessory) -> Void
    
    @State private var searchText: String = ""
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(roomsWithAccessories, id: \.0.uniqueIdentifier) { room, accessories in
                    Section(room.name) {
                        ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                            row(for: accessory)
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Cerca accessorio")
            .navigationTitle("Aggiungi accessorio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
    
    private func row(for accessory: HMAccessory) -> some View {
        let isPlaced = alreadyPlaced.contains(accessory.uniqueIdentifier)
        let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
        
        return Button {
            onPick(accessory)
            dismiss()
        } label: {
            HStack {
                AccessoryIconView(iconName: iconName)
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading) {
                    Text(accessory.name)
                        .foregroundStyle(isPlaced ? .secondary : .primary)
                    Text(accessory.category.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isPlaced {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .disabled(isPlaced)
    }
    
    private var roomsWithAccessories: [(HMRoom, [HMAccessory])] {
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
}
