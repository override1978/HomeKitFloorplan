import SwiftUI
import HomeKit
import Observation

struct AllAccessoriesView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    @State private var searchText: String = ""

    // Group accessories by room name, or "No Room" if unavailable
    private var accessoriesByRoom: [String: [HMAccessory]] {
        let filtered: [HMAccessory]
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filtered = homeKit.allAccessories
        } else {
            filtered = homeKit.allAccessories.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return Dictionary(grouping: filtered) { accessory in
            accessory.room?.name ?? "Nessuna stanza"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if homeKit.allAccessories.isEmpty {
                    ContentUnavailableView {
                        Label("Nessun accessorio", systemImage: "square.grid.2x2")
                    } description: {
                        Text(homeKit.isReady ? "Non sono stati trovati accessori." : "Inizializzazione HomeKit in corso…")
                    }
                } else if accessoriesByRoom.isEmpty {
                    Text("Nessun accessorio corrispondente alla ricerca.")
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    ForEach(accessoriesByRoom.keys.sorted(), id: \.self) { roomName in
                        Section(roomName) {
                            ForEach(accessoriesByRoom[roomName] ?? [], id: \.uniqueIdentifier) { acc in
                                NavigationLink {
                                    AccessoryDetailView(accessory: acc)
                                } label: {
                                    accessoryRow(acc)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Accessori")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        }
    }
    
    // MARK: - Row
    
    @ViewBuilder
    private func accessoryRow(_ accessory: HMAccessory) -> some View {
        let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit)
        let iconName = iconOverrides.effectiveIcon(for: accessory, adapter: adapter)
        
        HStack(spacing: 12) {
            AccessoryIconView(iconName: iconName)
                .foregroundStyle(accessory.isReachable ? Color.accentColor : Color.gray)
                .frame(width: 22, height: 22)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(accessory.name)
                    .font(.body)
                Text(summaryFor(accessory: accessory, adapter: adapter))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            
            if let battery = adapter.batteryInfo {
                    BatteryBadgeView(info: battery)
                }
            
            if !accessory.isReachable {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Summary
    
    /// Riassunto testuale: dove possibile usa l'adapter (più preciso),
    /// altrimenti cade su ricerca diretta delle caratteristiche.
    private func summaryFor(accessory: HMAccessory, adapter: any AccessoryAdapter) -> String {
        // Adapter espone già un primaryStatusText per molti casi (sensori, robot...)
        if let status = adapter.primaryStatusText {
            return status
        }
        // Fallback: power state + brightness se è una luce dimmerabile
        if let on = boolCharacteristic(type: HMCharacteristicTypePowerState, in: accessory) {
            if let brightness = intCharacteristic(type: HMCharacteristicTypeBrightness, in: accessory) {
                return on ? "Acceso • \(brightness)%" : "Spento"
            }
            return on ? "Acceso" : "Spento"
        }
        return ""
    }

    // MARK: - Characteristic helpers (per fallback summary)
    
    private func characteristic(with type: String, in accessory: HMAccessory) -> HMCharacteristic? {
        for service in accessory.services {
            if let ch = service.characteristics.first(where: { $0.characteristicType == type }) {
                return ch
            }
        }
        return nil
    }

    private func boolCharacteristic(type: String, in accessory: HMAccessory) -> Bool? {
        guard let ch = characteristic(with: type, in: accessory) else { return nil }
        if let v = homeKit.value(for: ch) as? Bool { return v }
        return nil
    }

    private func intCharacteristic(type: String, in accessory: HMAccessory) -> Int? {
        guard let ch = characteristic(with: type, in: accessory) else { return nil }
        if let v = homeKit.value(for: ch) as? Int { return v }
        if let v = homeKit.value(for: ch) as? NSNumber { return v.intValue }
        return nil
    }
}

#Preview {
    let service = HomeKitService()
    let store = IconOverrideStore()
    return NavigationStack {
        AllAccessoriesView()
            .environment(service)
            .environment(store)
    }
}
