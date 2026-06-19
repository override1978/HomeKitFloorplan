import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case italian = "it"

    static let appStorageKey = "app.languageOverride"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "settings.language.system", defaultValue: "System")
        case .english:
            return "English"
        case .italian:
            return "Italiano"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .english:
            return Locale(identifier: "en")
        case .italian:
            return Locale(identifier: "it")
        }
    }

    static func resolved(from rawValue: String) -> AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .system
    }

    static func apply(rawValue: String) {
        let language = resolved(from: rawValue)
        let defaults = UserDefaults.standard

        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .italian:
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }

        defaults.synchronize()
    }
}
