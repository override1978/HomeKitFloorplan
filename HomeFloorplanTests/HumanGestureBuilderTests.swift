import Foundation
import Testing
@testable import HomeFloorplan

@Suite("HumanGestureBuilder — riconoscere la mano di una persona")
struct HumanGestureBuilderTests {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Rome")!
        return c
    }
    private func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: h, minute: m, second: s))!
    }
    private func change(_ name: String, _ when: Date,
                        state: Bool = true,
                        type: String = "light",
                        origin: String = "external",
                        room: String? = "Soggiorno",
                        uuid: UUID = UUID()) -> HumanGestureBuilder.RawChange {
        .init(accessoryUUID: uuid, accessoryName: name, roomName: room,
              state: state, brightness: nil, eventType: type, at: when, origin: origin)
    }

    @Test("Comandi ravvicinati sono un gesto solo")
    func nearbyChangesFormOneGesture() throws {
        let gestures = HumanGestureBuilder.build(from: [
            change("Led Libreria", at(19, 47, 0)),
            change("Led TV", at(19, 47, 8)),
            change("Lampada", at(19, 47, 20))
        ])
        #expect(gestures.count == 1, "chi accende tre luci in venti secondi ha fatto una cosa")
        #expect(try #require(gestures.first).changes.count == 3)
        #expect(gestures.first?.at == at(19, 47, 0), "il gesto comincia col primo comando")
    }

    @Test("Comandi lontani sono gesti distinti")
    func distantChangesSplit() {
        let gestures = HumanGestureBuilder.build(from: [
            change("Led Libreria", at(19, 47)),
            change("Lampada", at(22, 10))
        ])
        #expect(gestures.count == 2)
    }

    @Test("Le scritture dell'app non sono gesti umani")
    func appWritesAreNotGestures() {
        let gestures = HumanGestureBuilder.build(from: [
            change("Motore", at(19, 47), origin: "app")
        ])
        #expect(gestures.isEmpty, "è la casa che agisce, ed è già raccontata sopra l'asse")
    }

    @Test("Ciò che cade su uno scatto programmato si attribuisce all'automazione")
    func changesNearScheduledFiresAreExcluded() {
        let fire = at(22, 0)
        let gestures = HumanGestureBuilder.build(
            from: [change("Antifurto", fire.addingTimeInterval(3))],
            scheduledFires: [fire])
        #expect(gestures.isEmpty)
    }

    @Test("Un comando lontano dallo scatto resta umano")
    func changesFarFromFiresSurvive() {
        let fire = at(22, 0)
        let gestures = HumanGestureBuilder.build(
            from: [change("Lampada", fire.addingTimeInterval(600))],
            scheduledFires: [fire])
        #expect(gestures.count == 1, "dieci minuti dopo non è più l'automazione")
    }

    @Test("Finestre e movimento non sono comandi")
    func observationsAreNotCommands() {
        let gestures = HumanGestureBuilder.build(from: [
            change("Finestra Cucina", at(9, 0), type: "contact"),
            change("Movimento", at(9, 0, 5), type: "motion")
        ])
        #expect(gestures.isEmpty, "nessuno può richiamare un sensore di movimento")
    }

    @Test("Lo stesso accessorio toccato due volte conta una volta, con l'ultimo stato")
    func repeatedAccessoryCollapses() throws {
        let lamp = UUID()
        let gestures = HumanGestureBuilder.build(from: [
            change("Lampada", at(19, 47, 0), state: true, uuid: lamp),
            change("Lampada", at(19, 47, 5), state: false, uuid: lamp)
        ])
        let gesture = try #require(gestures.first)
        #expect(gesture.changes.count == 1, "accendere e correggere è una cosa sola")
        #expect(gesture.changes.first?.state == false, "vale l'ultimo stato, non il primo")
    }

    @Test("Le stanze toccate si elencano senza ripetizioni")
    func roomsAreDeduplicated() throws {
        let gestures = HumanGestureBuilder.build(from: [
            change("A", at(19, 47, 0), room: "Soggiorno"),
            change("B", at(19, 47, 5), room: "Cucina"),
            change("C", at(19, 47, 9), room: "Soggiorno")
        ])
        #expect(try #require(gestures.first).roomNames == ["Soggiorno", "Cucina"])
    }

    @Test("Prevalenza di accensioni o di spegnimenti")
    func mostlyOnReflectsTheGesture() throws {
        let onGesture = HumanGestureBuilder.build(from: [
            change("A", at(19, 0), state: true),
            change("B", at(19, 0, 4), state: true),
            change("C", at(19, 0, 8), state: false)
        ])
        #expect(try #require(onGesture.first).isMostlyOn)

        let offGesture = HumanGestureBuilder.build(from: [
            change("A", at(23, 0), state: false),
            change("B", at(23, 0, 4), state: false)
        ])
        #expect(try #require(offGesture.first).isMostlyOn == false)
    }

    @Test("Nessun evento, nessun gesto")
    func emptyInputYieldsNothing() {
        #expect(HumanGestureBuilder.build(from: []).isEmpty)
    }
}
