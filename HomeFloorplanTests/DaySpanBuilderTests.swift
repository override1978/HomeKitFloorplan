import Testing
import Foundation
@testable import HomeFloorplan

/// I periodi: ciò che è durato, non ciò che è successo.
@Suite("Le durate sul nastro")
struct DaySpanBuilderTests {

    private let day = DateInterval(start: Date(timeIntervalSinceReferenceDate: 0),
                                   duration: 24 * 3600)

    private func at(_ hour: Double) -> Date {
        day.start.addingTimeInterval(hour * 3600)
    }

    private func change(_ uuid: UUID, on: Bool, at hour: Double,
                        type: String = "airPurifier",
                        name: String = "Purificatore") -> HumanGestureBuilder.RawChange {
        HumanGestureBuilder.RawChange(accessoryUUID: uuid,
                                      accessoryName: name,
                                      roomName: "Studio",
                                      state: on,
                                      brightness: nil,
                                      eventType: type,
                                      at: at(hour),
                                      origin: "external")
    }

    @Test("Acceso alle 9, spento alle 11: un periodo di due ore")
    func onThenOffIsASpan() throws {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 9),
                                                change(uuid, on: false, at: 11)],
                                         window: day, now: at(23))
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(span.start == at(9))
        #expect(span.end == at(11))
        #expect(span.duration(now: at(23)) == 2 * 3600)
        #expect(span.isRunning == false)
    }

    @Test("Ancora acceso adesso: il periodo resta aperto")
    func stillRunningStaysOpen() throws {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 9)],
                                         window: day, now: at(11))
        let span = try #require(spans.first)
        #expect(span.isRunning)
        #expect(span.end == nil)
        #expect(span.duration(now: at(11)) == 2 * 3600)
    }

    @Test("Su un giorno passato un periodo aperto si chiude al bordo")
    func pastDayClosesAtTheEdge() throws {
        let uuid = UUID()
        // «adesso» è fuori dalla finestra: è un giorno andato.
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 22)],
                                         window: day,
                                         now: day.end.addingTimeInterval(48 * 3600))
        let span = try #require(spans.first)
        #expect(span.isRunning == false, "fingere che duri ancora sarebbe falso")
        #expect(span.end == day.end)
    }

    @Test("Se il primo evento è uno spegnimento, era già acceso")
    func offFirstMeansItWasAlreadyOn() throws {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: false, at: 7)],
                                         window: day, now: at(12))
        let span = try #require(spans.first)
        #expect(span.start == day.start)
        #expect(span.startsBeforeWindow, "il bordo non è un inizio, è il limite di ciò che sappiamo")
        #expect(span.end == at(7))
    }

    @Test("Un lampo di due minuti resta un punto, non diventa una barra")
    func tooShortIsNotASpan() {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 9),
                                                change(uuid, on: false, at: 9.03)],
                                         window: day, now: at(12))
        #expect(spans.isEmpty)
    }

    @Test("Le luci non sono processi")
    func lightsAreNotProcesses() {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 21, type: "light"),
                                                change(uuid, on: false, at: 23, type: "light")],
                                         window: day, now: at(23.5))
        #expect(spans.isEmpty, "una luce accesa tre ore non dice niente che la stanza non dica già")
    }

    @Test("Accensioni ripetute dello stesso accessorio fanno periodi distinti")
    func repeatedRunsAreSeparate() {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 9),
                                                change(uuid, on: false, at: 10),
                                                change(uuid, on: true, at: 15),
                                                change(uuid, on: false, at: 16)],
                                         window: day, now: at(20))
        #expect(spans.count == 2)
        #expect(spans[0].start == at(9))
        #expect(spans[1].start == at(15))
    }

    @Test("Accessori diversi non si mescolano")
    func accessoriesDoNotMix() {
        let purifier = UUID(), fan = UUID()
        let spans = DaySpanBuilder.build(from: [
            change(purifier, on: true, at: 9),
            change(fan, on: true, at: 9.5, type: "fan", name: "Ventola"),
            change(purifier, on: false, at: 11),
            change(fan, on: false, at: 10, type: "fan", name: "Ventola")
        ], window: day, now: at(20))
        #expect(spans.count == 2)
        #expect(Set(spans.map(\.name)) == ["Purificatore", "Ventola"])
    }

    @Test("Accensioni doppie senza spegnimento in mezzo non aprono due periodi")
    func doubleOnDoesNotDuplicate() {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: true, at: 9),
                                                change(uuid, on: true, at: 9.5),
                                                change(uuid, on: false, at: 11)],
                                         window: day, now: at(20))
        #expect(spans.count == 1)
        #expect(spans[0].start == at(9))
    }

    @Test("I periodi escono in ordine di inizio")
    func spansAreOrdered() {
        let a = UUID(), b = UUID()
        let spans = DaySpanBuilder.build(from: [
            change(b, on: true, at: 15, type: "fan", name: "Ventola"),
            change(b, on: false, at: 16, type: "fan", name: "Ventola"),
            change(a, on: true, at: 9),
            change(a, on: false, at: 10)
        ], window: day, now: at(20))
        #expect(spans.map(\.start) == [at(9), at(15)])
    }

    @Test("Nessun evento, nessun periodo")
    func emptyInput() {
        #expect(DaySpanBuilder.build(from: [], window: day, now: at(12)).isEmpty)
    }
}

