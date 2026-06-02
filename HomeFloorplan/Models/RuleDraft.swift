import Foundation

// MARK: - RuleDraft

/// Struttura intermedia tra il JSON dell'AI e l'entità SwiftData `Rule`.
/// Usata da RuleEditorView per visualizzare e modificare la regola prima di salvarla.
/// Costruita da `AINextAction.ruleJSON` o da `HabitPattern.suggestedRuleJSON`.
struct RuleDraft: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String
    /// "calendar" | "characteristic" | "inApp"
    var triggerType: String
    /// Es. "22:18" — per trigger calendar.
    var triggerTime: String?
    /// Giorni della settimana (1=Dom, 7=Sab) — per trigger calendar.
    var triggerWeekdays: [Int]?
    /// UUID caratteristica HomeKit — per trigger characteristic.
    var triggerCharacteristicID: String?
    /// Soglia numerica — per trigger characteristic.
    var triggerThreshold: Double?
    /// UUID stringa dell'accessorio target.
    var actionAccessoryID: String
    /// Nome leggibile dell'accessorio (per UI, senza query).
    var actionAccessoryName: String
    /// "on" | "off" | "dim" | "open" | "close"
    var actionType: String
    /// 0.0–1.0 per dim, nil per gli altri.
    var actionValue: Double?
    /// Temperatura target in °C quando actionType == "setMode" (opzionale).
    var actionValue2: Double?
    var confidenceScore: Double
    var generatedByAI: Bool

    // MARK: - Factory

    /// Costruisce un RuleDraft da una stringa JSON generata dall'AI.
    /// Torna `nil` se il JSON non è valido o mancano campi obbligatori.
    static func from(ruleJSON: String) throws -> RuleDraft {
        guard let data = ruleJSON.data(using: .utf8) else {
            throw RuleDraftError.invalidJSON
        }

        // Prova prima il decoder diretto (JSON già nel formato RuleDraft)
        if let draft = try? JSONDecoder().decode(RuleDraft.self, from: data) {
            return draft
        }

        // Fallback: parsing manuale del formato AI (HabitAnalysisService)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessoryID = dict["accessoryID"] as? String ?? dict["actionAccessoryID"] as? String
        else {
            throw RuleDraftError.missingFields
        }

        let triggerType  = dict["triggerType"] as? String ?? "calendar"
        let action       = dict["action"] as? String ?? "on"
        let time         = dict["time"] as? String
        let weekdays     = dict["weekdays"] as? [Int]
        let value        = dict["value"] as? Double

        // Parsing "dim:30" → ("dim", 0.30)
        let (parsedAction, parsedValue) = parseAction(action, explicitValue: value)

        return RuleDraft(
            name: dict["accessoryName"] as? String ?? "Regola AI",
            description: dict["description"] as? String ?? "",
            triggerType: triggerType,
            triggerTime: time,
            triggerWeekdays: weekdays,
            triggerCharacteristicID: dict["triggerCharacteristicID"] as? String,
            triggerThreshold: dict["triggerThreshold"] as? Double,
            actionAccessoryID: accessoryID,
            actionAccessoryName: dict["accessoryName"] as? String ?? "",
            actionType: parsedAction,
            actionValue: parsedValue,
            confidenceScore: dict["confidence"] as? Double ?? 0.8,
            generatedByAI: true
        )
    }

    // MARK: - Helpers

    /// Delegabile a HomeKit se il trigger è semplice (orario o caratteristica).
    var shouldDelegateToHomeKit: Bool {
        triggerType == "calendar" || triggerType == "characteristic"
    }

    var executionMode: String {
        shouldDelegateToHomeKit ? "homeKit" : "inApp"
    }

    var executionModeLabel: String {
        executionMode == "homeKit"
            ? String(localized: "rule.mode.homekit", defaultValue: "HomeKit")
            : String(localized: "rule.mode.inapp", defaultValue: "In-App")
    }

    var executionModeIcon: String {
        executionMode == "homeKit" ? "house.fill" : "iphone"
    }
}

// MARK: - RuleDraftError

enum RuleDraftError: LocalizedError {
    case invalidJSON
    case missingFields

    var errorDescription: String? {
        switch self {
        case .invalidJSON:  return "JSON non valido."
        case .missingFields: return "Campi obbligatori mancanti nel JSON."
        }
    }
}

// MARK: - Private helpers

private func parseAction(_ action: String, explicitValue: Double?) -> (String, Double?) {
    if action.hasPrefix("dim:") {
        let pctStr = action.dropFirst(4)
        let pct = Double(pctStr) ?? 30.0
        return ("dim", pct / 100.0)
    }
    return (action, explicitValue)
}
