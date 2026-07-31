import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case italian = "it"

    static let appStorageKey = "app.languageOverride"
    private static let deviceSnapshotKey = "app.deviceLanguage.snapshot"
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
        case .system:  return Locale(identifier: Self.deviceLanguage == .italian ? "it" : "en")
        case .english: return Locale(identifier: "en")
        case .italian: return Locale(identifier: "it")
        }
    }

    /// La lingua del dispositivo, fotografata una volta sola.
    ///
    /// Va fotografata perché `apply()` scrive `AppleLanguages` nei UserDefaults
    /// dell'app: da quel momento `Locale.preferredLanguages` restituisce
    /// l'override scelto dall'utente e non più la lingua di sistema, quindi
    /// leggerla dopo darebbe una risposta circolare. `apply()` gira solo quando
    /// l'utente cambia lingua a mano, quindi al primo avvio la lettura è ancora
    /// quella vera.
    static var deviceLanguage: AppLanguage {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: deviceSnapshotKey) {
            return saved == "it" ? .italian : .english
        }
        let code = Locale.preferredLanguages.first
            .flatMap { Locale(identifier: $0).language.languageCode?.identifier }
        let resolved = (code == "it") ? "it" : "en"
        defaults.set(resolved, forKey: deviceSnapshotKey)
        return resolved == "it" ? .italian : .english
    }

    /// "Sistema" ora segue davvero il sistema.
    ///
    /// Prima sia `.system` sia un valore mancante si risolvevano in **inglese**,
    /// e il valore di partenza dell'AppStorage era anch'esso inglese: un iPad
    /// italiano su cui nessuno avesse mai aperto Impostazioni → Lingua partiva
    /// in inglese senza che nulla lo spiegasse.
    static func resolved(from rawValue: String) -> AppLanguage {
        if isSelectionLocked { return .english }
        let language = AppLanguage(rawValue: rawValue) ?? .system
        return language == .system ? deviceLanguage : language
    }

    static func apply(rawValue: String) {
        let language = isSelectionLocked ? .english : resolved(from: rawValue)
        let defaults = UserDefaults.standard

        defaults.set([language.rawValue], forKey: "AppleLanguages")

        defaults.synchronize()
    }
}
