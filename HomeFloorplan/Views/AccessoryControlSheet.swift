import SwiftUI
import HomeKit

/// Sheet di controllo per un singolo accessorio.
/// Per ora gestisce on/off (power state). Estendibile per categoria.
struct AccessoryControlSheet: View {
    let accessory: HMAccessory
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Nome")
                        Spacer()
                        Text(accessory.name).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Stanza")
                        Spacer()
                        Text(accessory.room?.name ?? "—").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Stato")
                        Spacer()
                        Text(accessory.isReachable ? "Raggiungibile" : "Offline")
                            .foregroundStyle(accessory.isReachable ? .green : .orange)
                    }
                }
                
                if let powerChar = powerCharacteristic {
                    Section("Controllo") {
                        Toggle(isOn: powerBinding(for: powerChar)) {
                            Label("Acceso", systemImage: "power")
                        }
                        .disabled(!accessory.isReachable)
                    }
                } else {
                    Section {
                        Text("Questo accessorio non espone un controllo on/off semplice. Supporto esteso in arrivo.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
                
                Section("Servizi disponibili") {
                    ForEach(accessory.services, id: \.uniqueIdentifier) { service in
                        VStack(alignment: .leading) {
                            Text(service.name.isEmpty ? service.localizedDescription : service.name)
                                .font(.body)
                            Text("\(service.characteristics.count) caratteristiche")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(accessory.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Power state
    
    /// Cerca una caratteristica "power state" tra tutti i servizi.
    /// HMCharacteristicTypePowerState UUID: 00000025-0000-1000-8000-0026BB765291
    private var powerCharacteristic: HMCharacteristic? {
        for service in accessory.services {
            for char in service.characteristics where char.characteristicType == HMCharacteristicTypePowerState {
                return char
            }
        }
        return nil
    }
    
    private func powerBinding(for characteristic: HMCharacteristic) -> Binding<Bool> {
        Binding(
            get: {
                (homeKit.value(for: characteristic) as? Bool)
                ?? (characteristic.value as? Bool)
                ?? false
            },
            set: { newValue in
                Task {
                    try? await homeKit.write(newValue, to: characteristic)
                }
            }
        )
    }
}
