import Foundation
import HomeKit

@MainActor
enum AutomationProposalMapper {
    private struct Draft {
        var source: AutomationProposalSource
        var title: String
        var explanation: String
        var confidence: Double?
        var triggerType: String
        var triggerTime: String?
        var triggerWeekdays: [Int]
        var sensorType: String?
        var sensorRoom: String
        var sensorAccessoryName: String?
        var sensorThreshold: Double?
        var sensorDirection: String?
        var accessoryIDString: String?
        var actionRaw: String
        var actionValue: Double?
        var actionValue2: Double?
        var sceneName: String?
        var scheduleKind: String?
        var scheduleOffsetMinutes: Int
        var presenceKind: String?
        var presenceUserScope: String?
        /// Trigger "accessoryState" (sequenze A→B): nome dell'accessorio causa
        /// e stato che innesca (true = si accende/attiva).
        var triggerAccessoryName: String? = nil
        var triggerAccessoryActive: Bool? = nil
        /// P2 v2 — condizioni contestuali oltre la primaria (che vive nei campi
        /// sensorType/Threshold/Direction). Risolte per (tipo, stanza): late binding,
        /// nessun ID HomeKit.
        var secondaryConditions: [ContextualCondition] = []
        /// Nome dell'accessorio effetto: fallback di risoluzione quando l'UUID non
        /// corrisponde a nessun accessorio locale (gli identifier HomeKit sono
        /// per-device: le opportunity sincronizzate da un altro device arrivano
        /// con UUID estranei).
        var effectAccessoryName: String? = nil
    }

    static func chatbotProposal(
        label: String,
        naturalLanguage: String,
        accessoryID: String,
        action: String,
        value: Double?,
        value2: Double?,
        triggerType: String,
        triggerTime: String?,
        triggerWeekdaysRaw: String?,
        triggerSensorType: String?,
        triggerSensorRoom: String?,
        triggerSensorAccessoryName: String? = nil,
        triggerThreshold: Double?,
        triggerDirection: String?,
        triggerConditionsRaw: String? = nil,
        sceneName: String?,
        triggerScheduleKind: String? = nil,
        triggerOffsetMinutes: Int = 0,
        triggerPresenceKind: String? = nil,
        triggerPresenceUserScope: String? = nil,
        semanticKey: String,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        var draft = Draft(
            source: .chatbot,
            title: label,
            explanation: naturalLanguage,
            confidence: nil,
            triggerType: triggerType,
            triggerTime: triggerTime,
            triggerWeekdays: normalizedWeekdays(from: triggerWeekdaysRaw),
            sensorType: triggerSensorType,
            sensorRoom: triggerSensorRoom ?? "",
            sensorAccessoryName: triggerSensorAccessoryName,
            sensorThreshold: triggerThreshold,
            sensorDirection: triggerDirection,
            accessoryIDString: accessoryID,
            actionRaw: action,
            actionValue: value,
            actionValue2: value2,
            sceneName: sceneName,
            scheduleKind: triggerScheduleKind,
            scheduleOffsetMinutes: triggerOffsetMinutes,
            presenceKind: triggerPresenceKind,
            presenceUserScope: triggerPresenceUserScope
        )

        if triggerType == "characteristic",
           let raw = triggerConditionsRaw,
           let parsed = ContextualCondition.parseConditions(fromSignature: raw),
           let primary = parsed.first {
            if !primary.roomName.isEmpty {
                draft.sensorRoom = primary.roomName
            }
            draft.secondaryConditions = Array(parsed.dropFirst())
        }

        return proposal(from: draft, capabilities: capabilities, scenes: scenes)
    }

    static func chatbotAction(
        accessoryID: String,
        action: String,
        value: Double?,
        value2: Double?
    ) -> AutomationProposalAction? {
        let draft = Draft(
            source: .chatbot,
            title: "",
            explanation: "",
            confidence: nil,
            triggerType: "inApp",
            triggerTime: nil,
            triggerWeekdays: Array(1...7),
            sensorType: nil,
            sensorRoom: "",
            sensorAccessoryName: nil,
            sensorThreshold: nil,
            sensorDirection: nil,
            accessoryIDString: accessoryID,
            actionRaw: action,
            actionValue: value,
            actionValue2: value2,
            sceneName: nil,
            scheduleKind: nil,
            scheduleOffsetMinutes: 0,
            presenceKind: nil,
            presenceUserScope: nil
        )
        var limitations: [String] = []
        return self.action(from: draft, capabilities: [], scenes: [], limitations: &limitations)
    }

