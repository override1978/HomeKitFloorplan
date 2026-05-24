import SwiftUI
import HomeKit
import Observation

struct AllAccessoriesView: View {
    @Environment(HomeKitService.self) private var homeKit
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
                                    HStack(spacing: 12) {
                                        Image(systemName: iconName(for: acc))
                                            .foregroundStyle(acc.isReachable ? Color.green : Color.gray)
                                            .frame(width: 20, height: 20, alignment: .center)
                                            .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(acc.name)
                                                .font(.body)
                                            Text(summaryFor(accessory: acc))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if acc.isReachable == false {
                                            Image(systemName: "exclamationmark.triangle")
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .contentShape(Rectangle())
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

    // MARK: - Helpers

    private func colorFor(accessory: HMAccessory) -> Color {
        // Verde se acceso (se rilevabile), blu per sensori attivi, grigio altrimenti
        if let on = boolCharacteristic(named: "Power State", in: accessory) ?? boolCharacteristic(type: HMCharacteristicTypePowerState, in: accessory) {
            return on ? .green : .gray
        }
        if let motion = boolCharacteristic(named: "Motion Detected", in: accessory) ?? boolCharacteristic(type: HMCharacteristicTypeMotionDetected, in: accessory) {
            return motion ? .blue : .gray
        }
        return .gray
    }

    private func summaryFor(accessory: HMAccessory) -> String {
        // Prova alcune caratteristiche comuni per comporre un riassunto
        if let on = boolCharacteristic(type: HMCharacteristicTypePowerState, in: accessory) {
            if let brightness = intCharacteristic(type: HMCharacteristicTypeBrightness, in: accessory) {
                return on ? "Acceso • Luminosità: \(brightness)%" : "Spento"
            }
            return on ? "Acceso" : "Spento"
        }
        if let temp = numberCharacteristic(type: HMCharacteristicTypeCurrentTemperature, in: accessory) {
            return String(format: "%.1f ℃", temp)
        }
        if let motion = boolCharacteristic(type: HMCharacteristicTypeMotionDetected, in: accessory) {
            return motion ? "Movimento rilevato" : "Nessun movimento"
        }
        return ""
    }

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

    private func boolCharacteristic(named localized: String, in accessory: HMAccessory) -> Bool? {
        for service in accessory.services {
            if let ch = service.characteristics.first(where: { $0.localizedDescription == localized }), let v = homeKit.value(for: ch) as? Bool {
                return v
            }
        }
        return nil
    }

    private func intCharacteristic(type: String, in accessory: HMAccessory) -> Int? {
        guard let ch = characteristic(with: type, in: accessory) else { return nil }
        if let v = homeKit.value(for: ch) as? Int { return v }
        if let v = homeKit.value(for: ch) as? NSNumber { return v.intValue }
        return nil
    }

    private func numberCharacteristic(type: String, in accessory: HMAccessory) -> Double? {
        guard let ch = characteristic(with: type, in: accessory) else { return nil }
        if let v = homeKit.value(for: ch) as? Double { return v }
        if let v = homeKit.value(for: ch) as? NSNumber { return v.doubleValue }
        return nil
    }

    private func iconName(for accessory: HMAccessory) -> String {
        let types = accessory.services.map { $0.serviceType }
        if types.contains(HMServiceTypeLightbulb) { return "lightbulb.fill" }
        if types.contains(HMServiceTypeOutlet) { return "powerplug.fill" }
        if types.contains(HMServiceTypeSwitch) { return "switch.2" }
        if types.contains(HMServiceTypeThermostat) { return "thermometer" }
        if types.contains(HMServiceTypeTemperatureSensor) { return "thermometer" }
        if types.contains(HMServiceTypeHumiditySensor) { return "humidity" }
        if types.contains(HMServiceTypeMotionSensor) { return "figure.walk.motion" }
        if types.contains(HMServiceTypeContactSensor) { return "sensor.tag.radiowaves.forward" }
        if types.contains(HMServiceTypeStatelessProgrammableSwitch) { return "dot.circle" }
        if types.contains(HMServiceTypeLockMechanism) { return "lock.fill" }
        if types.contains(HMServiceTypeDoor) { return "door.left.hand.closed" }
        if types.contains(HMServiceTypeWindow) { return "window.vertical.closed" }
        if types.contains(HMServiceTypeSecuritySystem) { return "shield.lefthalf.filled" }
        return "questionmark.circle"
    }
}

#Preview {
    let service = HomeKitService()
    return NavigationStack {
        AllAccessoriesView()
            .environment(service)
    }
}
