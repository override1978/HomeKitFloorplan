import Foundation
import HomeKit

@MainActor
enum AutomationProposalMapper {
    static func proposal(
        from opportunity: AutomationOpportunity,
        capabilities: [AutomationCharacteristicCapability],
        scenes: [SceneItem]
    ) -> AutomationProposal {
        var limitations: [String] = []
        var startEvents: [AutomationProposalStartEvent] = []
        var conditions: [AutomationProposalCondition] = []
        var actions: [AutomationProposalAction] = []

        if let startEvent = startEvent(from: opportunity, capabilities: capabilities, limitations: &limitations) {
            startEvents.append(startEvent)
        }

        if opportunity.triggerType == "calendar",
           let sensorCondition = sensorSelection(from: opportunity, capabilities: capabilities, limitations: &limitations) {
            conditions.append(.accessory(sensorCondition))
        }

        if let action = action(from: opportunity, capabilities: capabilities, scenes: scenes, limitations: &limitations) {
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
            source: source(from: opportunity.origin),
            title: opportunity.title,
            explanation: opportunity.naturalLanguage,
            confidence: opportunity.confidence,
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

    private static func startEvent(
        from opportunity: AutomationOpportunity,
        capabilities: [AutomationCharacteristicCapability],
        limitations: inout [String]
    ) -> AutomationProposalStartEvent? {
        switch opportunity.triggerType {
        case "calendar":
            guard let schedule = schedule(from: opportunity) else {
                limitations.append(String(localized: "automation.proposal.limit.missingTime", defaultValue: "The opportunity does not include a valid trigger time."))
                return nil
            }
            return .schedule(schedule)

        case "characteristic":
            guard let selection = sensorSelection(from: opportunity, capabilities: capabilities, limitations: &limitations) else {
                return nil
            }
            return .accessory(selection)

        default:
            limitations.append(String(localized: "automation.proposal.limit.inAppTrigger", defaultValue: "In-app triggers need to be reviewed before they can become HomeKit automations."))
            return nil
        }
    }

    private static func schedule(from opportunity: AutomationOpportunity) -> AutomationProposalSchedule? {
        guard let time = opportunity.triggerTime ?? opportunity.avgTimeString,
              let components = timeComponents(from: time) else {
            return nil
        }

        return AutomationProposalSchedule(
            kind: .fixedTime,
            hour: components.hour,
            minute: components.minute,
            weekdays: normalizedWeekdays(from: opportunity.triggerWeekdays)
        )
    }

    private static func sensorSelection(
        from opportunity: AutomationOpportunity,
        capabilities: [AutomationCharacteristicCapability],
        limitations: inout [String]
    ) -> AutomationProposalCapabilitySelection? {
        guard let sensorType = opportunity.triggerSensorType,
              let threshold = opportunity.triggerThreshold else {
            limitations.append(String(localized: "automation.proposal.limit.missingSensor", defaultValue: "The opportunity does not include a complete sensor condition."))
            return nil
        }

        guard let capability = capability(
            forSensorType: sensorType,
            roomName: opportunity.roomName,
            capabilities: capabilities
        ) else {
            limitations.append(String(localized: "automation.proposal.limit.sensorUnavailable", defaultValue: "The proposed sensor is no longer available in HomeKit."))
            return nil
        }

        let comparisonOperator: AutomationProposalOperator = opportunity.triggerDirection == "below"
            ? .lessThan
            : .greaterThan

        return AutomationProposalCapabilitySelection(
            capabilityID: capability.id,
            accessoryID: capability.accessoryID,
            characteristicID: capability.characteristic.uniqueIdentifier,
            comparisonOperator: comparisonOperator,
            targetValue: targetValue(threshold, for: capability)
        )
    }

    private static func capability(
        forSensorType sensorType: String,
        roomName: String,
        capabilities: [AutomationCharacteristicCapability]
    ) -> AutomationCharacteristicCapability? {
        let hmType = SensorServiceType(rawValue: sensorType)?.hmCharacteristicType
        let normalizedRoom = roomName.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = capabilities.filter { capability in
            guard capability.supportedRoles.contains(.trigger) || capability.supportedRoles.contains(.condition) else {
                return false
            }

            let matchesType: Bool
            if let hmType, !hmType.isEmpty {
                matchesType = capability.characteristic.characteristicType.caseInsensitiveCompare(hmType) == .orderedSame
            } else {
                matchesType = capability.title.localizedCaseInsensitiveContains(sensorType)
            }

            let matchesRoom = normalizedRoom.isEmpty ||
                capability.roomName.localizedCaseInsensitiveCompare(normalizedRoom) == .orderedSame
            return matchesType && matchesRoom
        }

        return candidates.first
    }

    private static func targetValue(
        _ raw: Double,
        for capability: AutomationCharacteristicCapability
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
        from opportunity: AutomationOpportunity,
        capabilities: [AutomationCharacteristicCapability],
        scenes: [SceneItem],
        limitations: inout [String]
    ) -> AutomationProposalAction? {
        if let sceneName = opportunity.effectSceneName,
           !sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let scene = scenes.first { $0.name.localizedCaseInsensitiveCompare(sceneName) == .orderedSame }
            return .scene(AutomationProposalSceneReference(sceneID: scene?.id, name: sceneName))
        }

        guard let rawAccessoryID = opportunity.effectAccessoryIDString,
              let accessoryID = UUID(uuidString: rawAccessoryID) else {
            limitations.append(String(localized: "automation.proposal.limit.missingActionTarget", defaultValue: "The opportunity does not include a valid action target."))
            return nil
        }

        switch opportunity.effectActionRaw {
        case "on", "activate":
            return powerAction(accessoryID: accessoryID, powerOn: true, capabilities: capabilities, limitations: &limitations)
        case "off":
            return powerAction(accessoryID: accessoryID, powerOn: false, capabilities: capabilities, limitations: &limitations)
        default:
            limitations.append(String(localized: "automation.proposal.limit.unsupportedAction", defaultValue: "This action needs the advanced accessory editor and is not converted automatically yet."))
            return nil
        }
    }

    private static func powerAction(
        accessoryID: UUID,
        powerOn: Bool,
        capabilities: [AutomationCharacteristicCapability],
        limitations: inout [String]
    ) -> AutomationProposalAction? {
        guard let capability = capabilities.first(where: {
            $0.accessoryID == accessoryID &&
            ($0.characteristic.characteristicType == HMCharacteristicTypePowerState ||
             $0.characteristic.characteristicType == HMCharacteristicTypeActive)
        }) else {
            limitations.append(String(localized: "automation.proposal.limit.powerUnavailable", defaultValue: "The proposed accessory cannot be turned on or off by the automation builder."))
            return nil
        }

        return .accessoryPower(AutomationProposalPowerAction(
            capabilityID: capability.id,
            accessoryID: capability.accessoryID,
            characteristicID: capability.characteristic.uniqueIdentifier,
            powerOn: powerOn
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

    private static func normalizedWeekdays(from values: [Int]) -> Set<Int> {
        let normalized = values.filter { (1...7).contains($0) }
        return normalized.isEmpty ? Set(1...7) : Set(normalized)
    }
}
