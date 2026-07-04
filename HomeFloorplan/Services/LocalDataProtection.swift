import Foundation

// MARK: - LocalDataProtection

enum LocalDataProtection {
    nonisolated static let preserveSwiftDataKey = "localData.preserveSwiftData"

    /// Defaults to true: local SwiftData records must not be removed automatically.
    nonisolated static var shouldPreserveSwiftData: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: preserveSwiftDataKey) != nil else { return true }
        return defaults.bool(forKey: preserveSwiftDataKey)
    }
}
