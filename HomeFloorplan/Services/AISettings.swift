import Foundation
import Observation

// MARK: - AIProvider

/// Provider AI supportati dall'app.
enum AIProvider: String, CaseIterable, Codable {
    case claude = "Claude (Anthropic)"
    case openai = "OpenAI"

    /// Providers exposed in the public app UI.
    /// OpenAI support remains in code for a future agentic implementation.
    static var publicProviders: [AIProvider] {
        [.claude]
    }

    var isPubliclyAvailable: Bool {
        Self.publicProviders.contains(self)
    }

    /// Endpoint base dell'API per questo provider.
    var apiEndpoint: String {
        switch self {
        case .claude: return "https://api.anthropic.com/v1/messages"
        case .openai: return "https://api.openai.com/v1/chat/completions"
        }
    }

    /// Modello di default per questo provider.
    var defaultModel: String {
        switch self {
        case .claude: return "claude-haiku-4-5"
        case .openai: return "gpt-4o-mini"
        }
    }

    /// Chiave Keychain per la API key di questo provider.
    var keychainKey: String {
        switch self {
        case .claude: return KeychainHelper.claudeAPIKey
        case .openai: return KeychainHelper.openAIAPIKey
        }
    }

    /// URL della pagina prezzi del provider (per mostrare il link in AISettingsView).
    var pricingURL: URL {
        switch self {
        case .claude: return URL(string: "https://www.anthropic.com/pricing")!
        case .openai: return URL(string: "https://openai.com/pricing")!
        }
    }

    /// Nome localizzato per UI.
    var localizedName: String {
        switch self {
        case .claude: return String(localized: "ai.provider.claude", defaultValue: "Claude (Anthropic)")
        case .openai: return String(localized: "ai.provider.openai", defaultValue: "OpenAI")
        }
    }

    /// Plain prompt features such as environmental insights and habit naming.
    var supportsPromptAnalysis: Bool {
        true
    }

    /// Agentic assistant features that require tool-use / tool-result loops.
    var supportsHomeAssistantTools: Bool {
        switch self {
        case .claude: return true
        case .openai: return false
        }
    }
}

// MARK: - AISettings

private enum AISettingsKeys {
    static let selectedProvider      = "ai.selectedProvider"
    static let isAIEnabled           = "ai.isEnabled"
    static let suggestionsEnabled    = "ai.suggestionsEnabled"
    static let anomalyEnabled        = "ai.anomalyDetectionEnabled"
    static let ruleEngineEnabled     = "ai.ruleEngineEnabled"
    static let lastTestDate          = "ai.lastConnectionTestDate"
    static let lastTestSuccess       = "ai.lastConnectionTestSuccess"
    static let dataConsent           = "ai.dataConsent.v1"
}

/// Impostazioni AI persistite in UserDefaults (solo dati NON sensibili).
/// Le API key sono salvate esclusivamente nel Keychain tramite KeychainHelper.
@Observable
final class AISettings {

    // MARK: - Provider

    /// Provider selezionato dall'utente.
    var selectedProvider: AIProvider {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: AISettingsKeys.selectedProvider) }
    }

    // MARK: - Master switch

    /// Abilita/disabilita globalmente tutte le feature AI.
    var isAIEnabled: Bool {
        didSet { UserDefaults.standard.set(isAIEnabled, forKey: AISettingsKeys.isAIEnabled) }
    }

    // MARK: - Feature toggles

    /// Suggerimenti abitudini (IDEA-04).
    var suggestionsEnabled: Bool {
        didSet { UserDefaults.standard.set(suggestionsEnabled, forKey: AISettingsKeys.suggestionsEnabled) }
    }

    /// Rilevamento anomalie sensori (IDEA-05).
    var anomalyDetectionEnabled: Bool {
        didSet { UserDefaults.standard.set(anomalyDetectionEnabled, forKey: AISettingsKeys.anomalyEnabled) }
    }

    /// Rule engine predittivo (IDEA-06).
    var ruleEngineEnabled: Bool {
        didSet { UserDefaults.standard.set(ruleEngineEnabled, forKey: AISettingsKeys.ruleEngineEnabled) }
    }

    // MARK: - Stato ultimo test connessione

    var lastConnectionTest: Date? {
        didSet {
            if let date = lastConnectionTest {
                UserDefaults.standard.set(date, forKey: AISettingsKeys.lastTestDate)
            } else {
                UserDefaults.standard.removeObject(forKey: AISettingsKeys.lastTestDate)
            }
        }
    }

    var lastConnectionSuccess: Bool? {
        didSet {
            if let val = lastConnectionSuccess {
                UserDefaults.standard.set(val, forKey: AISettingsKeys.lastTestSuccess)
            } else {
                UserDefaults.standard.removeObject(forKey: AISettingsKeys.lastTestSuccess)
            }
        }
    }

    // MARK: - Consent

    /// True se l'utente ha esplicitamente accettato la trasmissione dati ambientali al provider AI.
    var hasAIDataConsent: Bool {
        didSet { UserDefaults.standard.set(hasAIDataConsent, forKey: AISettingsKeys.dataConsent) }
    }

    /// Registra il consenso esplicito dell'utente.
    func grantConsent() {
        hasAIDataConsent = true
    }

    /// Revoca il consenso e disabilita l'AI.
    func revokeConsent() {
        hasAIDataConsent = false
        isAIEnabled = false
    }

    // MARK: - Computed

    /// True se è presente una API key nel Keychain per il provider corrente.
    var hasAPIKey: Bool {
        KeychainHelper.load(key: selectedProvider.keychainKey) != nil
    }

    /// True se l'AI è operativa (abilitata + API key presente + consenso dati concesso).
    var isOperational: Bool {
        isAIEnabled && hasAPIKey && hasAIDataConsent
    }

    // MARK: - Init

    init() {
        let ud = UserDefaults.standard

        if let raw = ud.string(forKey: AISettingsKeys.selectedProvider),
           let provider = AIProvider(rawValue: raw),
           provider.isPubliclyAvailable {
            self.selectedProvider = provider
        } else {
            self.selectedProvider = .claude
            ud.set(AIProvider.claude.rawValue, forKey: AISettingsKeys.selectedProvider)
        }

        self.isAIEnabled             = ud.bool(forKey: AISettingsKeys.isAIEnabled)
        self.suggestionsEnabled      = ud.bool(forKey: AISettingsKeys.suggestionsEnabled)
        self.anomalyDetectionEnabled = ud.bool(forKey: AISettingsKeys.anomalyEnabled)
        self.ruleEngineEnabled       = ud.bool(forKey: AISettingsKeys.ruleEngineEnabled)
        self.lastConnectionTest      = ud.object(forKey: AISettingsKeys.lastTestDate) as? Date
        self.lastConnectionSuccess   = ud.object(forKey: AISettingsKeys.lastTestSuccess) as? Bool
        self.hasAIDataConsent        = ud.bool(forKey: AISettingsKeys.dataConsent)
    }
}
