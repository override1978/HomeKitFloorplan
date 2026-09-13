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

// MARK: - Plausibilità

/// Le regole che distinguono una mano da una trasmissione.
///
/// Nascono da un caso vero: un rombo dell'1:28 con quarantasette comandi in
/// dieci stanze. Nessuno è in dieci stanze all'una e mezza di notte.
@Suite("Un gesto deve essere umanamente possibile")
struct HumanGesturePlausibilityTests {

    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func raw(_ index: Int,
                     at offset: TimeInterval,
                     origin: String = "external") -> HumanGestureBuilder.RawChange {
        HumanGestureBuilder.RawChange(accessoryUUID: UUID(),
                                      accessoryName: "Luce \(index)",
                                      // Poche stanze di proposito: qui si prova
                                      // la simultaneità, e dare una stanza a
                                      // testa farebbe scattare il vincolo sul
                                      // percorso mascherando ciò che si misura.
                                      roomName: "Stanza \(index % 4)",
                                      state: true,
                                      brightness: nil,
                                      eventType: "light",
                                      at: base.addingTimeInterval(offset),
                                      origin: origin)
    }

    @Test("Quarantasette accessori nello stesso istante non sono una mano")
    func simultaneousBurstIsNotAGesture() {
        let burst = (0..<47).map { raw($0, at: Double($0) * 0.02) }
        #expect(HumanGestureBuilder.build(from: burst).isEmpty)
    }

    @Test("Quindici cose spente uscendo di casa restano un gesto")
    func leavingHomeSurvives() {
        // Un minuto per quindici accessori: una persona che cammina.
        let walk = (0..<15).map { raw($0, at: Double($0) * 4) }
        let gestures = HumanGestureBuilder.build(from: walk)
        #expect(gestures.count == 1)
        #expect(gestures[0].changes.count == 15)
    }

    @Test("Sotto la soglia la simultaneità non conta")
    func smallSimultaneousGroupSurvives() {
        // Tre luci accese insieme da un interruttore di gruppo: plausibile.
        let group = (0..<3).map { raw($0, at: Double($0) * 0.01) }
        #expect(HumanGestureBuilder.build(from: group).count == 1)
    }

    @Test("Le scritture dell'app non sono gesti, comunque si chiamino")
    func onlyExternalCounts() {
        for origin in ["user", "engine", "app", ""] {
            let changes = (0..<3).map { raw($0, at: Double($0) * 30, origin: origin) }
            #expect(HumanGestureBuilder.build(from: changes).isEmpty,
                    "origin \(origin) non deve entrare nella corsia")
        }
    }

    @Test("Solo external entra")
    func externalCounts() {
        let changes = (0..<3).map { raw($0, at: Double($0) * 30) }
        #expect(HumanGestureBuilder.build(from: changes).count == 1)
    }

    @Test("Una raffica non affoga i gesti veri intorno")
    func burstDoesNotEatNeighbours() {
        // Una mano alle 00:00, una trasmissione dieci minuti dopo, una mano
        // dopo un'altra decina: le due mani restano, la trasmissione no.
        var changes = (0..<2).map { raw($0, at: Double($0) * 20) }
        changes += (0..<40).map { raw(100 + $0, at: 600 + Double($0) * 0.02) }
        changes += (0..<2).map { raw(200 + $0, at: 1_200 + Double($0) * 20) }
        let gestures = HumanGestureBuilder.build(from: changes)
        #expect(gestures.count == 2)
        #expect(gestures.allSatisfy { $0.changes.count == 2 })
    }
}

// MARK: - Attribuzione alle scene

/// Dare un nome a una raffica invece di nasconderla.
///
/// Una scena che tocca dieci stanze non è un difetto da filtrare: è la cosa
/// più informativa della giornata, purché si chiami col suo nome invece che
/// «quarantasette comandi».
@Suite("Le scene si riconoscono")
struct HumanGestureSceneAttributionTests {

    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func burst(_ uuids: [UUID], spacing: TimeInterval = 0.02)
    -> [HumanGestureBuilder.RawChange] {
        uuids.enumerated().map { index, uuid in
            HumanGestureBuilder.RawChange(accessoryUUID: uuid,
                                          accessoryName: "Luce \(index)",
                                          roomName: "Stanza \(index % 10)",
                                          state: false,
                                          brightness: nil,
                                          eventType: "light",
                                          at: base.addingTimeInterval(Double(index) * spacing),
                                          origin: "external")
        }
    }

