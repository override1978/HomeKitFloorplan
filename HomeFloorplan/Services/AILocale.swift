import Foundation

// MARK: - AILocale

/// Single source of truth for the output language injected into AI prompts.
///
/// Legge la stessa impostazione da cui l'interfaccia ricava il proprio locale
/// (`HomeFloorplanRootView` passa `AppLanguage.resolved(from: appLanguageRaw).locale`),
/// e non più `Locale.current`.
///
/// Erano due sorgenti diverse che sembravano la stessa. `Locale.current` riflette
/// `AppleLanguages`, che `AppLanguage.apply()` scrive in UserDefaults ma che il
/// sistema rilegge **solo al lancio successivo**; l'interfaccia invece ricalcola
/// il proprio locale subito dall'override. Finché coincidono nessuno se ne
/// accorge — quando divergono si ottiene interfaccia in una lingua e risposte
/// dell'AI nell'altra, che è come si è manifestato sul campo.
///
/// La lingua è anche una delle impostazioni sincronizzate via CloudKit, quindi
/// può cambiare da sotto senza che nessuno tocchi quel dispositivo: una ragione
/// in più perché i due percorsi partano dallo stesso valore invece che da due
/// copie che si allineano solo dopo un riavvio.
enum AILocale {

    /// L'override applicativo, con lo stesso fallback usato dall'interfaccia.
    private static var resolved: AppLanguage {
        let raw = UserDefaults.standard.string(forKey: AppLanguage.appStorageKey) ?? ""
        return AppLanguage.resolved(from: raw)
    }

    static var outputLanguage: String {
        resolved == .english ? "English" : "Italian"
    }

    /// Short language code used for per-language cache keys ("en" or "it").
    static var languageCode: String {
        resolved == .english ? "en" : "it"
    }
}
