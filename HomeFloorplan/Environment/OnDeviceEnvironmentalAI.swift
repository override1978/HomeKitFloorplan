import Foundation
import FoundationModels

// MARK: - OnDeviceEnvironmentalAI

/// Analisi ambientale con il modello Apple Intelligence sul dispositivo.
///
/// Il compito che resta all'AI è piccolo — il pre-processore ha già deciso
/// urgenza, scostamenti e se vale la pena chiamarla, e dopo la risposta
/// gravità e intent passano dai controlli deterministici: qui servono una
/// frase e qualche scelta da elenchi chiusi. È il lavoro in cui il modello
/// locale va bene, e il prompt (~2K token) sta comodo nel suo contesto.
///
/// Nessuna API key, nessun costo, nessuna rete: i dati dei sensori non
/// lasciano il dispositivo. Dove Apple Intelligence non c'è (es. iPad senza
/// chip M) l'analisi resta su Claude.
enum OnDeviceEnvironmentalAI {

    /// True se il modello locale può rispondere adesso: dispositivo idoneo,
    /// Apple Intelligence attiva e modello scaricato, lingua dell'app supportata.
    static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(Locale(identifier: AILocale.languageCode))
    }

    /// Risponde con lo stesso JSON chiesto a Claude, così `parseInsight` resta
    /// l'unico punto in cui la risposta viene letta e validata.
    ///
    /// Una sessione nuova per ogni stanza: le analisi sono indipendenti, e una
    /// sessione lunga riempirebbe il contesto senza dare nulla in cambio.
    static func respond(instructions: String, payload: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: payload,
            generating: EnvironmentalInsightDraft.self,
            options: GenerationOptions(temperature: 0.3)
        )
        return response.content.jsonString
    }
}

// MARK: - Schema di generazione

/// La risposta del modello locale, con gli stessi campi del JSON di Claude.
/// I valori chiusi (gravità, intent, livello) sono enum: il modello non può
/// produrre un valore che `parseInsight` scarterebbe.
///
/// La spiegazione viene prima del messaggio: ragionare prima di scrivere la
/// frase migliora la frase.
@Generable
nonisolated struct EnvironmentalInsightDraft {
    @Guide(description: "Brief reasoning in the output language, max 12 words: time of day, deviation direction, trend.")
    var whyExplanation: String

    @Guide(description: "True only if a sensor has urgency other than normal, or isAnomaly or actionableAnomaly is true.")
    var hasInsight: Bool

    var severity: InsightSeverityChoice

    @Guide(description: "The environmental problems to address. Empty if none applies.", .maximumCount(2))
    var intents: [EnvironmentalIntentChoice]

    var intelligenceLevel: IntelligenceLevelChoice

    @Guide(description: "Stable English snake_case key for a recurring situation, for example bathroom_post_shower_humidity. Empty if it is a one-off.")
    var patternKey: String

    @Guide(description: "One colloquial sentence in the output language, max 14 words, that includes the room name. No technical words.")
    var message: String

    /// Lo stesso JSON che produce Claude.
    var jsonString: String {
        let dict: [String: Any] = [
            "hasInsight": hasInsight,
            "message": message,
            "severity": severity.rawValue,
            "intents": intents.map(\.rawValue),
            "intelligenceLevel": intelligenceLevel.rawValue,
            "patternKey": patternKey.isEmpty ? NSNull() : patternKey,
            "whyExplanation": whyExplanation,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else { return "{\"hasInsight\":false}" }
        return string
    }
}

@Generable
nonisolated enum InsightSeverityChoice: String {
    case info, warning, anomaly
}

/// Gli stessi valori di `ActionIntent` che il prompt di Claude elenca.
@Generable
nonisolated enum EnvironmentalIntentChoice: String {
    case coolRoom, heatRoom, reduceHumidity, increaseHumidity, improveAirQuality
    case ventilateRoom, reduceCO2, respondToSmoke, respondToCO
}

@Generable
nonisolated enum IntelligenceLevelChoice: String {
    case observation, pattern, prediction, recommendation
}
