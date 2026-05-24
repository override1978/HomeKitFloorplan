import SwiftUI
import HomeKit

/// Gestisce gli override delle icone scelti dall'utente per ogni accessorio HomeKit.
/// Mapping: UUID dell'accessorio → nome icona (può essere SF Symbol o asset custom,
/// la distinzione la fa AccessoryIconView al momento del rendering).
@Observable
final class IconOverrideStore {
    
    private static let userDefaultsKey = "iconOverrides.v1"
    
    private(set) var overrides: [UUID: String] = [:]
    
    init() {
        load()
    }
    
    // MARK: - API
    
    func icon(for accessoryUUID: UUID) -> String? {
        overrides[accessoryUUID]
    }
    
    func setIcon(_ iconName: String, for accessoryUUID: UUID) {
        overrides[accessoryUUID] = iconName
        save()
    }
    
    func removeIcon(for accessoryUUID: UUID) {
        overrides.removeValue(forKey: accessoryUUID)
        save()
    }
    
    // MARK: - Persistenza
    
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        overrides = decoded.reduce(into: [:]) { partial, pair in
            if let uuid = UUID(uuidString: pair.key) {
                partial[uuid] = pair.value
            }
        }
    }
    
    private func save() {
        let encoded = overrides.reduce(into: [String: String]()) { partial, pair in
            partial[pair.key.uuidString] = pair.value
        }
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}

extension IconOverrideStore {
    /// Restituisce il nome icona da usare per un accessorio, dando priorità
    /// all'override utente. Se non c'è override, ricade sull'icona dell'adapter.
    /// Usare SEMPRE questa in qualunque view che renderizza un'icona di accessorio.
    func effectiveIcon(for accessory: HMAccessory, adapter: any AccessoryAdapter) -> String {
        if let override = icon(for: accessory.uniqueIdentifier) {
            return override
        }
        return adapter.iconName
    }
}
