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
            if let triggerID = await tryCreateHomeKitTrigger(rule: rule, home: home, enabled: rule.isEnabled) {
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
            if let triggerID = await tryCreateHomeKitTrigger(rule: rule, home: home, enabled: rule.isEnabled) {
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

        /// Tenta di creare un HMEventTrigger su HomeKit.
        /// Restituisce il triggerID stringa se riesce, nil altrimenti.
        /// Il trigger viene creato con lo stato `enabled` specificato, in modo che
        /// il suo stato su Apple Home rispecchi esattamente `rule.isEnabled`.
        ///
        /// Costruisce TUTTE le write action necessarie all'azione:
        /// "on al 60%" → power on + brightness 60 (scrivere solo la brightness lascerebbe
        /// la luce spenta). L'action set viene popolato in sequenza prima di creare il trigger.
        /// Quando rule.actionSceneName è impostato, aggiunge invece l'HMActionSet esistente.
        private func tryCreateHomeKitTrigger(rule: Rule, home: HMHome, enabled: Bool) async -> String? {

            // ── Scene-based path: collega un HMActionSet esistente ──────────────────
            if let sceneName = rule.actionSceneName {
                return await tryAttachSceneToTrigger(sceneName: sceneName,
                                                     rule: rule, home: home, enabled: enabled)
            }

            // ── Trova accessorio target ────────────────────────────────────────────
            guard let accessory = home.accessories.first(where: {
                $0.uniqueIdentifier.uuidString == rule.actionAccessoryID
            }) else {
                print("[HK] ❌ accessorio non trovato: \(rule.actionAccessoryID)")
                return nil
            }

            // HAP UUIDs
            let onUUID         = "00000025-0000-1000-8000-0026bb765291"
            let activeUUID     = "000000b0-0000-1000-8000-0026bb765291"
            let brightnessUUID = "00000008-0000-1000-8000-0026bb765291"
            let positionUUID   = "0000007c-0000-1000-8000-0026bb765291"

            let allChars = accessory.services.flatMap(\.characteristics)
            func char(_ uuid: String) -> HMCharacteristic? {
                allChars.first { $0.characteristicType.lowercased() == uuid }
            }

            // ── Costruisci write actions ───────────────────────────────────────────
            var writeActions: [HMCharacteristicWriteAction<NSCopying & NSObjectProtocol>] = []

            switch rule.actionType {
            case "on":
                if let c = char(onUUID) ?? char(activeUUID) {
                    writeActions.append(HMCharacteristicWriteAction(characteristic: c, targetValue: 1 as NSNumber))
                }
                if let v = rule.actionValue, let bChar = char(brightnessUUID) {
                    writeActions.append(HMCharacteristicWriteAction(characteristic: bChar,
                                                                    targetValue: Int(v * 100) as NSNumber))
                }
            case "dim":
                if let c = char(onUUID) {
                    writeActions.append(HMCharacteristicWriteAction(characteristic: c, targetValue: 1 as NSNumber))
                }
                if let bChar = char(brightnessUUID) {
                    let pct = Int((rule.actionValue ?? 0.3) * 100)
                    writeActions.append(HMCharacteristicWriteAction(characteristic: bChar,
                                                                    targetValue: pct as NSNumber))
                }
            case "off":
                if let c = char(onUUID) ?? char(activeUUID) {
                    writeActions.append(HMCharacteristicWriteAction(characteristic: c, targetValue: 0 as NSNumber))
                }
            case "open", "close":
                if let posChar = char(positionUUID) {
                    let pos = rule.actionType == "open" ? 100 : 0
                    writeActions.append(HMCharacteristicWriteAction(characteristic: posChar,
                                                                    targetValue: pos as NSNumber))
                }
            default:
                print("[HK] ❌ actionType non delegabile: \(rule.actionType)")
                return nil
            }

            guard !writeActions.isEmpty else {
                print("[HK] ❌ writeActions vuoto per \(accessory.name)")
                return nil
            }

            // ── Costruisci HMEvent ─────────────────────────────────────────────────
            let hmEvent: HMEvent
            // Catturate dal caso "characteristic" per aggiungere il predicato dopo la creazione del trigger
            var characteristicSensorChar: HMCharacteristic? = nil
            var characteristicThreshold:  Double?            = nil
            var characteristicDirection:  String             = "below"

            switch rule.triggerType {

            case "calendar":
                guard let timeStr = rule.triggerTime,
                      let t = parseTimeComponents(timeStr) else {
                    print("[HK] ❌ calendar: triggerTime mancante o non parsabile")
                    return nil
                }
                var components = DateComponents()
                components.hour   = t.hour
                components.minute = t.minute
                hmEvent = HMCalendarEvent(fire: components)

            case "characteristic":
                // Trigger su soglia sensore HomeKit.
                // Usa HMCharacteristicEvent(triggerValue:nil) per catturare qualsiasi cambiamento
                // del valore, poi aggiunge un predicato con la soglia via updatePredicate.
                // Questo approccio (identico al caso calendar+condizione) viene visualizzato
                // correttamente da Apple Home come "> 28°C" invece di un range senza etichette.
                guard let conditionStr = rule.triggerCharacteristicID,
                      let threshold = rule.triggerThreshold else {
                    print("[HK] ❌ characteristic: conditionStr o threshold mancante")
                    return nil
                }
                let parts         = conditionStr.split(separator: "|").map(String.init)
                let sensorTypeRaw = parts[0]
                let sensorRoom    = parts.count > 1 ? String(parts[1]) : nil
                let direction     = parts.count > 2 ? String(parts[2]) : "below"
                guard let sensorChar = findSensorCharacteristic(typeRaw: sensorTypeRaw,
                                                                 room: sensorRoom,
                                                                 in: home) else {
                    print("[HK] ❌ characteristic: nessun sensore HomeKit '\(sensorTypeRaw)' in room=\(sensorRoom ?? "any") → fallback inApp")
                    return nil
                }
                hmEvent = HMCharacteristicEvent<NSNumber>(characteristic: sensorChar, triggerValue: nil)
                characteristicSensorChar = sensorChar
                characteristicThreshold  = threshold
                characteristicDirection  = direction

            default:
                print("[HK] ❌ triggerType non supportato: \(rule.triggerType)")
                return nil
            }

            // ── Crea ActionSet + Trigger in HomeKit ────────────────────────────────
            return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let actionSetName = homeKitSafeName(for: rule)
                print("[HK] addActionSet: '\(actionSetName)'")
                home.addActionSet(withName: actionSetName) { [weak home] actionSet, error in
                    guard error == nil, let actionSet, let home else {
                        print("[HK] ❌ addActionSet fallito: \(error?.localizedDescription ?? "home nil")")
                        continuation.resume(returning: nil)
                        return
                    }

                    func addActions(_ index: Int) {
                        if index >= writeActions.count {
                            let trigger = HMEventTrigger(name: actionSetName,
                                                         events: [hmEvent],
                                                         end: nil,
                                                         recurrences: nil,
                                                         predicate: nil)
                            print("[HK] addTrigger: '\(actionSetName)'")
                            home.addTrigger(trigger) { error in
                                guard error == nil else {
                                    print("[HK] ❌ addTrigger fallito: \(error!.localizedDescription)")
                                    continuation.resume(returning: nil)
                                    return
                                }
                                trigger.addActionSet(actionSet) { error in
                                    guard error == nil else {
                                        print("[HK] ❌ trigger.addActionSet fallito: \(error!.localizedDescription)")
                                        continuation.resume(returning: nil)
                                        return
                                    }
                                    let triggerID = trigger.uniqueIdentifier.uuidString

                                    // Characteristic trigger: aggiungi predicato soglia
                                    if let condChar = characteristicSensorChar,
                                       let thr = characteristicThreshold {
                                        let op: NSComparisonPredicate.Operator = characteristicDirection == "above" ? .greaterThan : .lessThan
                                        let pred = HMEventTrigger.predicateForEvaluatingTrigger(
                                            condChar, relatedBy: op, toValue: NSNumber(value: thr))
                                        trigger.updatePredicate(pred) { _ in
                                            trigger.enable(enabled) { _ in }
                                            continuation.resume(returning: triggerID)
                                        }
                                        return
                                    }

                                    // Calendar + sensore aggiuntivo: aggiungi predicato HK
                                    if rule.triggerType == "calendar",
                                       let conditionStr = rule.triggerCharacteristicID,
                                       let threshold = rule.triggerThreshold {
                                        let parts = conditionStr.split(separator: "|").map(String.init)
                                        let sensorTypeRaw = parts.first ?? ""
                                        let sensorRoom    = parts.count > 1 ? String(parts[1]) : nil
                                        let direction     = parts.count > 2 ? String(parts[2]) : "below"
                                        if let condChar = self.findSensorCharacteristic(
                                            typeRaw: sensorTypeRaw, room: sensorRoom, in: home) {
                                            let op: NSComparisonPredicate.Operator = direction == "above"
                                                ? .greaterThan : .lessThan
                                            let predicate = HMEventTrigger.predicateForEvaluatingTrigger(
                                                condChar, relatedBy: op, toValue: NSNumber(value: threshold))
                                            trigger.updatePredicate(predicate) { _ in
                                                trigger.enable(enabled) { _ in }
                                                continuation.resume(returning: triggerID)
                                            }
                                            return
                                        }
                                    }
                                    trigger.enable(enabled) { _ in }
                                    continuation.resume(returning: triggerID)
                                }
                            }
                            return
                        }
                        actionSet.addAction(writeActions[index]) { error in
                            guard error == nil else {
                                continuation.resume(returning: nil); return
                            }
                            addActions(index + 1)
                        }
                    }
                    addActions(0)
                }
            }
        }

    // MARK: - Scene-based trigger attachment

    /// Attaches an existing HMActionSet (scene) to a new HMEventTrigger.
    /// Used when rule.actionSceneName is set — the scene was created earlier via createScene.
    private func tryAttachSceneToTrigger(sceneName: String, rule: Rule, home: HMHome, enabled: Bool) async -> String? {
        guard let actionSet = home.actionSets.first(where: {
            $0.name.lowercased() == sceneName.lowercased()
        }) else {
            print("[HK] ❌ scena '\(sceneName)' non trovata — fallback inApp")
            return nil
        }

        // Build HMEvent (same logic as tryCreateHomeKitTrigger)
        var characteristicSensorChar: HMCharacteristic? = nil
        var characteristicThreshold:  Double?            = nil
        var characteristicDirection:  String             = "below"

        let hmEvent: HMEvent
        switch rule.triggerType {
        case "calendar":
            guard let timeStr = rule.triggerTime, let t = parseTimeComponents(timeStr) else {
                print("[HK] ❌ calendar: triggerTime mancante per scena")
                return nil
            }
            var components = DateComponents()
            components.hour   = t.hour
            components.minute = t.minute
            hmEvent = HMCalendarEvent(fire: components)

        case "characteristic":
            guard let conditionStr = rule.triggerCharacteristicID,
                  let threshold = rule.triggerThreshold else {
                print("[HK] ❌ characteristic: conditionStr o threshold mancante per scena")
                return nil
            }
            let parts         = conditionStr.split(separator: "|").map(String.init)
            let sensorTypeRaw = parts[0]
            let sensorRoom    = parts.count > 1 ? String(parts[1]) : nil
            let direction     = parts.count > 2 ? String(parts[2]) : "below"
            guard let sensorChar = findSensorCharacteristic(typeRaw: sensorTypeRaw,
                                                             room: sensorRoom,
                                                             in: home) else {
                print("[HK] ❌ sensore non trovato per scena '\(sceneName)'")
                return nil
            }
            hmEvent = HMCharacteristicEvent<NSNumber>(characteristic: sensorChar, triggerValue: nil)
            characteristicSensorChar = sensorChar
            characteristicThreshold  = threshold
            characteristicDirection  = direction

        default:
            print("[HK] ❌ triggerType non supportato per scena: \(rule.triggerType)")
            return nil
        }

        let triggerName = homeKitSafeName(for: rule)
        print("[HK] addTrigger (scene): '\(triggerName)' → scena '\(sceneName)'")

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let trigger = HMEventTrigger(name: triggerName,
                                         events: [hmEvent],
                                         end: nil,
                                         recurrences: nil,
                                         predicate: nil)
            home.addTrigger(trigger) { error in
                guard error == nil else {
                    print("[HK] ❌ addTrigger(scena) fallito: \(error!.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                trigger.addActionSet(actionSet) { error in
                    guard error == nil else {
                        print("[HK] ❌ addActionSet(scena) fallito: \(error!.localizedDescription)")
                        continuation.resume(returning: nil)
                        return
                    }
                    let triggerID = trigger.uniqueIdentifier.uuidString

                    if let condChar = characteristicSensorChar, let thr = characteristicThreshold {
                        let op: NSComparisonPredicate.Operator = characteristicDirection == "above" ? .greaterThan : .lessThan
                        let pred = HMEventTrigger.predicateForEvaluatingTrigger(
                            condChar, relatedBy: op, toValue: NSNumber(value: thr))
                        trigger.updatePredicate(pred) { _ in
                            trigger.enable(enabled) { _ in }
                            continuation.resume(returning: triggerID)
                        }
                        return
                    }
                    trigger.enable(enabled) { _ in }
                    continuation.resume(returning: triggerID)
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

            // ── Trigger characteristic: sensore supera/scende sotto soglia ──────────
            if rule.triggerType == "characteristic" {
                guard let conditionStr = rule.triggerCharacteristicID,
                      let threshold = rule.triggerThreshold else { continue }

                // Cooldown 2h: non ri-eseguire mentre la condizione è già attiva
                if let last = rule.lastExecutedAt, now.timeIntervalSince(last) < 7200 { continue }

                let parts     = conditionStr.split(separator: "|").map(String.init)
                let sensorType = parts[0]
                let sensorRoom = parts.count > 1 ? String(parts[1]) : nil
                let direction  = parts.count > 2 ? String(parts[2]) : "below"

                var desc = FetchDescriptor<SensorReading>(
                    sortBy: [SortDescriptor(\SensorReading.timestamp, order: .reverse)]
                )
                desc.fetchLimit = 20
                let ctx = ModelContext(modelContainer)
                let allReadings = (try? ctx.fetch(desc)) ?? []
                let matching = allReadings.filter {
                    $0.serviceTypeRaw == sensorType &&
                    (sensorRoom == nil || $0.roomName.lowercased().contains(sensorRoom!.lowercased()))
                }
                guard let latest = matching.first else { continue }
                let conditionMet = direction == "above" ? latest.value > threshold : latest.value < threshold
                guard conditionMet else { continue }

                await executeRule(rule, home: home)
                continue
            }

            // ── Trigger calendar: ora fissa ───────────────────────────────────────
            guard rule.triggerType == "calendar",
                  let timeStr = rule.triggerTime,
                  let t = parseTimeComponents(timeStr)
            else { continue }

            let currentHour   = cal.component(.hour,   from: now)
            let currentMinute = cal.component(.minute,  from: now)
            let currentDay    = cal.component(.weekday, from: now)

            guard currentHour == t.hour && currentMinute == t.minute else { continue }

            if !rule.weekdaysArray.isEmpty && !rule.weekdaysArray.contains(currentDay) { continue }

            // Evita doppia esecuzione nello stesso giorno
            if let last = rule.lastExecutedAt, cal.isDateInToday(last) { continue }

            // Condizione sensore opzionale (calendar + predicato)
            if let conditionStr = rule.triggerCharacteristicID, let threshold = rule.triggerThreshold {
                let parts = conditionStr.split(separator: "|").map(String.init)
                let sensorType = parts[0]
                let sensorRoom = parts.count > 1 ? String(parts[1]) : nil
                let direction  = parts.count > 2 ? String(parts[2]) : "below"
                var desc = FetchDescriptor<SensorReading>(
                    sortBy: [SortDescriptor(\SensorReading.timestamp, order: .reverse)]
                )
                desc.fetchLimit = 20
                let context = ModelContext(modelContainer)
                let allReadings = (try? context.fetch(desc)) ?? []
                let matching = allReadings.filter {
                    $0.serviceTypeRaw == sensorType &&
                    (sensorRoom == nil || $0.roomName.lowercased().contains(sensorRoom!.lowercased()))
                }
                guard let latest = matching.first else { continue }
                let conditionMet = direction == "above" ? latest.value > threshold : latest.value < threshold
                guard conditionMet else { continue }
            }

            await executeRule(rule, home: home)
        }
    }

    private func executeRule(_ rule: Rule, home: HMHome) async {
        // Scene-based: execute the existing HMActionSet directly
        if let sceneName = rule.actionSceneName {
            if let actionSet = home.actionSets.first(where: {
                $0.name.lowercased() == sceneName.lowercased()
            }) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    home.executeActionSet(actionSet) { _ in continuation.resume() }
                }
            }
            rule.lastExecutedAt = Date()
            try? modelContainer.mainContext.save()
            return
        }

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

    func toggleRule(_ rule: Rule, home: HMHome? = nil) {
        rule.isEnabled.toggle()
        try? modelContainer.mainContext.save()

        // Sincronizza lo stato dell'HMEventTrigger su Apple Home con il nuovo isEnabled.
        // Senza questo, disabilitare una regola nell'app non ferma l'automazione HomeKit.
        guard rule.executionMode == "homeKit",
              let triggerIDStr = rule.homeKitTriggerID,
              let triggerUUID  = UUID(uuidString: triggerIDStr),
              let home,
              let trigger = home.triggers.first(where: { $0.uniqueIdentifier == triggerUUID })
        else { return }

        trigger.enable(rule.isEnabled) { _ in }
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

    /// Builds a HomeKit-safe unique name for a rule's action set / trigger.
    /// HomeKit only accepts letters, digits, spaces, apostrophes, and hyphens;
    /// the name must start and end with alphanumeric characters.
    private func homeKitSafeName(for rule: Rule) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " '-"))
        // Remove colons (e.g. "7:30" → "7 30") then strip all other invalid chars.
        let preprocessed = rule.name.replacingOccurrences(of: ":", with: " ")
        let filtered = String(preprocessed.unicodeScalars.filter { allowed.contains($0) })
        // Collapse multiple spaces into one.
        let collapsed = filtered
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " '-"))
        let base = String((trimmed.isEmpty ? "Rule" : trimmed).prefix(40))
        let suffix = String(rule.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(4))
        return "\(base) \(suffix)"
    }

    private func shouldDelegateToHomeKit(triggerType: String) -> Bool {
        // Delegabile: trigger a orario fisso e trigger per caratteristica semplice
        triggerType == "calendar" || triggerType == "characteristic"
    }

    /// Finds the first HMCharacteristic matching the given sensor type HAP UUID.
    /// When `room` is provided, searches ONLY that room — returns nil if not found there.
    /// When `room` is nil, searches all accessories (for characteristic triggers without a room).
    private func findSensorCharacteristic(typeRaw: String, room: String?, in home: HMHome) -> HMCharacteristic? {
        guard let hapUUID = sensorHAPUUID(for: typeRaw) else { return nil }
        func char(in accessories: [HMAccessory]) -> HMCharacteristic? {
            accessories
                .flatMap { $0.services }
                .flatMap { $0.characteristics }
                .first { $0.characteristicType.lowercased() == hapUUID }
        }
        if let room {
            let needle = room.lowercased()
            let roomAccessories = home.rooms
                .filter { $0.name.lowercased().contains(needle) }
                .flatMap { $0.accessories }
            return char(in: roomAccessories)  // nil if not found — no global fallback when room is specified
        }
        return char(in: home.accessories)
    }

    private func sensorHAPUUID(for typeRaw: String) -> String? {
        switch typeRaw {
        case "lightSensor":    return "0000006b-0000-1000-8000-0026bb765291"
        case "temperature":    return "00000011-0000-1000-8000-0026bb765291"
        case "humidity":       return "00000010-0000-1000-8000-0026bb765291"
        case "carbonDioxide":  return "00000113-0000-1000-8000-0026bb765291"
        case "carbonMonoxide": return "00000069-0000-1000-8000-0026bb765291"
        case "airQuality":     return "00000095-0000-1000-8000-0026bb765291"
        default:               return nil
        }
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
    /*
    func insertRule(_ rule: Rule) {
        let context = ModelContext(modelContainer)
        context.insert(rule)
        try? context.save()
        rules.append(rule)
    }
     */
    /// Inserts an already-built Rule. If it's a calendar rule, delegates to HomeKit
    /// like the draft/pattern paths do.
    func insertRule(_ rule: Rule, home: HMHome?) async {
        // Delega HomeKit se calendar (stessa logica degli altri percorsi)
        if rule.executionMode == "homeKit", let home {
            if let triggerID = await tryCreateHomeKitTrigger(rule: rule, home: home, enabled: rule.isEnabled) {
                rule.homeKitTriggerID = triggerID
            } else {
                rule.executionMode = "inApp"   // fallback se HomeKit fallisce
            }
        }

        let context = modelContainer.mainContext   // usa mainContext, non un context nuovo
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