    @Test("Una raffica che coincide con una scena prende il suo nome")
    func burstBecomesTheScene() {
        let uuids = (0..<20).map { _ in UUID() }
        let scene = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Buonanotte",
                                                       accessoryUUIDs: Set(uuids))
        let gestures = HumanGestureBuilder.build(from: burst(uuids), scenes: [scene])
        #expect(gestures.count == 1)
        #expect(gestures[0].sceneName == "Buonanotte")
        #expect(gestures[0].shortTitle == "Buonanotte")
    }

    @Test("Senza una scena che la spieghi, la raffica resta fuori")
    func unattributedBurstStillDropped() {
        let uuids = (0..<20).map { _ in UUID() }
        let other = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Cinema",
                                                       accessoryUUIDs: Set((0..<20).map { _ in UUID() }))
        #expect(HumanGestureBuilder.build(from: burst(uuids), scenes: [other]).isEmpty)
    }

    @Test("Una scena riconosciuta sopravvive alla regola di plausibilità")
    func sceneSurvivesPlausibility() {
        let uuids = (0..<40).map { _ in UUID() }
        let scene = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Spegni tutto",
                                                       accessoryUUIDs: Set(uuids))
        let gestures = HumanGestureBuilder.build(from: burst(uuids), scenes: [scene])
        #expect(gestures.count == 1)
        #expect(gestures[0].isScene)
    }

    @Test("Basta la maggior parte: una scena muove solo ciò che non era già a posto")
    func partialSceneStillMatches() {
        let all = (0..<20).map { _ in UUID() }
        let scene = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Buonanotte",
                                                       accessoryUUIDs: Set(all))
        // Metà casa era già spenta: arrivano solo dieci eventi.
        let gestures = HumanGestureBuilder.build(from: burst(Array(all.prefix(10))), scenes: [scene])
        #expect(gestures.first?.sceneName == "Buonanotte")
    }

    @Test("Fra due scene compatibili vince la più piccola")
    func smallestSceneWins() {
        let shared = (0..<10).map { _ in UUID() }
        let small = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Notte Soggiorno",
                                                       accessoryUUIDs: Set(shared))
        let big = HumanGestureBuilder.SceneSignature(
            id: UUID(), name: "Spegni tutto",
            accessoryUUIDs: Set(shared + (0..<30).map { _ in UUID() }))
        let gestures = HumanGestureBuilder.build(from: burst(shared), scenes: [big, small])
        #expect(gestures.first?.sceneName == "Notte Soggiorno")
    }

    @Test("Un gesto piccolo non diventa una scena per caso")
    func smallGestureIsNeverAScene() {
        let uuids = (0..<3).map { _ in UUID() }
        let scene = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Buonanotte",
                                                       accessoryUUIDs: Set(uuids))
        let gestures = HumanGestureBuilder.build(from: burst(uuids, spacing: 20), scenes: [scene])
        #expect(gestures.count == 1)
        #expect(gestures[0].isScene == false)
    }
}

// MARK: - Il vincolo fisico

@Suite("Nessuno è in dieci stanze in tre minuti")
struct HumanGestureRoomSpreadTests {

    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func change(room: String, at offset: TimeInterval) -> HumanGestureBuilder.RawChange {
        HumanGestureBuilder.RawChange(accessoryUUID: UUID(),
                                      accessoryName: "Luce \(room)",
                                      roomName: room,
                                      state: false,
                                      brightness: nil,
                                      eventType: "light",
                                      at: base.addingTimeInterval(offset),
                                      origin: "external")
    }

    @Test("Dieci stanze in due secondi non sono un percorso")
    func tooManyRoomsTooFastIsNotAWalk() {
        let spread = (0..<10).map { change(room: "Stanza \($0)", at: Double($0) * 0.2) }
        #expect(HumanGestureBuilder.build(from: spread).isEmpty)
    }

    @Test("Il giro serale per casa è un gesto, anche se tocca otto stanze")
    func slowRoundOfTheHouseSurvives() {
        // Una stanza ogni due minuti: dentro la finestra di raggruppamento,
        // quindi un gesto solo — e il più reale che ci sia.
        let round = (0..<8).map { change(room: "Stanza \($0)", at: Double($0) * 120) }
        let gestures = HumanGestureBuilder.build(from: round)
        #expect(gestures.count == 1)
        #expect(gestures[0].roomNames.count == 8)
    }

    @Test("Le stanze si contano nel tempo, non in assoluto")
    func roomsAreJudgedByPace() {
        // Sei stanze in un minuto: dieci secondi a stanza, una camminata svelta.
        let brisk = (0..<6).map { change(room: "Stanza \($0)", at: Double($0) * 12) }
        #expect(HumanGestureBuilder.build(from: brisk).count == 1)
        // Le stesse sei in tre secondi: nessuno cammina così.
        let instant = (0..<6).map { change(room: "Stanza \($0)", at: Double($0) * 0.5) }
        #expect(HumanGestureBuilder.build(from: instant).isEmpty)
    }

    @Test("Un interruttore di gruppo accende due stanze insieme, e va bene")
    func groupSwitchAcrossRoomsSurvives() {
        // Scala ed Entrata sullo stesso comando: due stanze HomeKit, un dito.
        let group = [change(room: "Scala", at: 0),
                     change(room: "Entrata", at: 0.03),
                     change(room: "Scala", at: 0.05)]
        #expect(HumanGestureBuilder.build(from: group).count == 1)
    }

    @Test("Uscire di casa attraversa quattro stanze e resta un gesto")
    func leavingHomeIsAWalk() {
        let rooms = ["Cucina", "Soggiorno", "Entrata", "Scala"]
        let walk = rooms.enumerated().map { change(room: $0.element, at: Double($0.offset) * 15) }
        #expect(HumanGestureBuilder.build(from: walk).count == 1)
    }

    @Test("Molti accessori in poche stanze restano un gesto")
    func manyAccessoriesFewRooms() {
        // Dodici lampade fra soggiorno e cucina, con calma: è una persona che
        // sistema, non una trasmissione.
        let changes = (0..<12).map { change(room: $0 % 2 == 0 ? "Soggiorno" : "Cucina",
                                            at: Double($0) * 8) }
        #expect(HumanGestureBuilder.build(from: changes).count == 1)
    }

    @Test("Una scena riconosciuta passa anche attraverso dieci stanze")
    func attributedSceneIgnoresRoomSpread() {
        let changes = (0..<10).map { change(room: "Stanza \($0)", at: Double($0) * 0.1) }
        let scene = HumanGestureBuilder.SceneSignature(
            id: UUID(), name: "Buonanotte",
            accessoryUUIDs: Set(changes.map(\.accessoryUUID)))
        let gestures = HumanGestureBuilder.build(from: changes, scenes: [scene])
        #expect(gestures.count == 1)
        #expect(gestures[0].sceneName == "Buonanotte")
    }
}