    static func proposal(
        from opportunity: AutomationOpportunity,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem],
        sourcePattern: BehavioralPattern? = nil
    ) -> AutomationProposal {
        var draft = Draft(
            source: source(from: opportunity.origin),
            title: opportunity.title,
            explanation: opportunity.naturalLanguage,
            confidence: opportunity.confidence,
            triggerType: opportunity.triggerType,
            triggerTime: opportunity.triggerTime ?? opportunity.avgTimeString,
            triggerWeekdays: opportunity.triggerWeekdays,
            sensorType: opportunity.triggerSensorType,
            sensorRoom: opportunity.roomName,
            sensorAccessoryName: nil,
            sensorThreshold: opportunity.triggerThreshold,
            sensorDirection: opportunity.triggerDirection,
            accessoryIDString: opportunity.effectAccessoryIDString,
            actionRaw: opportunity.effectActionRaw,
            actionValue: opportunity.effectValue,
            actionValue2: opportunity.effectValue2,
            sceneName: opportunity.effectSceneName,
            scheduleKind: nil,
            scheduleOffsetMinutes: 0,
            presenceKind: nil,
            presenceUserScope: nil
        )

        // Sequenze A→B: la causa vive nel pattern sorgente (nome + azione dalla signature).
        if opportunity.triggerType == "accessoryState", let pattern = sourcePattern {
            draft.triggerAccessoryName = pattern.causeName
            draft.triggerAccessoryActive = pattern.causeSignature.flatMap(causeTriggerState(fromSignature:))
        }

        draft.effectAccessoryName = sourcePattern?.accessoryName

        // P2 v2 — condizioni multiple: vivono nell'opportunità stessa (autosufficiente),
        // NON nel pattern sorgente, che per i contestuali è effimero (UUID nuovo a ogni
        // run → patternID dangling su opportunità snoozed o sincronizzate).
        if opportunity.triggerType == "characteristic",
           let raw = opportunity.triggerConditionsRaw,
           let conditions = ContextualCondition.parseConditions(fromSignature: raw),
           let primary = conditions.first {
            if !primary.roomName.isEmpty {
                draft.sensorRoom = primary.roomName
            }
            draft.secondaryConditions = Array(conditions.dropFirst())
        }

        return proposal(from: draft, capabilities: capabilities, scenes: scenes)
    }

    /// Stato che innesca la sequenza, estratto dalla causeSignature
    /// ("eventType:accessoryName:action"): true = attivazione, false = spegnimento.
    /// Nil per azioni non riconducibili a uno stato on/off (trigger non costruibile).
    static func causeTriggerState(fromSignature signature: String) -> Bool? {
        let parts = signature.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, let action = parts.last else { return nil }
        switch action {
        case "on", "activate", "dim", "open", "unlock":
            return true
        case "off", "close", "lock":
            return false
        default:
            return nil
        }
    }

    /// Livello B: proposta da un suggerimento dell'interprete LLM.
    /// Il target è già risolto in UUID dal servizio (match nome normalizzato).
    static func proposal(
        from suggestion: HabitInterpreterCore.RoutineSuggestion,
        targetAccessoryID: UUID?,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        let draft = Draft(
            source: .opportunity,
            title: suggestion.title,
            explanation: suggestion.explanation,
            confidence: nil,
            triggerType: suggestion.triggerType,
            triggerTime: suggestion.triggerTime,
            triggerWeekdays: suggestion.weekdays ?? Array(1...7),
            sensorType: nil,
            sensorRoom: "",
            sensorAccessoryName: nil,
            sensorThreshold: nil,
            sensorDirection: nil,
            accessoryIDString: targetAccessoryID?.uuidString,
            actionRaw: suggestion.action,
            actionValue: nil,
            actionValue2: nil,
            sceneName: nil,
            scheduleKind: nil,
            scheduleOffsetMinutes: 0,
            presenceKind: nil,
            presenceUserScope: nil,
            triggerAccessoryName: suggestion.triggerAccessoryName,
            triggerAccessoryActive: suggestion.triggerType == "accessoryState" ? true : nil
        )
        return proposal(from: draft, capabilities: capabilities, scenes: scenes)
    }

    /// Pivot evidenze: costruisce una proposta dall'evidenza d'uso osservata.
    /// L'utente è il giudice — la proposta arriva pre-compilata (orario = inizio
    /// finestra, giorni dal pattern) e si rifinisce nel wizard esistente.
    static func proposal(
        from evidence: UsageEvidenceBuilder.Evidence,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        let time = String(format: "%02d:%02d",
                          evidence.windowStartMinute / 60,
                          evidence.windowStartMinute % 60)
        let endTime = String(format: "%02d:%02d",
                             evidence.windowEndMinute / 60,
                             evidence.windowEndMinute % 60)

        let weekdays: [Int]
        switch evidence.weekdayPattern {
        case .everyDay:      weekdays = Array(1...7)
        case .weekdays:      weekdays = [2, 3, 4, 5, 6]
        case .weekend:       weekdays = [1, 7]
        case .days(let set): weekdays = set.sorted()
        }

        let draft = Draft(
            source: .opportunity,
            title: String(format: String(localized: "evidence.proposal.title",
                                         defaultValue: "Turn on %@ at %@"),
                          evidence.accessoryName, time),
            explanation: String(format: String(localized: "evidence.proposal.explanation",
                                               defaultValue: "Observed on between %@ and %@ on %d different days over the last %d days."),
                                time, endTime, evidence.distinctDays, evidence.observedSpanDays),
            confidence: nil,
            triggerType: "calendar",
            triggerTime: time,
            triggerWeekdays: weekdays,
            sensorType: nil,
            sensorRoom: evidence.roomName ?? "",
            sensorAccessoryName: nil,
            sensorThreshold: nil,
            sensorDirection: nil,
            accessoryIDString: evidence.accessoryID.uuidString,
            actionRaw: "on",
            actionValue: nil,
            actionValue2: nil,
            sceneName: nil,
            scheduleKind: nil,
            scheduleOffsetMinutes: 0,
            presenceKind: nil,
            presenceUserScope: nil
        )

        return proposal(from: draft, capabilities: capabilities, scenes: scenes)
    }

    static func proposal(
        from pattern: HabitPattern,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        let legacy = legacyHabitDraft(from: pattern)
        let draft = Draft(
            source: .opportunity,
            title: pattern.displayTitle,
            explanation: pattern.patternDescription,
            confidence: pattern.confidence,
            triggerType: legacy.triggerType,
            triggerTime: legacy.triggerTime,
            triggerWeekdays: legacy.weekdays,
            sensorType: nil,
            sensorRoom: pattern.roomName,
            sensorAccessoryName: nil,
            sensorThreshold: nil,
            sensorDirection: nil,
            accessoryIDString: pattern.patternType == .scene ? nil : pattern.accessoryID.uuidString,
            actionRaw: legacy.actionRaw,
            actionValue: legacy.actionValue,
            actionValue2: legacy.actionValue2,
            sceneName: pattern.sceneName,
            scheduleKind: nil,
            scheduleOffsetMinutes: 0,
            presenceKind: nil,
            presenceUserScope: nil
        )

        return proposal(from: draft, capabilities: capabilities, scenes: scenes)
    }

    static func proposal(
        from pattern: BehavioralPattern,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        var draft = Draft(
            source: .opportunity,
            title: pattern.localizedTitle,
            explanation: pattern.naturalLanguageDescription,
            confidence: pattern.confidence,
            triggerType: triggerType(for: pattern),
            triggerTime: pattern.avgTimeString,
            triggerWeekdays: pattern.weekdays,
            sensorType: nil,
            sensorRoom: pattern.roomName,
            sensorAccessoryName: nil,
            sensorThreshold: nil,
            sensorDirection: nil,
            accessoryIDString: pattern.patternType == .scene ? nil : pattern.accessoryID?.uuidString,
            actionRaw: pattern.action.rawValue,
            actionValue: actionValue(for: pattern),
            actionValue2: nil,
            sceneName: sceneName(for: pattern),
            scheduleKind: nil,
            scheduleOffsetMinutes: 0,
            presenceKind: nil,
            presenceUserScope: nil
        )

        if pattern.patternType == .sequential {
            draft.triggerAccessoryName = pattern.causeName
            draft.triggerAccessoryActive = pattern.causeSignature.flatMap(causeTriggerState(fromSignature:))
        }

        if pattern.patternType != .scene {
            draft.effectAccessoryName = pattern.accessoryName
        }

        return proposal(from: draft, capabilities: capabilities, scenes: scenes)
    }

    private static func proposal(
        from draft: Draft,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        var limitations: [String] = []
        var startEvents: [AutomationProposalStartEvent] = []
        var conditions: [AutomationProposalCondition] = []
        var actions: [AutomationProposalAction] = []

        if let startEvent = startEvent(from: draft, capabilities: capabilities, limitations: &limitations) {
            startEvents.append(startEvent)
        }

        // Condizione sensore sulle proposte calendar: è un ARRICCHIMENTO OPZIONALE
        // (le condizioni non sono obbligatorie). Il tentativo non deve sporcare le
        // limitations — "does not include a complete sensor condition" compariva
        // su OGNI abitudine temporale. Diventa un limite reale solo se il draft
        // aveva davvero un sensore e questo non si risolve più in HomeKit.
        if draft.triggerType == "calendar" {
            var attempt: [String] = []
            if let sensorCondition = sensorSelection(from: draft, requiredRole: .condition, capabilities: capabilities, limitations: &attempt) {
                conditions.append(.accessory(sensorCondition))
            } else if draft.sensorType != nil {
                limitations.append(contentsOf: attempt)
            }
        }

        if draft.triggerType != "presence",
           draft.presenceKind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            conditions.append(.presence(presenceCondition(from: draft)))
        }

        // P2 v2 — coppia contestuale: OR degli attraversamenti (start events multipli,
        // copre entrambi gli ordini di arrivo) + AND delle condizioni (predicato
        // composto, conditionJoinMode .all). Una secondaria non risolvibile produce
        // una limitation esplicita nel wizard, MAI un drop silenzioso: l'utente non
        // deve approvare un'automazione diversa da quella descritta sulla card.
        if draft.triggerType == "characteristic", !draft.secondaryConditions.isEmpty, !startEvents.isEmpty {
            var probe: [String] = []  // esiti dei tentativi opzionali: non sono limiti della proposta
            let primaryAsCondition = sensorSelection(
                sensorType: draft.sensorType,
                roomName: draft.sensorRoom,
                accessoryName: draft.sensorAccessoryName,
                threshold: draft.sensorThreshold,
                direction: draft.sensorDirection,
                requiredRole: .condition,
                capabilities: capabilities,
                limitations: &probe
            )

            var addedSecondary = false
            for secondary in draft.secondaryConditions {
                let room = secondary.roomName.isEmpty ? draft.sensorRoom : secondary.roomName
                var attempt: [String] = []
                guard let conditionSelection = sensorSelection(
                    sensorType: secondary.sensorTypeRaw,
                    roomName: room,
                    accessoryName: nil,
                    threshold: secondary.threshold,
                    direction: secondary.direction,
                    requiredRole: .condition,
                    capabilities: capabilities,
                    limitations: &attempt
                ) else {
                    let typeName = SensorServiceType(rawValue: secondary.sensorTypeRaw)?.displayName ?? secondary.sensorTypeRaw
                    let label = "\(typeName) (\(room)) \(secondary.direction == "above" ? ">" : "<") \(secondary.threshold)"
                    limitations.append(String(
                        format: String(localized: "automation.proposal.limit.secondaryCondition",
                                       defaultValue: "The additional condition (%@) could not be resolved in HomeKit — the automation will be created without it."),
                        label
                    ))
                    continue
                }
                conditions.append(.accessory(conditionSelection))
                addedSecondary = true

                // Attraversamento della secondaria come start event SOLO se la primaria
                // è disponibile come condizione: altrimenti l'automazione scatterebbe
                // sulla secondaria senza verificare la primaria.
                if primaryAsCondition != nil,
                   let triggerSelection = sensorSelection(
                       sensorType: secondary.sensorTypeRaw,
                       roomName: room,
                       accessoryName: nil,
                       threshold: secondary.threshold,
                       direction: secondary.direction,
                       requiredRole: .trigger,
                       capabilities: capabilities,
                       limitations: &probe
                   ) {
                    startEvents.append(.accessory(triggerSelection))
                }
            }

            if addedSecondary, let primaryAsCondition {
                conditions.append(.accessory(primaryAsCondition))
            }
        }

        if let action = action(from: draft, capabilities: capabilities, scenes: scenes, limitations: &limitations) {
            actions.append(action)
        }

        let unsupportedReason: String?
        if startEvents.isEmpty {
            unsupportedReason = String(localized: "automation.proposal.unsupported.trigger", defaultValue: "This opportunity cannot be converted because its trigger is not supported by the automation builder yet.")
        } else if actions.isEmpty {
            unsupportedReason = String(localized: "automation.proposal.unsupported.action", defaultValue: "This opportunity cannot be converted because its action is not supported by the automation builder yet.")
        } else {
            unsupportedReason = nil
        }

        return AutomationProposal(
            source: draft.source,
            title: draft.title,
            explanation: draft.explanation,
            confidence: draft.confidence,
            startEvents: startEvents,
            conditions: conditions,
            conditionJoinMode: .all,
            actions: actions,
            limitations: limitations,
            requiresUserReview: true,
            unsupportedReason: unsupportedReason,
            shouldEnableAutomation: true
        )
    }

    private static func source(from origin: OpportunityOrigin) -> AutomationProposalSource {
        switch origin {
        case .detected, .contextual:
            return .opportunity
        case .conversational:
            return .chatbot
        }
    }

    private static func triggerType(for pattern: BehavioralPattern) -> String {
        switch pattern.patternType {
        case .sequential:
            return "accessoryState"
        case .contextual:
            return "characteristic"
        case .temporal, .lighting, .scene:
            return "calendar"
        }
    }

    private static func actionValue(for pattern: BehavioralPattern) -> Double? {
        switch pattern.action {
        case .dim:
            return pattern.numericValue
        default:
            return nil
        }
    }

    private static func sceneName(for pattern: BehavioralPattern) -> String? {
        guard pattern.patternType == .scene else { return nil }
        return pattern.causeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? pattern.causeName
            : pattern.accessoryName
    }

    private static func startEvent(
        from draft: Draft,
        capabilities: [AutomationCapabilityDescriptor],
        limitations: inout [String]
    ) -> AutomationProposalStartEvent? {
        switch draft.triggerType {
        case "calendar":
            guard let schedule = schedule(from: draft) else {
                limitations.append(String(localized: "automation.proposal.limit.missingTime", defaultValue: "The opportunity does not include a valid trigger time."))
                return nil
            }
            return .schedule(schedule)

        case "characteristic":
            guard let selection = sensorSelection(from: draft, requiredRole: .trigger, capabilities: capabilities, limitations: &limitations) else {
                return nil
            }
            return .accessory(selection)

        case "presence", "people":
            return .presence(presenceTrigger(from: draft))

        case "accessoryState":
            guard let selection = accessoryStateSelection(from: draft, capabilities: capabilities, limitations: &limitations) else {
                return nil
            }
            return .accessory(selection)

        default:
            limitations.append(String(localized: "automation.proposal.limit.inAppTrigger", defaultValue: "In-app triggers need to be reviewed before they can become HomeKit automations."))
            return nil
        }
    }

    /// Selezione trigger per le sequenze A→B: la capability boolean (power/active)
    /// dell'accessorio causa, risolta per nome (match esatto, poi contains).
    private static func accessoryStateSelection(
        from draft: Draft,
        capabilities: [AutomationCapabilityDescriptor],
        limitations: inout [String]
    ) -> AutomationProposalCapabilitySelection? {
        guard let causeName = draft.triggerAccessoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !causeName.isEmpty,
              let triggersOnActive = draft.triggerAccessoryActive else {
            limitations.append(String(localized: "automation.proposal.limit.missingCauseAccessory", defaultValue: "The triggering accessory of this sequence could not be resolved."))
            return nil
        }

        let candidates = capabilities.filter { capability in
            guard capability.supportedRoles.contains(.trigger) else { return false }
            if case .boolean = capability.valueKind { return true }
            return false
        }

        let normalizedCause = causeName.lowercased()
        let capability = candidates.first { $0.accessoryName.lowercased() == normalizedCause }
            ?? candidates.first { $0.accessoryName.lowercased().contains(normalizedCause) || normalizedCause.contains($0.accessoryName.lowercased()) }

        guard let capability else {
            limitations.append(String(localized: "automation.proposal.limit.missingCauseAccessory", defaultValue: "The triggering accessory of this sequence could not be resolved."))
            return nil
        }

        return AutomationProposalCapabilitySelection(
            capabilityID: capability.id,
            accessoryID: capability.accessoryID,
            characteristicID: capability.characteristicID,
            comparisonOperator: triggersOnActive ? .becomesActive : .becomesInactive,
            targetValue: .bool(triggersOnActive)
        )
    }

    private static func presenceTrigger(from draft: Draft) -> AutomationProposalPresenceTrigger {
        let kind: AutomationProposalPresenceTriggerKind
        switch draft.presenceKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "everyexit", "exit", "leave", "leaves", "esco", "uscita":
            kind = .everyExit
        case "firstentry", "first", "firstarrives":
            kind = .firstEntry
        case "lastexit", "last", "lastleaves":
            kind = .lastExit
        default:
            kind = .everyEntry
        }

        let userScope: AutomationProposalPresenceUserScope
        switch draft.presenceUserScope?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "homeusers", "anyone", "tutti", "chiunque":
            userScope = .homeUsers
        default:
            userScope = .currentUser
        }

        return AutomationProposalPresenceTrigger(kind: kind, userScope: userScope)
    }

    private static func presenceCondition(from draft: Draft) -> AutomationProposalPresenceCondition {
        let kind: AutomationProposalPresenceConditionKind
        switch draft.presenceKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "notathome", "away", "empty", "nobody", "noone", "nessuno", "fuori", "assente",
             "everyexit", "exit", "leave", "leaves", "esco", "uscita", "lastexit", "last", "lastleaves":
            kind = .notAtHome
        default:
            kind = .atHome
        }

        let userScope: AutomationProposalPresenceUserScope
        switch draft.presenceUserScope?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "currentuser", "me", "io":
            userScope = .currentUser
        default:
            userScope = .homeUsers
        }

        return AutomationProposalPresenceCondition(kind: kind, userScope: userScope)
    }

    private static func schedule(from draft: Draft) -> AutomationProposalSchedule? {
        if let kind = scheduleKind(from: draft.scheduleKind),
           kind != .fixedTime {
            return AutomationProposalSchedule(
                kind: kind,
                offsetMinutes: draft.scheduleOffsetMinutes,
                weekdays: Set(draft.triggerWeekdays)
            )
        }

        guard let time = draft.triggerTime,
              let components = timeComponents(from: time) else {
            return nil
        }

        return AutomationProposalSchedule(
            kind: .fixedTime,
            hour: components.hour,
            minute: components.minute,
            offsetMinutes: draft.scheduleOffsetMinutes,
            weekdays: Set(draft.triggerWeekdays)
        )
    }

    private static func sensorSelection(
        from draft: Draft,
        requiredRole: AutomationCapabilityRole,
        capabilities: [AutomationCapabilityDescriptor],
        limitations: inout [String]
    ) -> AutomationProposalCapabilitySelection? {
        sensorSelection(
            sensorType: draft.sensorType,
            roomName: draft.sensorRoom,
            accessoryName: draft.sensorAccessoryName,
            threshold: draft.sensorThreshold,
            direction: draft.sensorDirection,
            requiredRole: requiredRole,
            capabilities: capabilities,
            limitations: &limitations
        )
    }

    private static func sensorSelection(
        sensorType: String?,
        roomName: String,
        accessoryName: String?,
        threshold: Double?,
        direction: String?,
        requiredRole: AutomationCapabilityRole,
        capabilities: [AutomationCapabilityDescriptor],
        limitations: inout [String]
    ) -> AutomationProposalCapabilitySelection? {
        guard let sensorType else {
            limitations.append(String(localized: "automation.proposal.limit.missingSensor", defaultValue: "The opportunity does not include a complete sensor condition."))
            return nil
        }

        guard let capability = capability(
            forSensorType: sensorType,
            roomName: roomName,
            accessoryName: accessoryName,
            requiredRole: requiredRole,
            capabilities: capabilities
        ) else {
            limitations.append(String(localized: "automation.proposal.limit.sensorUnavailable", defaultValue: "The proposed sensor is no longer available in HomeKit."))
            return nil
        }

        let comparisonOperator: AutomationProposalOperator
        let target: AutomationProposalTargetValue
        let normalizedDirection = direction?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch capability.valueKind {
        case .boolean:
            let inactiveDirections = ["below", "inactive", "closed", "clear", "off", "false"]
            let isInactiveTarget = inactiveDirections.contains(normalizedDirection)
            comparisonOperator = isInactiveTarget ? .becomesInactive : .becomesActive
            target = .bool(!isInactiveTarget)
        case .numeric, .state:
            guard let threshold else {
                limitations.append(String(localized: "automation.proposal.limit.missingSensor", defaultValue: "The opportunity does not include a complete sensor condition."))
                return nil
            }
            comparisonOperator = normalizedDirection == "below"
                ? .lessThan
                : .greaterThan
            target = targetValue(threshold, for: capability)
        }

        return AutomationProposalCapabilitySelection(
            capabilityID: capability.id,
            accessoryID: capability.accessoryID,
            characteristicID: capability.characteristicID,
            comparisonOperator: comparisonOperator,
            targetValue: target
        )
    }

    private static func capability(
        forSensorType sensorType: String,
        roomName: String,
        accessoryName: String?,
        requiredRole: AutomationCapabilityRole,
        capabilities: [AutomationCapabilityDescriptor]
    ) -> AutomationCapabilityDescriptor? {
        let hmType = SensorServiceType(rawValue: sensorType)?.hmCharacteristicType
            ?? sensorKindCharacteristicType(from: sensorType)
        let normalizedRoom = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccessory = accessoryName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = capabilities.filter { capability in
            guard capability.supportedRoles.contains(requiredRole) else {
                return false
            }

            let matchesType: Bool
            if let hmType, !hmType.isEmpty {
                matchesType = capability.characteristicType.caseInsensitiveCompare(hmType) == .orderedSame
            } else {
                matchesType = capability.title.localizedCaseInsensitiveContains(sensorType)
            }

            let matchesRoom = normalizedRoom.isEmpty ||
                capability.roomName.localizedCaseInsensitiveCompare(normalizedRoom) == .orderedSame
            let matchesAccessory = normalizedAccessory?.isEmpty != false ||
                capability.accessoryName.localizedCaseInsensitiveContains(normalizedAccessory ?? "") ||
                capability.title.localizedCaseInsensitiveContains(normalizedAccessory ?? "")
            return matchesType && matchesRoom && matchesAccessory
        }

        return candidates.first
    }

    private static func sensorKindCharacteristicType(from raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "contact", "contactsensor", "door", "doorstate", "window":
            return HMCharacteristicTypeContactState
        case "motion", "motionsensor", "movement", "presenza movimento":
            return HMCharacteristicTypeMotionDetected
        case "occupancy", "presence", "presenza":
            return HMCharacteristicTypeOccupancyDetected
        case "leak", "water":
            return HMCharacteristicTypeLeakDetected
        case "smoke":
            return HMCharacteristicTypeSmokeDetected
        case "pm2.5", "pm 2.5", "pm25", "particulate2.5":
            return HMCharacteristicTypePM2_5Density
        case "pm10", "pm 10", "particulate10":
            return HMCharacteristicTypePM10Density
        default:
            return nil
        }
    }

    private static func scheduleKind(from raw: String?) -> AutomationProposalScheduleKind? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sunrise", "alba":
            return .sunrise
        case "sunset", "tramonto":
            return .sunset
        case "fixedtime", "fixed", "time", "orario":
            return .fixedTime
        default:
            return nil
        }
    }

    private static func targetValue(
        _ raw: Double,
        for capability: AutomationCapabilityDescriptor
    ) -> AutomationProposalTargetValue {
        switch capability.valueKind {
        case .boolean:
            return .bool(raw != 0)
        case .numeric:
            return .number(raw)
        case .state:
            return .state(Int(raw.rounded()))
        }
    }

    private static func action(
        from draft: Draft,
        capabilities: [AutomationCapabilityDescriptor],
        scenes: [SceneItem],
        limitations: inout [String]
    ) -> AutomationProposalAction? {
        if let sceneName = draft.sceneName,
           !sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let scene = scenes.first { $0.name.localizedCaseInsensitiveCompare(sceneName) == .orderedSame }
            return .scene(AutomationProposalSceneReference(sceneID: scene?.id, name: sceneName))
        }

        let parsedID = draft.accessoryIDString.flatMap(UUID.init(uuidString:))

        // Con un catalogo capability disponibile, un UUID che non corrisponde a
        // nessun accessorio locale è tipico delle opportunity sincronizzate da un
        // altro device (gli identifier HomeKit sono per-device): si riabbina per
        // nome+stanza invece di produrre una proposta senza azioni.
        let accessoryID: UUID
        if let parsedID,
           capabilities.isEmpty || capabilities.contains(where: { $0.accessoryID == parsedID }) {
            accessoryID = parsedID
        } else if let fallbackID = effectAccessoryID(
            named: draft.effectAccessoryName,
            roomName: draft.sensorRoom,
            capabilities: capabilities
        ) {
            accessoryID = fallbackID
        } else {
            limitations.append(String(localized: "automation.proposal.limit.missingActionTarget", defaultValue: "The opportunity does not include a valid action target."))
            return nil
        }

        switch draft.actionRaw {
        case "on":
            return accessoryAction(accessoryID: accessoryID, kind: .turnOn)
        case "activate":
            return accessoryAction(accessoryID: accessoryID, kind: .activate)
        case "off":
            return accessoryAction(accessoryID: accessoryID, kind: .turnOff)
        case "dim":
            return accessoryAction(accessoryID: accessoryID, kind: .dim, value: draft.actionValue)
        case "setMode":
            return accessoryAction(
                accessoryID: accessoryID,
                kind: .setMode,
                value: draft.actionValue,
                secondaryValue: draft.actionValue2
            )
        case "setTemp":
            return accessoryAction(accessoryID: accessoryID, kind: .setTemperature, value: draft.actionValue)
        case "setSpeed":
            return accessoryAction(accessoryID: accessoryID, kind: .setFanSpeed, value: draft.actionValue)
        case "setHumidity":
            return accessoryAction(accessoryID: accessoryID, kind: .setHumidity, value: draft.actionValue)
        case "open", "openGarage":
            return accessoryAction(accessoryID: accessoryID, kind: .open)
        case "close", "closeGarage":
            return accessoryAction(accessoryID: accessoryID, kind: .close)
        case "lock":
            return accessoryAction(accessoryID: accessoryID, kind: .lock)
        case "unlock":
            return accessoryAction(accessoryID: accessoryID, kind: .unlock)
        case "armStay":
            return accessoryAction(accessoryID: accessoryID, kind: .setMode, value: Double(SecurityMode.stay.rawValue))
        case "armAway":
            return accessoryAction(accessoryID: accessoryID, kind: .setMode, value: Double(SecurityMode.away.rawValue))
        case "armNight":
            return accessoryAction(accessoryID: accessoryID, kind: .setMode, value: Double(SecurityMode.night.rawValue))
        case "disarm":
            return accessoryAction(accessoryID: accessoryID, kind: .setMode, value: Double(SecurityMode.disarm.rawValue))
        default:
            limitations.append(String(localized: "automation.proposal.limit.unsupportedAction", defaultValue: "This action needs the advanced accessory editor and is not converted automatically yet."))
            return nil
        }
    }

    /// Risoluzione dell'accessorio effetto per nome (match esatto, poi contains),
    /// preferendo la stessa stanza del trigger quando più accessori condividono il nome.
    private static func effectAccessoryID(
        named accessoryName: String?,
        roomName: String,
        capabilities: [AutomationCapabilityDescriptor]
    ) -> UUID? {
        guard let accessoryName = accessoryName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessoryName.isEmpty else {
            return nil
        }

        let normalizedName = accessoryName.lowercased()
        let normalizedRoom = roomName.trimmingCharacters(in: .whitespacesAndNewlines)

        let exact = capabilities.filter { $0.accessoryName.lowercased() == normalizedName }
        let candidates = exact.isEmpty
            ? capabilities.filter {
                $0.accessoryName.lowercased().contains(normalizedName) ||
                normalizedName.contains($0.accessoryName.lowercased())
            }
            : exact

        let sameRoom = candidates.first {
            !normalizedRoom.isEmpty &&
            $0.roomName.localizedCaseInsensitiveCompare(normalizedRoom) == .orderedSame
        }
        return (sameRoom ?? candidates.first)?.accessoryID
    }

    private static func accessoryAction(
        accessoryID: UUID,
        kind: AutomationProposalAccessoryActionKind,
        value: Double? = nil,
        secondaryValue: Double? = nil
    ) -> AutomationProposalAction {
        .accessory(AutomationProposalAccessoryAction(
            accessoryID: accessoryID,
            kind: kind,
            value: value,
            secondaryValue: secondaryValue
        ))
    }

    private static func timeComponents(from text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    private struct LegacyHabitDraft {
        var triggerType: String
        var triggerTime: String?
        var weekdays: [Int]
        var actionRaw: String
        var actionValue: Double?
        var actionValue2: Double?
    }

    private static func legacyHabitDraft(from pattern: HabitPattern) -> LegacyHabitDraft {
        guard let data = pattern.suggestedRuleJSON.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return LegacyHabitDraft(
                triggerType: "calendar",
                triggerTime: nil,
                weekdays: Array(1...7),
                actionRaw: "on",
                actionValue: nil,
                actionValue2: nil
            )
        }

        let action = dict["action"] as? String
            ?? dict["actionType"] as? String
            ?? "on"
        let explicitValue = dict["value"] as? Double
            ?? dict["actionValue"] as? Double
        let parsed = parseLegacyAction(action, explicitValue: explicitValue)

        return LegacyHabitDraft(
            triggerType: dict["triggerType"] as? String ?? "calendar",
            triggerTime: dict["time"] as? String ?? dict["triggerTime"] as? String,
            weekdays: dict["weekdays"] as? [Int] ?? dict["triggerWeekdays"] as? [Int] ?? Array(1...7),
            actionRaw: parsed.action,
            actionValue: parsed.value,
            actionValue2: dict["actionValue2"] as? Double
        )
    }

    private static func parseLegacyAction(
        _ action: String,
        explicitValue: Double?
    ) -> (action: String, value: Double?) {
        if action.hasPrefix("dim:") {
            let percentageText = action.dropFirst(4)
            let percentage = Double(percentageText) ?? 30
            return ("dim", percentage / 100)
        }
        return (action, explicitValue)
    }

    private static func normalizedWeekdays(from values: [Int]) -> Set<Int> {
        let normalized = values.filter { (1...7).contains($0) }
        return normalized.isEmpty ? Set(1...7) : Set(normalized)
    }

    private static func normalizedWeekdays(from raw: String?) -> [Int] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(1...7)
        }

        let values = raw
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { (1...7).contains($0) }

        return values.isEmpty ? Array(1...7) : values
    }
}
