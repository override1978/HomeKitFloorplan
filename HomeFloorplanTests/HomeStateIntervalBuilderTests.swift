import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("HomeStateIntervalBuilder — ricostruzione intervalli da eventi")
struct HomeStateIntervalBuilderTests {

    @Test("Contatto: state false=aperto apre l'intervallo, true=chiuso lo chiude")
    func contactOpenCloseSemantics() {
        let accessoryID = UUID()
        let openAt = Date().addingTimeInterval(-30 * 60)
        let closedAt = Date().addingTimeInterval(-5 * 60)

        let events = [
            makeEvent(accessoryID: accessoryID, name: "Porta Ingresso", state: false, timestamp: openAt, eventType: .contact),
            makeEvent(accessoryID: accessoryID, name: "Porta Ingresso", state: true, timestamp: closedAt, eventType: .contact)
        ]

        let intervals = HomeStateIntervalBuilder.build(from: events)
        #expect(intervals.count == 1)
        let interval = intervals.first
        #expect(interval?.signalType == .contact)
        #expect(interval?.stateRaw == "open")
        #expect(interval?.isActive == false)
        #expect(interval?.startedAt == openAt)
        #expect(interval?.endedAt == closedAt)
    }

    @Test("Luce accesa senza spegnimento: intervallo attivo 'on'")
    func lightWithoutOffIsActive() {
        let events = [
            makeEvent(name: "Lampada Studio", state: true, timestamp: Date().addingTimeInterval(-2 * 3600), eventType: .light)
        ]

        let intervals = HomeStateIntervalBuilder.build(from: events)
        #expect(intervals.count == 1)
        #expect(intervals.first?.signalType == .power)
        #expect(intervals.first?.stateRaw == "on")
        #expect(intervals.first?.isActive == true)
    }

    @Test("Input newest-first (come dalla pipeline): il builder ordina e ricostruisce comunque")
    func newestFirstInputHandled() {
        let accessoryID = UUID()
        let onAt = Date().addingTimeInterval(-3 * 3600)
        let offAt = Date().addingTimeInterval(-1 * 3600)

        // Ordine inverso: prima l'evento più recente, come dal fetch reverse della pipeline.
        let events = [
            makeEvent(accessoryID: accessoryID, name: "Presa TV", state: false, timestamp: offAt, eventType: .outlet),
            makeEvent(accessoryID: accessoryID, name: "Presa TV", state: true, timestamp: onAt, eventType: .outlet)
        ]

        let intervals = HomeStateIntervalBuilder.build(from: events)
        #expect(intervals.count == 1)
        #expect(intervals.first?.isActive == false)
        #expect(intervals.first?.durationSeconds == offAt.timeIntervalSince(onAt))
    }

    @Test("Eventi blind esclusi dagli intervalli")
    func blindEventsExcluded() {
        let events = [
            makeEvent(name: "Tapparella", state: true, timestamp: Date().addingTimeInterval(-3600), eventType: .blind)
        ]
        #expect(HomeStateIntervalBuilder.build(from: events).isEmpty)
    }

    @Test("Termostato attivo: intervallo etichettato 'heating' con signalType .active")
    func thermostatIntervalLabeledHeating() {
        let events = [
            makeEvent(name: "Termostato Soggiorno", state: true, timestamp: Date().addingTimeInterval(-3600), eventType: .thermostat)
        ]

        let intervals = HomeStateIntervalBuilder.build(from: events)
        #expect(intervals.first?.signalType == .active)
        #expect(intervals.first?.stateRaw == "heating")
    }

    @Test("Evento di chiusura senza apertura: nessun intervallo orfano")
    func closeWithoutOpenIsIgnored() {
        let events = [
            makeEvent(name: "Porta Garage", state: true, timestamp: Date().addingTimeInterval(-3600), eventType: .contact)
        ]
        #expect(HomeStateIntervalBuilder.build(from: events).isEmpty)
    }

    // MARK: - Helper

    private func makeEvent(
        accessoryID: UUID = UUID(),
        name: String,
        state: Bool,
        timestamp: Date,
        eventType: AccessoryEventType
    ) -> AccessoryEvent {
        AccessoryEvent(
            accessoryID: accessoryID,
            accessoryName: name,
            roomName: "Stanza",
            state: state,
            timestamp: timestamp,
            eventType: eventType.rawValue
        )
    }
}
