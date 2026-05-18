import SwiftUI
import HomeKit

struct HomeKitDebugView: View {
    @Environment(HomeKitService.self) private var homeKit
    
    var body: some View {
        NavigationStack {
            Group {
                if !homeKit.isReady {
                    ContentUnavailableView {
                        Label("In attesa di HomeKit", systemImage: "house.badge.exclamationmark")
                    } description: {
                        Text("Concedi l'accesso a HomeKit quando richiesto. Se non vedi il prompt, controlla Impostazioni → Privacy → HomeKit.")
                    }
                } else if homeKit.allAccessories.isEmpty {
                    ContentUnavailableView {
                        Label("Nessun accessorio", systemImage: "lightbulb.slash")
                    } description: {
                        Text("Non è stato trovato alcun accessorio HomeKit. Verifica che l'app Casa abbia almeno una casa configurata con accessori.")
                    }
                } else {
                    accessoryList
                }
            }
            .navigationTitle(homeKit.currentHome?.name ?? "HomeKit")
            .toolbar {
                if let error = homeKit.lastError {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .labelStyle(.iconOnly)
                    }
                }
            }
        }
    }
    
    private var accessoryList: some View {
        List {
            Section {
                HStack {
                    Text("Casa")
                    Spacer()
                    Text(homeKit.currentHome?.name ?? "—")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Accessori totali")
                    Spacer()
                    Text("\(homeKit.allAccessories.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Stanze")
                    Spacer()
                    Text("\(homeKit.currentHome?.rooms.count ?? 0)")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Riepilogo")
            }
            
            ForEach(roomsWithAccessories, id: \.0.uniqueIdentifier) { room, accessories in
                Section(room.name) {
                    ForEach(accessories, id: \.uniqueIdentifier) { accessory in
                        accessoryRow(accessory)
                    }
                }
            }
        }
    }
    
    private func accessoryRow(_ accessory: HMAccessory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: iconName(for: accessory))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading) {
                    Text(accessory.name)
                        .font(.body)
                    Text(accessory.category.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !accessory.isReachable {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
            Text("Servizi: \(accessory.services.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
    
    /// Raggruppa gli accessori per stanza.
    private var roomsWithAccessories: [(HMRoom, [HMAccessory])] {
        guard let home = homeKit.currentHome else { return [] }
        return home.rooms.map { room in
            let accs = home.accessories.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
            return (room, accs)
        }
        .filter { !$0.1.isEmpty }
    }
    
    /// Icona SF Symbol approssimativa in base alla categoria HomeKit.
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
        case HMAccessoryCategoryTypeAirPurifier: return "air.purifier.fill"
        case HMAccessoryCategoryTypeSprinkler: return "drop.fill"
        case HMAccessoryCategoryTypeBridge: return "antenna.radiowaves.left.and.right"
        default: return "questionmark.circle"
        }
    }
}
