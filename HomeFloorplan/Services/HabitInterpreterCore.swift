import Foundation

/// Core puro del livello B del pivot Abitudini: l'interprete LLM.
///
/// La statistica rigida non funziona sui dati domestici sfumati; qui i ruoli
/// si invertono — il codice PREPARA un riassunto compatto dell'uso reale
/// (istogrammi orari + sequenze accessorio→accessorio) e il modello lo LEGGE
/// proponendo routine, che l'utente giudica nel wizard esistente.
/// Questo file è deterministico e testabile: niente rete, niente SwiftData.
enum HabitInterpreterCore {

    /// Proposta di routine come la restituisce il modello (JSON).
    struct RoutineSuggestion: Codable, Equatable, Identifiable {
        var id: String { "\(targetAccessoryName)|\(triggerType)|\(triggerTime ?? triggerAccessoryName ?? "")" }
        let title: String
        let explanation: String
        /// "calendar" (orario) oppure "accessoryState" (sequenza A→B).
        let triggerType: String
        /// "HH:mm" — solo per triggerType == "calendar".
        let triggerTime: String?
        /// 1=dom ... 7=sab — solo per calendar; nil = tutti i giorni.
        let weekdays: [Int]?
        /// Nome dell'accessorio causa — solo per triggerType == "accessoryState".
        let triggerAccessoryName: String?
        let targetAccessoryName: String
        /// "on" | "off".
        let action: String
    }

    // MARK: - Riassunto per il prompt

    /// Riassunto compatto e leggibile dell'uso: una riga per accessorio con
    /// istogramma orario delle accensioni, più le sequenze A→B frequenti.
    /// `preferExternal`: se esistono eventi flaggati "external", usa solo quelli.
    static func buildUsageSummary(events: [UsageEvidenceBuilder.EventSample],
                                  existingAutomations: [String],
                                  maxAccessories: Int = 25,
                                  calendar: Calendar = .current) -> String {
        let external = events.filter { $0.origin == "external" }
        let pool = external.isEmpty ? events : external
        let onEvents = pool.filter(\.state)

        var lines: [String] = []

        // Istogrammi orari per accessorio (solo accensioni).
        let byAccessory = Dictionary(grouping: onEvents) { $0.accessoryID }
        let ranked = byAccessory.values
            .sorted { $0.count > $1.count }
            .prefix(maxAccessories)

        for group in ranked {
            guard let first = group.first else { continue }
            var hourCounts: [Int: Int] = [:]
            for e in group {
                let h = calendar.component(.hour, from: e.timestamp)
                hourCounts[h, default: 0] += 1
            }
            let histogram = hourCounts.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: " ")
            let room = first.roomName.map { " (\($0))" } ?? ""
            lines.append("\(first.accessoryName)\(room) [\(first.eventType)] on×\(group.count) — h \(histogram)")
        }

        // Sequenze A→B: accensioni di B entro 120s da un'accensione di A.
        var pairCounts: [String: Int] = [:]
        let sorted = onEvents.sorted { $0.timestamp < $1.timestamp }
        for (i, a) in sorted.enumerated() {
            var j = i + 1
            while j < sorted.count,
                  sorted[j].timestamp.timeIntervalSince(a.timestamp) <= 120 {
                let b = sorted[j]
                if b.accessoryID != a.accessoryID {
                    pairCounts["\(a.accessoryName) -> \(b.accessoryName)", default: 0] += 1
                }
                j += 1
            }
        }
        let topPairs = pairCounts.filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(12)
        if !topPairs.isEmpty {
            lines.append("SEQUENCES (B on within 2min of A):")
            for (pair, count) in topPairs {
                lines.append("\(pair) ×\(count)")
            }
        }

        if !existingAutomations.isEmpty {
            lines.append("EXISTING AUTOMATIONS (do not duplicate):")
            lines.append(contentsOf: existingAutomations.prefix(20))
        }

        return lines.joined(separator: "\n")
    }

    /// System prompt: contratto JSON stretto, poche proposte, solo evidenza forte.
    static var systemPrompt: String {
        """
        You analyze smart-home usage summaries and propose automations.
        Input: per-accessory hourly ON histograms (hour:count), A -> B sequences, existing automations.
        Propose AT MOST 3 automations with clear recurring evidence. Skip anything ambiguous, \
        anything duplicating an existing automation, and sensor-only devices.
        Reply ONLY with a JSON array (no prose, no code fences) of objects:
        {"title": string, "explanation": string (mention the observed evidence), \
        "triggerType": "calendar"|"accessoryState", "triggerTime": "HH:mm" or null, \
        "weekdays": [1-7] or null (1=Sunday), "triggerAccessoryName": string or null, \
        "targetAccessoryName": string, "action": "on"|"off"}
        Empty array [] if nothing is clearly supported.
        """
    }

    // MARK: - Parsing risposta

    /// Parsing tollerante: estrae il primo array JSON anche se il modello
    /// aggiunge testo o code fence attorno.
    static func parseSuggestions(_ response: String) -> [RoutineSuggestion] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start < end else { return [] }
        let json = String(response[start...end])
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([RoutineSuggestion].self, from: data) else {
            return []
        }
        return parsed.filter { suggestion in
            (suggestion.action == "on" || suggestion.action == "off") &&
            (suggestion.triggerType == "calendar" || suggestion.triggerType == "accessoryState") &&
            !suggestion.targetAccessoryName.isEmpty
        }
    }
}
