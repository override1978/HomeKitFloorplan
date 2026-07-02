import Foundation

/// Provides a stable UUID for this device installation.
/// Generated once on first launch and persisted in UserDefaults.
/// Survives app updates; reset only if the user deletes and reinstalls the app.
enum DeviceIdentity {
    private static let key = "device.stable.uuid"

    static let id: String = {
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()
}
