import Foundation
import SwiftData

// MARK: - Rule

/// Regola di automazione generata dall'AI o dall'utente.
/// Può essere delegata a HomeKit (HMEventTrigger) o eseguita in-app.
/// Legacy schema model retained only so existing local stores remain readable.
@Model
final class Rule {
    @Attribute(.unique) var id: UUID
    var name: String
    var ruleDescription: String
    /// Tipo trigger: "calendar" (orario fisso) | "characteristic" | "inApp"
    var triggerType: String
    /// Orario per trigger calendar (es. "22:18").
    var triggerTime: String?
    /// Giorni settimana serializzati (es. "1,2,3,4,5,6,7").
    var triggerWeekdays: String?
    /// UUID caratteristica HomeKit per trigger characteristic.
    var triggerCharacteristicID: String?
    /// Soglia per trigger characteristic.
    var triggerThreshold: Double?
    /// UUID accessorio target.
    var actionAccessoryID: String
    /// Tipo azione: "on", "off", "dim", "open", "close".
    var actionType: String
    /// Valore azione (es. 0.3 per dim al 30%).
    var actionValue: Double?
    /// Valore secondario: temperatura target in °C quando actionType == "setMode".
    var actionValue2: Double?
    /// Nome scena HomeKit da eseguire. Se impostato, actionAccessoryID/actionType vengono ignorati.
    var actionSceneName: String?
    /// Modalità esecuzione: "homeKit" | "inApp".
    var executionMode: String
    /// UUID del HMEventTrigger se delegato a HomeKit.
    var homeKitTriggerID: String?
    var isEnabled: Bool
    var confidenceScore: Double
    var generatedByAI: Bool
    var createdAt: Date
    var lastExecutedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        ruleDescription: String,
        triggerType: String,
        triggerTime: String? = nil,
        triggerWeekdays: String? = nil,
        triggerCharacteristicID: String? = nil,
        triggerThreshold: Double? = nil,
        actionAccessoryID: String,
        actionType: String,
        actionValue: Double? = nil,
        actionValue2: Double? = nil,
        actionSceneName: String? = nil,
        executionMode: String = "inApp",
        homeKitTriggerID: String? = nil,
        isEnabled: Bool = true,
        confidenceScore: Double = 0.0,
        generatedByAI: Bool = true,
        createdAt: Date = Date(),
        lastExecutedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.ruleDescription = ruleDescription
        self.triggerType = triggerType
        self.triggerTime = triggerTime
        self.triggerWeekdays = triggerWeekdays
        self.triggerCharacteristicID = triggerCharacteristicID
        self.triggerThreshold = triggerThreshold
        self.actionAccessoryID = actionAccessoryID
        self.actionType = actionType
        self.actionValue = actionValue
        self.actionValue2 = actionValue2
        self.actionSceneName = actionSceneName
        self.executionMode = executionMode
        self.homeKitTriggerID = homeKitTriggerID
        self.isEnabled = isEnabled
        self.confidenceScore = confidenceScore
        self.generatedByAI = generatedByAI
        self.createdAt = createdAt
        self.lastExecutedAt = lastExecutedAt
    }

    // MARK: - Computed helpers

    /// Array di giorni settimana parsato da `triggerWeekdays`.
    var weekdaysArray: [Int] {
        get {
            guard let raw = triggerWeekdays else { return [] }
            return raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        set {
            triggerWeekdays = newValue.map(String.init).joined(separator: ",")
        }
    }

    /// Label badge per l'UI.
    var executionModeLabel: String {
        executionMode == "homeKit"
            ? String(localized: "rule.mode.homeKit", defaultValue: "HomeKit")
            : String(localized: "rule.mode.inApp",   defaultValue: "In-App")
    }

    var executionModeIcon: String {
        executionMode == "homeKit" ? "house.fill" : "iphone"
    }
}
