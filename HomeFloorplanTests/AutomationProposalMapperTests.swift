import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("AutomationProposalMapper chatbot proposals")
struct AutomationProposalMapperTests {

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
