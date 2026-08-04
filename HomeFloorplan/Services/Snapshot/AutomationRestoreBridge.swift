import Foundation
import HomeKit

// MARK: - AutomationRestoreBridge

/// Il ponte fra un'automazione viva e la sua forma salvabile, in entrambi i
/// versi.
///
/// **Il filtro non è una lista di casi scritta a mano.** Un'automazione entra
/// nel backup ripristinabile se `AutomationWizardEditDraft` riesce a decodificarla
/// — che è lo stesso controllo con cui l'app decide se può aprirtela in
/// modifica. Se non sa riaprirla non sa nemmeno ricrearla, e riusare quel
/// giudizio evita che i due divergano alla prima automazione strana.
@MainActor
enum AutomationRestoreBridge {

    // MARK: - Cattura

    /// La forma salvabile, **oppure il motivo per cui non c'è**.
    ///
    /// Il motivo va registrato, non dedotto dopo: le ragioni per cui si rinuncia
    /// sono diverse — non esegue una scena, ha condizioni che non so esprimere,
    /// è un geofence — e indovinarne una guardando il tipo di contenuto produce
    /// spiegazioni false, che è peggio di nessuna spiegazione.
    static func restorable(from trigger: HMTrigger,
                           capabilities: [AutomationCharacteristicCapability],
                           serials: [UUID: String],
                           readableActions: [SceneActionSnapshot]) -> (plan: RestorableAutomation?, reason: String?) {
        let item = AutomationItem(trigger: trigger)
        guard let draft = AutomationWizardEditDraft(item: item, capabilities: capabilities) else {
            return (nil, String(localized: "automationCapture.skip.undecodable",
                                defaultValue: "this app cannot read its trigger in full — it cannot be opened for editing either"))
        }
        // Una scena vera, oppure le azioni dirette. Il builder sa creare
        // entrambe le forme, quindi non avere una scena non è un motivo di
        // scarto: lo è non avere **niente** da eseguire.
        let ownScene = trigger.actionSets.first { !HomeKitAutomationsService.isTriggerOwned($0) }
        let sceneName = ownScene?.name
        let inlineActions = sceneName == nil ? readableActions : []
        guard sceneName != nil || !inlineActions.isEmpty else {
            return (nil, String(localized: "automationCapture.skip.nothingToRun",
                                defaultValue: "there is nothing readable for it to run: no scene, and no action this app can read"))
        }

        var startEvents: [RestorableAutomation.StartEvent] = []
        for event in draft.startEvents {
            switch event.kind {
            case .accessory:
                guard let selection = event.selection,
                      let ref = capabilityRef(from: selection, serials: serials) else {
                    return (nil, String(localized: "automationCapture.skip.event",
                                        defaultValue: "one of its start events could not be described"))
                }
                startEvents.append(.accessory(ref))
            case .time:
                startEvents.append(.schedule(schedule(from: event.schedule)))
            case .people:
                startEvents.append(.presence(kind: event.presence.kind.rawValue,
                                             userScope: event.presence.userScope.rawValue))
            case .location:
                // Un geofence ricreato in silenzio da coordinate salvate è il
                // tipo di cosa che si scopre sbagliata quando non scatta.
                return (nil, String(localized: "automationCapture.skip.location",
                                    defaultValue: "it uses a location, and recreating a geofence silently is not safe"))
            }
        }
        guard !startEvents.isEmpty else {
            return (nil, String(localized: "automationCapture.skip.noEvents",
                                defaultValue: "no start event could be read"))
        }

        // Se una condizione non si riesce a esprimere, l'automazione **non** è
        // ripristinabile: ricrearla senza è ricreare qualcosa di diverso col suo
        // nome sopra.
        var conditions: [RestorableAutomation.CapabilityRef] = []
        for selection in draft.conditionSelections {
            guard let ref = capabilityRef(from: selection, serials: serials) else {
                return (nil, String(localized: "automationCapture.skip.condition",
                                    defaultValue: "one of its conditions could not be described, and recreating it without would change what it does"))
            }
            conditions.append(ref)
        }
        // Orario e presenza sono valori semplici e il servizio li accetta già
        // in creazione: salvarli costa niente ed evita di scartare automazioni
        // che l'app sa perfettamente rifare.
        let timeConditions = draft.timeConditions.map(timeCondition(from:))
        let presenceConditions = draft.presenceConditions.map {
            RestorableAutomation.PresenceCondition(kind: $0.kind.rawValue,
                                                   userScope: $0.userScope.rawValue)
        }
        guard draft.preservedConditionPredicate == nil else {
            return (nil, String(localized: "automationCapture.skip.predicate",
                                defaultValue: "it carries a condition built outside this app, which would be lost"))
        }

        return (RestorableAutomation(
            startEvents: startEvents,
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            conditionJoinMode: draft.conditionJoinMode.rawValue,
            sceneName: sceneName,
            inlineActions: inlineActions,
            isEnabled: trigger.isEnabled
        ), nil)
    }

