import Foundation

// MARK: - AILocale

/// Single source of truth for the output language injected into AI prompts.
/// Derived from the device locale: English for en, Italian for everything else.
enum AILocale {
    static var outputLanguage: String {
        let id = Locale.current.language.languageCode?.identifier ?? "it"
        return id == "en" ? "English" : "Italian"
    }
}
