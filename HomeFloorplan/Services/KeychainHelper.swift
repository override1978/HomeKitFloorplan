import Foundation
import Security

// MARK: - KeychainHelper

/// Wrapper semplice per operazioni Keychain con kSecClassGenericPassword.
/// Usato per salvare le API key dei provider AI in modo sicuro,
/// senza mai passare per UserDefaults o log.
enum KeychainHelper {

    // MARK: - Keys

    static let claudeAPIKey = "homefloorplan.ai.claude.apikey"
    static let openAIAPIKey = "homefloorplan.ai.openai.apikey"

    // MARK: - Save

    /// Salva o aggiorna un valore stringa nel Keychain.
    /// - Parameters:
    ///   - key: Identificatore univoco dell'item.
    ///   - value: Stringa da salvare (es. API key).
    @discardableResult
    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Elimina prima l'eventuale item esistente (update non è affidabile su tutti i sistemi)
        delete(key: key)

        let query: [CFString: Any] = [
            kSecClass:           kSecClassGenericPassword,
            kSecAttrAccount:     key,
            kSecValueData:       data,
            kSecAttrAccessible:  kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Load

    /// Legge e restituisce il valore stringa associato alla chiave, o nil se non esiste.
    static func load(key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }

        return string
    }

    // MARK: - Delete

    /// Elimina l'item associato alla chiave. Non produce errore se non esiste.
    @discardableResult
    static func delete(key: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrAccount:  key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
