import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("AutomationProposalMapper chatbot proposals")
struct AutomationProposalMapperTests {

    /// UUID stabile per l'accessorio demo usato nel test di fallback-per-nome.
    static let climaSoggiornoID = UUID(uuidString: "DE300000-0000-4000-8000-000000000001")!

    /// Fixture capability minima (accessorio azionabile "Demo Clima Soggiorno"),
    /// inlined dopo la rimozione di HabitScenarioFactory col ritiro del motore.
    private func demoCapabilities() -> [AutomationCapabilityDescriptor] {
        [
            AutomationCapabilityDescriptor(
                id: "\(Self.climaSoggiornoID.uuidString)-power",
                accessoryID: Self.climaSoggiornoID,
                accessoryName: "Demo Clima Soggiorno",
                roomName: "Demo Soggiorno",
                characteristicID: UUID(uuidString: "DE300000-0000-4000-8000-0000000000AA")!,
                characteristicType: "00000025-0000-1000-8000-0026BB765291", // PowerState
                title: "Power",
                valueKind: .boolean(activeLabel: "On", inactiveLabel: "Off"),
                supportedRoles: [.trigger, .condition],
                defaultOperator: .equals
            )
        ]
    }

    @Test("setMode keeps secondary target temperature")
    func setModeKeepsSecondaryTargetTemperature() {
        let accessoryID = UUID()
        let proposal = makeProposal(
            accessoryID: accessoryID,
            action: "setMode",
            value: 2,
            value2: 24
        )

        #expect(proposal.source == .chatbot)
        #expect(proposal.startEvents.count == 1)
        #expect(proposal.actions.count == 1)

        guard case .accessory(let action) = proposal.actions.first else {
            Issue.record("Expected accessory action")
            return
        }

        #expect(action.accessoryID == accessoryID)
        #expect(action.kind == .setMode)
        #expect(action.value == 2)
        #expect(action.secondaryValue == 24)
    }

    @Test("UUID effetto estraneo: riabbinato per nome+stanza alle capability locali")
    func staleEffectAccessoryIDResolvesByName() {
        // Scenario device slave: l'opportunity/pattern arriva via sync con un UUID
        // HomeKit di un ALTRO device. Il mapper deve riabbinare per nome invece
        // di produrre una proposta senza azioni.
        let foreignID = UUID()
        let pattern = makeContextualPattern(
            accessoryID: foreignID,
            accessoryName: "Clima Soggiorno",
            roomName: "Soggiorno",
            causeSignature: "context:temperature:above:28"
        )

        let proposal = AutomationProposalMapper.proposal(
            from: pattern,
            capabilities: demoCapabilities(),
            scenes: []
        )

        guard case .accessory(let action) = proposal.actions.first else {
            Issue.record("Expected accessory action resolved by name fallback")
            return
        }
        #expect(action.accessoryID == Self.climaSoggiornoID)
        #expect(action.accessoryID != foreignID)
    }

    @Test("UUID estraneo senza nome abbinabile: nessuna azione, limitation esplicita")
    func unresolvableEffectAccessoryYieldsNoAction() {
        let pattern = makeContextualPattern(
            accessoryID: UUID(),
            accessoryName: "Accessorio Inesistente",
            roomName: "Cantina",
            causeSignature: "context:temperature:above:28"
        )

        let proposal = AutomationProposalMapper.proposal(
            from: pattern,
            capabilities: demoCapabilities(),
            scenes: []
        )

        #expect(proposal.actions.isEmpty)
        #expect(proposal.unsupportedReason != nil, "azione mancante = proposta esplicitamente non supportata, mai un builder vuoto silenzioso")
    }

    @Test("setHumidity maps to humidity proposal action")
    func setHumidityMapsToHumidityAction() {
        let proposal = makeProposal(action: "setHumidity", value: 45)

        guard case .accessory(let action) = proposal.actions.first else {
            Issue.record("Expected accessory action")
            return
        }

        #expect(action.kind == .setHumidity)
        #expect(action.value == 45)
    }

    @Test("closeGarage maps to close proposal action")
    func closeGarageMapsToCloseAction() {
        let proposal = makeProposal(action: "closeGarage")

        guard case .accessory(let action) = proposal.actions.first else {
            Issue.record("Expected accessory action")
            return
        }

        #expect(action.kind == .close)
    }

    @Test("lock maps to lock proposal action")
    func lockMapsToLockAction() {
        let proposal = makeProposal(action: "lock")

        guard case .accessory(let action) = proposal.actions.first else {
            Issue.record("Expected accessory action")
            return
        }

        #expect(action.kind == .lock)
    }

    @Test("armAway maps to security setMode proposal action")
    func armAwayMapsToSecurityModeAction() {
        let proposal = makeProposal(action: "armAway")

        guard case .accessory(let action) = proposal.actions.first else {
            Issue.record("Expected accessory action")
            return
        }

        #expect(action.kind == .setMode)
        #expect(action.value == Double(SecurityMode.away.rawValue))
    }

    @Test("calendar chatbot proposal keeps schedule")
    func calendarProposalKeepsSchedule() {
        let proposal = makeProposal(
            triggerTime: "07:30",
            triggerWeekdaysRaw: "2,3,4,5,6"
        )

        guard case .schedule(let schedule) = proposal.startEvents.first else {
            Issue.record("Expected schedule start event")
            return
        }

        #expect(schedule.hour == 7)
        #expect(schedule.minute == 30)
        #expect(schedule.weekdays == Set([2, 3, 4, 5, 6]))
    }

    private func makeContextualPattern(
        accessoryID: UUID,
        accessoryName: String,
        roomName: String,
        causeSignature: String
    ) -> BehavioralPattern {
        BehavioralPattern(
            id: UUID(),
            patternType: .contextual,
            detectedAt: Date(),
            accessoryName: accessoryName,
            accessoryID: accessoryID,
            roomName: roomName,
            eventTypeRaw: "thermostat",
            action: .on,
            numericValue: nil,
            avgMinuteOfDay: 14 * 60,
            timeDeviationMinutes: 120,
            weekdays: [],
            dayType: nil,
            causeSignature: causeSignature,
            causeName: "test",
            avgGapSeconds: nil,
            observations: 8,
            validations: 8,
            firstObservedAt: Date().addingTimeInterval(-12 * 24 * 3600),
            lastObservedAt: Date(),
            stabilityDays: 12,
            distinctActiveDays: 8,
            status: .active,
            dismissedAt: nil,
            approvedAt: nil,
            naturalLanguageDescription: "test"
        )
    }

    private func makeProposal(
        accessoryID: UUID = UUID(),
        action: String = "on",
        value: Double? = nil,
        value2: Double? = nil,
        triggerTime: String = "08:00",
        triggerWeekdaysRaw: String? = nil
    ) -> AutomationProposal {
        AutomationProposalMapper.chatbotProposal(
            label: "Test proposal",
            naturalLanguage: "Create a test automation",
            accessoryID: accessoryID.uuidString,
            action: action,
            value: value,
            value2: value2,
            triggerType: "calendar",
            triggerTime: triggerTime,
            triggerWeekdaysRaw: triggerWeekdaysRaw,
            triggerSensorType: nil,
            triggerSensorRoom: nil,
            triggerThreshold: nil,
            triggerDirection: nil,
            sceneName: nil,
            semanticKey: "\(accessoryID.uuidString):\(action):\(value ?? -1):\(value2 ?? -1)",
            capabilities: [],
            scenes: []
        )
    }
}