    private static func timeCondition(from condition: AutomationTimeCondition) -> RestorableAutomation.TimeCondition {
        let calendar = Calendar.current
        let start = calendar.dateComponents([.hour, .minute], from: condition.time)
        let end = calendar.dateComponents([.hour, .minute], from: condition.endTime)
        return RestorableAutomation.TimeCondition(
            kind: condition.kind.rawValue,
            relation: condition.relation.rawValue,
            hour: start.hour ?? 0,
            minute: start.minute ?? 0,
            offsetMinutes: condition.offsetMinutes,
            endKind: condition.endKind.rawValue,
            endHour: end.hour ?? 0,
            endMinute: end.minute ?? 0,
            endOffsetMinutes: condition.endOffsetMinutes
        )
    }

    private static func decodeTimeCondition(_ stored: RestorableAutomation.TimeCondition) -> AutomationTimeCondition? {
        guard let kind = AutomationTimeConditionKind(rawValue: stored.kind),
              let relation = AutomationTimeConditionRelation(rawValue: stored.relation),
              let endKind = AutomationTimeConditionKind(rawValue: stored.endKind) else { return nil }
        var condition = AutomationTimeCondition()
        condition.kind = kind
        condition.relation = relation
        condition.time = Calendar.current.date(bySettingHour: stored.hour, minute: stored.minute,
                                               second: 0, of: Date()) ?? Date()
        condition.offsetMinutes = stored.offsetMinutes
        condition.endKind = endKind
        condition.endTime = Calendar.current.date(bySettingHour: stored.endHour, minute: stored.endMinute,
                                                  second: 0, of: Date()) ?? Date()
        condition.endOffsetMinutes = stored.endOffsetMinutes
        return condition
    }

