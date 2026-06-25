import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case italian = "it"

    static let appStorageKey = "app.languageOverride"
    static let isSelectionLocked = false
    static let selectableLanguages: [AppLanguage] = [.english, .italian]

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
            return Locale(identifier: "en")
        case .english:
            return Locale(identifier: "en")
        case .italian:
            return Locale(identifier: "it")
        }
    }

    static func resolved(from rawValue: String) -> AppLanguage {
        if isSelectionLocked { return .english }
        let language = AppLanguage(rawValue: rawValue) ?? .english
        return language == .system ? .english : language
    }

    static func apply(rawValue: String) {
        let language = isSelectionLocked ? .english : resolved(from: rawValue)
        let defaults = UserDefaults.standard

        defaults.set([language.rawValue], forKey: "AppleLanguages")

        defaults.synchronize()
    }
}
