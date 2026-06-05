import Foundation

// MARK: - ActionIntentInferrer

/// Reverse-engineers semantic ActionIntents from an AI-generated AmbientalAIInsight.
///
/// The inferrer works by scanning the natural-language insight message for Italian
/// keywords associated with each intent.  More specific keywords are evaluated first
/// (safety > health > comfort) to avoid false matches.
///
/// Sprint 1 usage: feeds the ActionResolver in shadow mode only.
/// Sprint 2 usage: replaced by the LLM outputting explicit intent strings.
enum ActionIntentInferrer {

    // MARK: - Keyword Map

    /// Ordered list of (keywords, intent) pairs.  First match per intent wins.
    /// Ordering: safety intents first, then health, then comfort.
    private static let keywordMap: [(keywords: [String], intent: ActionIntent)] = [
        // Safety
        (["fumo", "incendio", "smoke"],                                              .respondToSmoke),
        (["monossido", "co ", "carbonio monossido"],                                 .respondToCO),
        // Health — humidity
        (["umidità alta", "umidità elevat", "troppa umidità", "umidità sup"],        .reduceHumidity),
        (["umidità bassa", "umidità scarsa", "aria secca", "secchezza"],             .increaseHumidity),
        // Health — air quality
        (["qualità dell'aria", "qualità aria", "aria pesante", "voc", "inquin"],     .improveAirQuality),
        (["co₂", "anidride", "co2"],                                                 .improveAirQuality),
        (["ventila", "arieggia", "ricambio", "aria viziata"],                        .ventilateRoom),
        // Comfort — temperature
        (["caldo", "calda", "temperatura alta", "temperatura elevat", "surriscald"], .coolRoom),
        (["freddo", "fredda", "temperatura bassa", "gelo", "rigido"],                .heatRoom),
    ]

    // MARK: - Inference

    /// Infers one or more ActionIntents from the natural-language message in the given insight.
    /// Returns an empty array if no keyword matches are found.
    static func infer(from insight: AmbientalAIInsight) -> [ActionIntent] {
        let text = insight.message.lowercased()
        var found: [ActionIntent] = []
        var seen: Set<ActionIntent> = []

        for (keywords, intent) in keywordMap {
            guard !seen.contains(intent) else { continue }
            for keyword in keywords {
                if text.contains(keyword) {
                    found.append(intent)
                    seen.insert(intent)
                    break
                }
            }
        }

        return found
    }
}