    private static func schedule(from trigger: AutomationScheduleTrigger) -> RestorableAutomation.Schedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: trigger.time)
        return RestorableAutomation.Schedule(
            kind: trigger.kind.rawValue,
            hour: parts.hour ?? 0,
            minute: parts.minute ?? 0,
            offsetMinutes: trigger.offsetMinutes,
            weekdays: trigger.weekdays.map(\.rawValue).sorted()
        )
    }

    private static func capabilityRef(from selection: AutomationCapabilitySelection,
                                      serials: [UUID: String]) -> RestorableAutomation.CapabilityRef? {
        guard let accessory = selection.capability.characteristic.service?.accessory else { return nil }
        return RestorableAutomation.CapabilityRef(
            accessory: AccessoryAddress(
                serialNumber: serials[accessory.uniqueIdentifier],
                manufacturer: accessory.manufacturer,
                model: accessory.model,
                name: accessory.name,
                roomName: accessory.room?.name,
                category: accessory.category.categoryType,
                isBridged: accessory.isBridged,
                localUUID: accessory.uniqueIdentifier.uuidString
            ),
            characteristicType: selection.capability.characteristic.characteristicType,
            comparisonOperator: operatorKey(selection.comparisonOperator),
            targetValue: targetValue(selection.targetValue)
        )
    }

    private static func operatorKey(_ value: AutomationCapabilityOperator) -> String {
        switch value {
        case .becomesActive:   "becomesActive"
        case .becomesInactive: "becomesInactive"
        case .equals:          "equals"
        case .greaterThan:     "greaterThan"
        case .lessThan:        "lessThan"
        }
    }

    private static func decodeOperator(_ key: String) -> AutomationCapabilityOperator? {
        switch key {
        case "becomesActive":   .becomesActive
        case "becomesInactive": .becomesInactive
        case "equals":          .equals
        case "greaterThan":     .greaterThan
        case "lessThan":        .lessThan
        default:                nil
        }
    }

    private static func targetValue(_ value: AutomationCapabilityTargetValue) -> RestorableAutomation.TargetValue {
        switch value {
        case .bool(let flag):  .bool(flag)
        case .number(let n):   .number(n)
        case .state(let s):    .state(s)
        case .any:             .any
        }
    }

    private static func decodeTargetValue(_ value: RestorableAutomation.TargetValue) -> AutomationCapabilityTargetValue {
        switch value {
        case .bool(let flag):  .bool(flag)
        case .number(let n):   .number(n)
        case .state(let s):    .state(s)
        case .any:             .any
        }
    }

    // MARK: - Ricreazione

    enum RestoreFailure: LocalizedError {
        case sceneMissing(String)
        case accessoryMissing(String)
        case characteristicMissing(accessory: String, characteristic: String)
        case unsupported

        var errorDescription: String? {
            switch self {
            case .sceneMissing(let name):
                String(format: String(localized: "restorableAutomation.fail.scene",
                                      defaultValue: "the scene “%@” is not in this home"), name)
            case .accessoryMissing(let name):
                String(format: String(localized: "restorableAutomation.fail.accessory",
                                      defaultValue: "“%@” is not in this home"), name)
            case .characteristicMissing(let accessory, let characteristic):
                String(format: String(localized: "restorableAutomation.fail.characteristic",
                                      defaultValue: "“%1$@” no longer offers %2$@"), accessory, characteristic)
            case .unsupported:
                String(localized: "restorableAutomation.fail.unsupported",
                       defaultValue: "this trigger cannot be recreated")
            }
        }
    }

    /// Ricrea l'automazione. Risolve **tutto prima** di scrivere: se un pezzo
    /// manca si esce senza aver creato niente, invece di lasciare in casa un
    /// trigger a metà col nome giusto.
    static func recreate(_ plan: RestorableAutomation,
                         in home: HMHome,
                         scenes: [SceneItem],
                         inlineActions: [HMAction],
                         name: String,
                         automationsService: HomeKitAutomationsService) async throws {
        var scene: SceneItem?
        if let sceneName = plan.sceneName {
            guard let match = scenes.first(where: { $0.name == sceneName }) else {
                throw RestoreFailure.sceneMissing(sceneName)
            }
            scene = match
        } else if inlineActions.isEmpty {
            throw RestoreFailure.unsupported
        }
        let capabilities = AutomationCapabilityCatalog.capabilities(in: home)

        var startEvents: [AutomationStartEvent] = []
        for event in plan.startEvents {
            switch event {
            case .accessory(let ref):
                startEvents.append(.accessory(try selection(for: ref, capabilities: capabilities, in: home)))
            case .schedule(let stored):
                startEvents.append(.schedule(scheduleTrigger(from: stored)))
            case .presence(let kind, let scope):
                guard let presenceKind = AutomationPresenceTriggerKind(rawValue: kind),
                      let userScope = AutomationPresenceUserScope(rawValue: scope) else {
                    throw RestoreFailure.unsupported
                }
                startEvents.append(.presence(AutomationPresenceTrigger(kind: presenceKind, userScope: userScope)))
            }
        }

        let conditions = try plan.conditions.map {
            try selection(for: $0, capabilities: capabilities, in: home)
        }

        let timeConditions = plan.timeConditions.compactMap(decodeTimeCondition)
        guard timeConditions.count == plan.timeConditions.count else { throw RestoreFailure.unsupported }
        let presenceConditions = plan.presenceConditions.compactMap { stored -> AutomationPresenceCondition? in
            guard let kind = AutomationPresenceConditionKind(rawValue: stored.kind),
                  let scope = AutomationPresenceUserScope(rawValue: stored.userScope) else { return nil }
            var condition = AutomationPresenceCondition()
            condition.kind = kind
            condition.userScope = scope
            return condition
        }
        guard presenceConditions.count == plan.presenceConditions.count else { throw RestoreFailure.unsupported }

        try await automationsService.createSceneAutomation(
            name: name,
            startEvents: startEvents,
            conditions: conditions,
            timeConditions: timeConditions,
            presenceConditions: presenceConditions,
            conditionJoinMode: AutomationConditionJoinMode(rawValue: plan.conditionJoinMode) ?? .all,
            scene: scene,
            inlineActions: inlineActions,
            enabled: plan.isEnabled
        )
    }

    private static func scheduleTrigger(from stored: RestorableAutomation.Schedule) -> AutomationScheduleTrigger {
        var trigger = AutomationScheduleTrigger()
        trigger.kind = AutomationScheduleKind(rawValue: stored.kind) ?? .fixedTime
        trigger.time = Calendar.current.date(bySettingHour: stored.hour,
                                             minute: stored.minute,
                                             second: 0,
                                             of: Date()) ?? Date()
        trigger.offsetMinutes = stored.offsetMinutes
        trigger.weekdays = Set(stored.weekdays.compactMap(AutomationScheduleWeekday.init(rawValue:)))
        return trigger
    }

    private static func selection(for ref: RestorableAutomation.CapabilityRef,
                                  capabilities: [AutomationCharacteristicCapability],
                                  in home: HMHome) throws -> AutomationCapabilitySelection {
        guard let accessory = resolveAccessory(ref.accessory, in: home) else {
            throw RestoreFailure.accessoryMissing(ref.accessory.name)
        }
        guard let capability = capabilities.first(where: {
            $0.accessoryID == accessory.uniqueIdentifier
                && $0.characteristic.characteristicType == ref.characteristicType
        }) else {
            throw RestoreFailure.characteristicMissing(
                accessory: accessory.name,
                characteristic: SnapshotCharacteristicNames.readable(ref.characteristicType))
        }
        return AutomationCapabilitySelection(
            capability: capability,
            comparisonOperator: decodeOperator(ref.comparisonOperator),
            targetValue: decodeTargetValue(ref.targetValue)
        )
    }

    /// Seriale, poi identificatore locale, poi nome — ognuno solo se univoco.
    private static func resolveAccessory(_ address: AccessoryAddress, in home: HMHome) -> HMAccessory? {
        if let serial = address.serialNumber, !serial.isEmpty {
            let matches = home.accessories.filter { accessory in
                accessory.services
                    .first { $0.serviceType == HMServiceTypeAccessoryInformation }?
                    .characteristics
                    .first { $0.characteristicType.hasPrefix("00000030") }?
                    .value as? String == serial
            }
            if matches.count == 1 { return matches[0] }
        }
        if let raw = address.localUUID, let uuid = UUID(uuidString: raw),
           let match = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
            return match
        }
        let byName = home.accessories.filter { $0.name == address.name }
        return byName.count == 1 ? byName[0] : nil
    }
}