/// Come si dice una durata a una persona.
@Suite("Il testo delle durate")
struct SpanDurationTextTests {

    @Test("Sotto l'ora si contano i minuti")
    func minutesOnly() {
        #expect(FloorplanSpanPanelContent.durationText(45 * 60) == "45 min")
        #expect(FloorplanSpanPanelContent.durationText(5 * 60) == "5 min")
    }

    @Test("Un'ora tonda non porta gli zeri dietro")
    func wholeHours() {
        #expect(FloorplanSpanPanelContent.durationText(2 * 3600) == "2h")
    }

    @Test("Ore e minuti insieme, coi minuti a due cifre")
    func hoursAndMinutes() {
        // «2h 05» e non «2h 5»: le durate si leggono in colonna con le ore
        // dell'asse, e una cifra sola le fa saltare.
        #expect(FloorplanSpanPanelContent.durationText(2 * 3600 + 5 * 60) == "2h 05")
        #expect(FloorplanSpanPanelContent.durationText(2 * 3600 + 35 * 60) == "2h 35")
    }

    @Test("Una durata negativa non produce numeri assurdi")
    func negativeIsClamped() {
        #expect(FloorplanSpanPanelContent.durationText(-100) == "0 min")
    }
}

/// Le righe: due periodi sovrapposti non stanno mai sulla stessa.
@Suite("Le corsie dei periodi")
struct SpanLaneTests {

    private let base = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3600) }

    private func span(_ name: String, _ from: Double, _ to: Double?) -> DaySpan {
        DaySpan(id: name, accessoryUUID: UUID(), name: name, roomName: nil,
                eventType: "airPurifier", start: at(from),
                end: to.map(at), startsBeforeWindow: false)
    }

    @Test("Periodi che non si toccano stanno tutti sulla prima riga")
    func disjointShareOneLane() {
        let placed = DayRibbonView.assignLanes([span("a", 1, 2), span("b", 5, 6), span("c", 9, 10)],
                                               now: at(12))
        #expect(placed.allSatisfy { $0.lane == 0 })
    }

    @Test("Periodi sovrapposti finiscono su righe diverse")
    func overlappingGetOwnLanes() {
        let placed = DayRibbonView.assignLanes([span("a", 1, 8), span("b", 2, 9), span("c", 3, 10)],
                                               now: at(12))
        #expect(Set(placed.map(\.lane)) == [0, 1, 2])
    }

    @Test("La riga si riusa appena si libera")
    func lanesAreReused() {
        let placed = DayRibbonView.assignLanes([span("a", 1, 4), span("b", 2, 5), span("c", 6, 8)],
                                               now: at(12))
        let byName = Dictionary(uniqueKeysWithValues: placed.map { ($0.span.name, $0.lane) })
        #expect(byName["a"] == 0)
        #expect(byName["b"] == 1)
        #expect(byName["c"] == 0, "quando «a» è finito la prima riga torna libera")
    }

    @Test("Oltre le righe disponibili si rinuncia invece di accavallare")
    func overflowIsDroppedNotStacked() {
        let crowd = (0..<6).map { span("s\($0)", Double($0) * 0.1, 10) }
        let placed = DayRibbonView.assignLanes(crowd, now: at(12))
        #expect(placed.count == DayRibbonView.spanLanes)
        #expect(Set(placed.map(\.lane)).count == placed.count, "e nessuna riga porta due barre")
    }

    @Test("Un periodo ancora aperto occupa la riga fino ad adesso")
    func openSpanHoldsItsLane() {
        let placed = DayRibbonView.assignLanes([span("aperto", 1, nil), span("dopo", 5, 6)],
                                               now: at(12))
        let byName = Dictionary(uniqueKeysWithValues: placed.map { ($0.span.name, $0.lane) })
        #expect(byName["dopo"] != byName["aperto"],
                "l'aperto arriva fino ad adesso, quindi la riga è ancora sua")
    }

    @Test("L'ordine di ingresso non cambia il risultato")
    func inputOrderDoesNotMatter() {
        let a = span("a", 1, 8), b = span("b", 2, 9)
        let one = DayRibbonView.assignLanes([a, b], now: at(12))
        let two = DayRibbonView.assignLanes([b, a], now: at(12))
        #expect(one == two)
    }
}
