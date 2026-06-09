import Foundation
import SwiftData
import HomeKit
import Observation

// MARK: - RuleEngineService

/// Gestisce la creazione, esecuzione e ciclo di vita delle regole di automazione.
/// Quando un pattern viene approvato, decide automaticamente se delegare a HomeKit
/// o eseguire in-app. Valuta le regole inApp periodicamente.
@Observable
@MainActor
final class RuleEngineService {

    // MARK: - State

    var rules: [Rule] = []

    // MARK: - Private

    private let modelContainer: ModelContainer

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        loadRules()
    }

    // MARK: - Rule Creation

    /// Crea una regola da un HabitPattern approvato.
    /// Decide automaticamente executionMode in base alla complessità del trigger.
    func createRule(from pattern: HabitPattern, home: HMHome) async throws {
        guard let ruleData = pattern.suggestedRuleJSON.data(using: .utf8),
              let ruleDict = try? JSONSerialization.jsonObject(with: ruleData) as? [String: Any]
        else {
            // Fallback: crea regola inApp minimale
            createFallbackRule(from: pattern)
            return
        }

        let triggerType = ruleDict["triggerType"] as? String ?? "calendar"
        let time        = ruleDict["time"] as? String
        let weekdays    = ruleDict["weekdays"] as? [Int] ?? []
        let action      = ruleDict["action"] as? String ?? "on"
        let value       = ruleDict["value"] as? Double

        // Parsing azione: "dim:30" → actionType = "dim", actionValue = 0.30
        let (parsedAction, parsedValue) = parseAction(action, explicitValue: value)

        let weekdaysStr = weekdays.map(String.init).joined(separator: ",")

        let rule = Rule(
            name: pattern.accessoryName,
            ruleDescription: pattern.description,
            triggerType: triggerType,
            triggerTime: time,
            triggerWeekdays: weekdaysStr.isEmpty ? nil : weekdaysStr,
            actionAccessoryID: pattern.accessoryID.uuidString,
            actionType: parsedAction,
            actionValue: parsedValue,
            executionMode: shouldDelegateToHomeKit(triggerType: triggerType) ? "homeKit" : "inApp",
            isEnabled: false,
            confidenceScore: pattern.confidence,
            generatedByAI: true
        )

        // Tenta delega HomeKit
        if rule.executionMode == "homeKit" {
            if let triggerID = await tryCreateHomeKitTrigger(rule: rule, home: home) {
                rule.homeKitTriggerID = triggerID
            } else {
                // Fallback a inApp se HomeKit non riesce
                rule.executionMode = "inApp"
            }
        }

        let context = modelContainer.mainContext
        context.insert(rule)
        try? context.save()
        rules.append(rule)
    }

    /// Crea una regola da un RuleDraft (proveniente da AINextAction o RuleEditorView).
    func createRule(from draft: RuleDraft, home: HMHome) async throws {
        let weekdaysStr = (draft.triggerWeekdays ?? []).map(String.init).joined(separator: ",")
        let executionMode = draft.shouldDelegateToHomeKit ? "homeKit" : "inApp"

        let rule = Rule(
            name: draft.name,
            ruleDescription: draft.description,
            triggerType: draft.triggerType,
            triggerTime: draft.triggerTime,
            triggerWeekdays: weekdaysStr.isEmpty ? nil : weekdaysStr,
            triggerCharacteristicID: draft.triggerCharacteristicID,
            triggerThreshold: draft.triggerThreshold,
            actionAccessoryID: draft.actionAccessoryID,
            actionType: draft.actionType,
            actionValue: draft.actionValue,
            actionValue2: draft.actionValue2,
            executionMode: executionMode,
            confidenceScore: draft.confidenceScore,
            generatedByAI: draft.generatedByAI
        )

        // Tenta delega HomeKit
        if rule.executionMode == "homeKit" {
            if let triggerID = await tryCreateHomeKitTrigger(rule: rule, home: home) {
                rule.homeKitTriggerID = triggerID
            } else {
                rule.executionMode = "inApp"
            }
        }

        let context = modelContainer.mainContext
        context.insert(rule)
        try? context.save()
        rules.append(rule)
    }

    // MARK: - HomeKit Trigger

    /// Tenta di creare un HMEventTrigger su HomeKit.
    /// Restituisce il triggerID stringa se riesce, nil altrimenti.
    private func tryCreateHomeKitTrigger(rule: Rule, home: HMHome) async -> String? {
        guard rule.triggerType == "calendar",
              let timeStr = rule.triggerTime,
              let triggerTime = parseTimeComponents(timeStr)
        else { return nil }

        // Trova l'accessorio e la caratteristica target
        guard let accessory = home.accessories.first(where: {
            $0.uniqueIdentifier.uuidString == rule.actionAccessoryID
        }) else { return nil }

        // Cerca la caratteristica on/off (UUID HAP standard)
        let onUUID = "00000025-0000-1000-8000-0026bb765291"
        let brightnessUUID = "00000008-0000-1000-8000-0026bb765291"

        let targetCharUUID: String
        if rule.actionType == "dim" {
            targetCharUUID = brightnessUUID
        } else {
            targetCharUUID = onUUID
        }

        guard let service = accessory.services.first(where: {
            $0.characteristics.contains { $0.characteristicType.lowercased() == targetCharUUID }
        }),
              let characteristic = service.characteristics.first(where: {
                  $0.characteristicType.lowercased() == targetCharUUID
              })
        else { return nil }

        // Costruisci HMCharacteristicWriteAction
        let actionValue: NSCopying & NSObjectProtocol
        switch rule.actionType {
        case "on":    actionValue = 1 as NSNumber
        case "off":   actionValue = 0 as NSNumber
        case "dim":
            let pct = Int((rule.actionValue ?? 0.3) * 100)
            actionValue = pct as NSNumber
        default:      actionValue = 1 as NSNumber
        }

        let writeAction = HMCharacteristicWriteAction(
            characteristic: characteristic,
            targetValue: actionValue
        )

        // Crea calendario trigger
        var components = DateComponents()
        components.hour   = triggerTime.hour
        components.minute = triggerTime.minute

        // HMCalendarEvent non supporta weekday filtering nativo —
        // i giorni vengono gestiti in-app (evaluateInAppRules).

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // HMActionSet deve essere creato tramite home.addActionSet(withName:)
            home.addActionSet(withName: rule.name) { [weak home] actionSet, error in
                guard error == nil, let actionSet, let home else {
                    continuation.resume(returning: nil)
                    return
                }
                actionSet.addAction(writeAction) { error in
                    guard error == nil else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let calEvent = HMCalendarEvent(fire: components)
                    let trigger = HMEventTrigger(name: rule.name, events: [calEvent], end: nil, recurrences: nil, predicate: nil)
                    home.addTrigger(trigger) { error in
                        guard error == nil else {
                            continuation.resume(returning: nil)
                            return
                        }
                        trigger.addActionSet(actionSet) { error in
                            guard error == nil else {
                                continuation.resume(returning: nil)
                                return
                            }
                            trigger.enable(true) { _ in }
                            continuation.resume(returning: trigger.uniqueIdentifier.uuidString)
                        }
                    }
                }
            }
        }
    }

    // MARK: - In-App Rule Evaluation

    /// Valuta le regole inApp e le esegue se il trigger è soddisfatto.
    /// Chiamato periodicamente dal BGAppRefreshTask o dall'app in foreground.
    func evaluateInAppRules(home: HMHome) async {
        let now = Date()
        let cal = Calendar.current

        for rule in rules where rule.isEnabled && rule.executionMode == "inApp" {
            guard rule.triggerType == "calendar",
                  let timeStr = rule.triggerTime,
                  let t = parseTimeComponents(timeStr)
            else { continue }

            let currentHour   = cal.component(.hour,   from: now)
            let currentMinute = cal.component(.minute,  from: now)
            let currentDay    = cal.component(.weekday, from: now)

            // Triggera se siamo nell'ora/minuto corretti
            guard currentHour == t.hour && currentMinute == t.minute else { continue }

            // Verifica giorni settimana
            if !rule.weekdaysArray.isEmpty && !rule.weekdaysArray.contains(currentDay) { continue }

            // Evita doppia esecuzione nello stesso minuto
            if let last = rule.lastExecutedAt,
               abs(now.timeIntervalSince(last)) < 58 { continue }

            await executeRule(rule, home: home)
        }
    }

    private func executeRule(_ rule: Rule, home: HMHome) async {
        guard let accessory = home.accessories.first(where: {
            $0.uniqueIdentifier.uuidString == rule.actionAccessoryID
        }) else { return }

        let allChars = accessory.services.flatMap(\.characteristics)

        func char(_ uuid: String) -> HMCharacteristic? {
            allChars.first { $0.characteristicType.lowercased() == uuid }
        }

        let activeUUID    = "000000b0-0000-1000-8000-0026bb765291"
        let onUUID        = "00000025-0000-1000-8000-0026bb765291"
        let hcUUID        = "000000b2-0000-1000-8000-0026bb765291"
        let heatingUUID   = "00000012-0000-1000-8000-0026bb765291"
        let coolingUUID   = "0000000d-0000-1000-8000-0026bb765291"

        // Determina se è un termostato/AC (ha HeaterCoolerState)
        let isThermostat  = char(hcUUID) != nil

        switch rule.actionType {

        case "on":
            if isThermostat {
                // Per termostati: Active=1 poi imposta modalità (actionValue se presente, altrimenti Auto=0)
                if let activeChar = char(activeUUID) {
                    try? await activeChar.writeValue(1)
                }
                let mode = Int(rule.actionValue ?? 0)   // 0=Auto, 1=Caldo, 2=Freddo
                if let modeChar = char(hcUUID) {
                    try? await modeChar.writeValue(mode)
                }
            } else {
                let target = char(activeUUID) ?? char(onUUID)
                try? await target?.writeValue(1)
            }

        case "off":
            if isThermostat {
                // Per termostati: Active=0 spegne il dispositivo
                if let activeChar = char(activeUUID) {
                    try? await activeChar.writeValue(0)
                }
            } else {
                let target = char(activeUUID) ?? char(onUUID)
                try? await target?.writeValue(0)
            }

        case "dim":
            try? await char("00000008-0000-1000-8000-0026bb765291")?.writeValue(Int((rule.actionValue ?? 0.3) * 100))

        case "open":
            try? await char("0000007c-0000-1000-8000-0026bb765291")?.writeValue(100)

        case "close":
            try? await char("0000007c-0000-1000-8000-0026bb765291")?.writeValue(0)

        case "setSpeed":
            try? await char("00000029-0000-1000-8000-0026bb765291")?.writeValue(Int((rule.actionValue ?? 0.5) * 100))

        case "setMode":
            if isThermostat {
                let mode = Int(rule.actionValue ?? 0)
                if mode == -1 {
                    // Spegni
                    try? await char(activeUUID)?.writeValue(0)
                } else {
                    // Attiva prima, poi imposta modalità
                    if let activeChar = char(activeUUID) {
                        try? await activeChar.writeValue(1)
                    }
                    try? await char(hcUUID)?.writeValue(mode)
                    // Temperatura secondaria (riscaldamento/raffreddamento)
                    if let temp = rule.actionValue2 {
                        try? await char(heatingUUID)?.writeValue(temp)
                        try? await char(coolingUUID)?.writeValue(temp)
                    }
                }
            } else {
                // Purificatore o altro: TargetAirPurifierState
                let apUUID = "000000a8-0000-1000-8000-0026bb765291"
                try? await char(apUUID)?.writeValue(Int(rule.actionValue ?? 0))
            }

        case "setTemp":
            try? await char("00000035-0000-1000-8000-0026bb765291")?.writeValue(rule.actionValue ?? 22.0)
            // Se termostato: scrivi anche HeatingThreshold e CoolingThreshold
            if isThermostat, let temp = rule.actionValue {
                try? await char(heatingUUID)?.writeValue(temp)
                try? await char(coolingUUID)?.writeValue(temp)
            }

        default: return
        }

        rule.lastExecutedAt = Date()
        try? modelContainer.mainContext.save()
    }

    // MARK: - Execute Now

    /// Esegue immediatamente una regola, ignorando il trigger orario.
    /// Usato dal pulsante "Esegui ora" in ActiveRulesView.
    func executeNow(_ rule: Rule, home: HMHome) async {
        await executeRule(rule, home: home)
    }

    // MARK: - Update / Toggle / Delete

    func updateRule(_ rule: Rule, from draft: RuleDraft) {
        let context = modelContainer.mainContext
        rule.name            = draft.name
        rule.triggerType     = draft.triggerType
        rule.triggerTime     = draft.triggerTime
        rule.weekdaysArray   = draft.triggerWeekdays ?? []
        rule.actionType      = draft.actionType
        rule.actionValue     = draft.actionValue
        rule.actionValue2    = draft.actionValue2
        rule.triggerThreshold = draft.triggerThreshold
        rule.executionMode   = draft.shouldDelegateToHomeKit ? "homeKit" : "inApp"
        try? context.save()
    }

    func toggleRule(_ rule: Rule) {
        rule.isEnabled.toggle()
        try? modelContainer.mainContext.save()
    }

    func deleteRule(_ rule: Rule, home: HMHome?) async throws {
        // Rimuovi da HomeKit se delegato e la casa è disponibile
        if let home,
           rule.executionMode == "homeKit",
           let triggerIDStr = rule.homeKitTriggerID,
           let triggerUUID = UUID(uuidString: triggerIDStr),
           let trigger = home.triggers.first(where: { $0.uniqueIdentifier == triggerUUID }) {
            try await home.removeTrigger(trigger)
        }

        let context = modelContainer.mainContext
        context.delete(rule)
        try? context.save()
        rules.removeAll { $0.id == rule.id }
    }

    // MARK: - Helpers

    private func shouldDelegateToHomeKit(triggerType: String) -> Bool {
        // Delegabile: trigger a orario fisso e trigger per caratteristica semplice
        triggerType == "calendar" || triggerType == "characteristic"
    }

    private func parseAction(_ action: String, explicitValue: Double?) -> (String, Double?) {
        if action.hasPrefix("dim:") {
            let pctStr = action.dropFirst(4)
            let pct = Double(pctStr) ?? 30.0
            return ("dim", pct / 100.0)
        }
        return (action, explicitValue)
    }

    private func parseTimeComponents(_ timeStr: String) -> (hour: Int, minute: Int)? {
        let parts = timeStr.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func createFallbackRule(from pattern: HabitPattern) {
        let rule = Rule(
            name: pattern.accessoryName,
            ruleDescription: pattern.description,
            triggerType: "inApp",
            actionAccessoryID: pattern.accessoryID.uuidString,
            actionType: "on",
            executionMode: "inApp",
            isEnabled: false,
            confidenceScore: pattern.confidence,
            generatedByAI: true
        )
        let context = modelContainer.mainContext
        context.insert(rule)
        try? context.save()
        rules.append(rule)
    }

    /// Inserts an already-built Rule into SwiftData and the in-memory list.
    /// Used when BehavioralAnalysisService approves an AutomationOpportunity.
    func insertRule(_ rule: Rule) {
        let context = ModelContext(modelContainer)
        context.insert(rule)
        try? context.save()
        rules.append(rule)
    }

    // MARK: - Load

    private func loadRules() {
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Rule>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        rules = (try? context.fetch(descriptor)) ?? []
    }
}
