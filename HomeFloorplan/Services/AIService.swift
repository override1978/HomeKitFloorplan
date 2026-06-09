import Foundation

// MARK: - AIError

/// Errori restituiti da AIService, con messaggi leggibili in italiano.
enum AIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case networkUnavailable(underlying: Error)
    case unauthorized          // HTTP 401
    case rateLimited           // HTTP 429
    case serverError(code: Int)
    case unexpectedResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(localized: "ai.error.missingKey",
                          defaultValue: "API key non configurata. Vai in Impostazioni → Intelligenza Artificiale per aggiungerla.")
        case .invalidURL:
            return String(localized: "ai.error.invalidURL",
                          defaultValue: "URL endpoint non valido.")
        case .networkUnavailable:
            return String(localized: "ai.error.network",
                          defaultValue: "Connessione di rete non disponibile. Verifica la connessione e riprova.")
        case .unauthorized:
            return String(localized: "ai.error.unauthorized",
                          defaultValue: "API key non valida o scaduta (401). Controlla la chiave in Impostazioni.")
        case .rateLimited:
            return String(localized: "ai.error.rateLimited",
                          defaultValue: "Troppe richieste (429). Attendi qualche secondo e riprova.")
        case .serverError(let code):
            return String(localized: "ai.error.serverError",
                          defaultValue: "Errore del server (\(code)). Riprova tra qualche minuto.")
        case .unexpectedResponse:
            return String(localized: "ai.error.unexpected",
                          defaultValue: "Risposta inattesa dal provider AI.")
        case .decodingFailed:
            return String(localized: "ai.error.decoding",
                          defaultValue: "Impossibile interpretare la risposta del provider AI.")
        }
    }
}

// MARK: - AIService

/// Layer di networking unificato verso provider AI (Claude e OpenAI).
/// Legge la API key dal Keychain e formatta il payload correttamente per ogni provider.
/// Nessuna chiamata automatica in background — tutte le chiamate sono esplicite.
final class AIService {

    // MARK: - Singleton / DI

    static let shared = AIService(settings: .init())

    private let settings: AISettings
    private let session: URLSession

    init(settings: AISettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    // MARK: - Test connessione

    /// Verifica che la API key configurata funzioni inviando un prompt minimale.
    /// Aggiorna `settings.lastConnectionTest` e `settings.lastConnectionSuccess`.
    /// - Returns: `true` se la connessione ha avuto successo.
    @MainActor
    func testConnection() async -> Bool {
        do {
            _ = try await sendPrompt(
                systemPrompt: "Rispondi solo con la parola OK.",
                userPrompt: "ping"
            )
            settings.lastConnectionTest    = Date()
            settings.lastConnectionSuccess = true
            return true
        } catch {
            settings.lastConnectionTest    = Date()
            settings.lastConnectionSuccess = false
            return false
        }
    }

    // MARK: - Send prompt

    /// Invia un prompt al provider configurato e restituisce la risposta testuale.
    /// - Parameters:
    ///   - systemPrompt: Istruzione di sistema (contesto e ruolo del modello).
    ///   - userPrompt: Messaggio utente da inviare al modello.
    /// - Throws: `AIError` in caso di problemi di rete, autenticazione o parsing.
    func sendPrompt(systemPrompt: String, userPrompt: String) async throws -> String {
        guard let apiKey = KeychainHelper.load(key: settings.selectedProvider.keychainKey),
              !apiKey.isEmpty
        else { throw AIError.missingAPIKey }

        switch settings.selectedProvider {
        case .claude:
            return try await sendClaude(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: apiKey)
        case .openai:
            return try await sendOpenAI(systemPrompt: systemPrompt, userPrompt: userPrompt, apiKey: apiKey)
        }
    }

    // MARK: - Claude

    private func sendClaude(systemPrompt: String, userPrompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: AIProvider.claude.apiEndpoint) else { throw AIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.httpMethod = "POST"
        request.setValue(apiKey,         forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",   forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model":      AIProvider.claude.defaultModel,
            "max_tokens": 1000,
            "system":     systemPrompt,
            "messages":   [["role": "user", "content": userPrompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performWithRetry(request)
        try checkHTTP(response)

        // Decodifica risposta Claude:
        // { "content": [{ "type": "text", "text": "..." }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let first = content.first,
              let text = first["text"] as? String
        else { throw AIError.decodingFailed }

        return text
    }

    // MARK: - OpenAI

    private func sendOpenAI(systemPrompt: String, userPrompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: AIProvider.openai.apiEndpoint) else { throw AIError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": AIProvider.openai.defaultModel,
            "messages": [
                ["role": "system",  "content": systemPrompt],
                ["role": "user",    "content": userPrompt],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performWithRetry(request)
        try checkHTTP(response)

        // Decodifica risposta OpenAI:
        // { "choices": [{ "message": { "content": "..." } }] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String
        else { throw AIError.decodingFailed }

        return text
    }

    // MARK: - Helpers

    /// Esegue la richiesta con retry esponenziale (max 4 tentativi, backoff 1s/2s/4s ± 0.5s jitter).
    /// Ritenta su: URLError (rete), HTTP 429 (rate limited), HTTP 503/504 (server transient).
    /// Non ritenta: 401, missingAPIKey, invalidURL — quelli sono definitivi.
    private func performWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var lastError: Error = AIError.unexpectedResponse
        let baseDelays: [Double] = [1.0, 2.0, 4.0]   // delays between attempts 0→1, 1→2, 2→3

        for attempt in 0..<4 {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200...299:
                        return (data, response)
                    case 429:
                        lastError = AIError.rateLimited
                    case 503, 504:
                        lastError = AIError.serverError(code: http.statusCode)
                    default:
                        // Non-transient HTTP error: return and let checkHTTP throw
                        return (data, response)
                    }
                } else {
                    return (data, response)
                }
            } catch let urlError as URLError {
                lastError = AIError.networkUnavailable(underlying: urlError)
            }

            if attempt < baseDelays.count {
                let jitter = Double.random(in: -0.5...0.5)
                let ns = UInt64(max(0.1, baseDelays[attempt] + jitter) * 1_000_000_000)
                try await Task.sleep(nanoseconds: ns)
            }
        }
        throw lastError
    }

    /// Controlla lo status code HTTP e lancia l'errore appropriato.
    private func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AIError.unexpectedResponse }
        switch http.statusCode {
        case 200...299: return
        case 401:       throw AIError.unauthorized
        case 429:       throw AIError.rateLimited
        default:        throw AIError.serverError(code: http.statusCode)
        }
    }
}
