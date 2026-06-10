import Foundation

// MARK: - EnergyIgnoreStore

/// Persists the set of accessory UUIDs that the user has marked as "always on by design",
/// so the AI never generates energy alerts for them again.
///
/// Backed by UserDefaults — survives app restarts, zero SwiftData overhead.
enum EnergyIgnoreStore {

    private static let key = "energy.ignoredAccessories.v1"

    // MARK: - Read

    static var ignoredIDs: Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    static func isIgnored(_ id: UUID) -> Bool {
        ignoredIDs.contains(id)
    }

    // MARK: - Write

    /// Permanently suppresses energy alerts for the given accessory.
    static func ignore(_ id: UUID) {
        persist(ignoredIDs.union([id]))
    }

    /// Re-enables energy monitoring for the given accessory.
    static func unignore(_ id: UUID) {
        persist(ignoredIDs.subtracting([id]))
    }

    // MARK: - Private

    private static func persist(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }
}
