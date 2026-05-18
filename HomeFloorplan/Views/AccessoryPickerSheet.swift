import SwiftUI
import HomeKit

/// Sheet per scegliere un accessorio HomeKit da aggiungere al floorplan.
struct AccessoryPickerSheet: View {
    @Environment(HomeKitService.self) private var homeKit
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
        return Button {
            onPick(accessory)
            dismiss()
        } label: {
            HStack {
                Image(systemName: iconName(for: accessory))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
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
    
    private func iconName(for accessory: HMAccessory) -> String {
        switch accessory.category.categoryType {
        case HMAccessoryCategoryTypeLightbulb: return "lightbulb.fill"
        case HMAccessoryCategoryTypeOutlet: return "powerplug.fill"
        case HMAccessoryCategoryTypeSwitch: return "switch.2"
        case HMAccessoryCategoryTypeThermostat: return "thermometer"
        case HMAccessoryCategoryTypeSensor: return "sensor.fill"
        case HMAccessoryCategoryTypeDoorLock: return "lock.fill"
        case HMAccessoryCategoryTypeWindow,
             HMAccessoryCategoryTypeWindowCovering: return "blinds.horizontal.closed"
        case HMAccessoryCategoryTypeFan: return "fan.fill"
        case HMAccessoryCategoryTypeGarageDoorOpener: return "door.garage.closed"
        case HMAccessoryCategoryTypeIPCamera,
             HMAccessoryCategoryTypeVideoDoorbell: return "video.fill"
        default: return "questionmark.circle"
        }
    }
}
