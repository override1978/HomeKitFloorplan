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

    @Test("Uno spegnimento senza accensione non inventa una durata")
    func offFirstDoesNotInventAStart() {
        let uuid = UUID()
        let spans = DaySpanBuilder.build(from: [change(uuid, on: false, at: 7)],
                                         window: day, now: at(12))
        #expect(spans.isEmpty, "senza aver visto l'accensione, partire da mezzanotte sarebbe una deduzione falsa")
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

    @Test("Prese e switch non diventano barre continue")
    func outletsAndSwitchesAreNotProcesses() {
        let outlet = UUID()
        let switchID = UUID()
        let spans = DaySpanBuilder.build(from: [
            change(outlet, on: true, at: 1, type: "outlet", name: "Multipresa"),
            change(switchID, on: true, at: 2, type: "switch", name: "Switch")
        ], window: day, now: at(20))

        #expect(spans.isEmpty, "stati lunghi sempre accesi riempiono il nastro senza raccontare un processo")
    }

    @Test("I climatizzatori sono processi")
    func thermostatsAreProcesses() throws {
        let thermostat = UUID()
        let spans = DaySpanBuilder.build(from: [
            change(thermostat, on: true, at: 16, type: "thermostat", name: "Condizionatore"),
            change(thermostat, on: false, at: 22, type: "thermostat", name: "Condizionatore")
        ], window: day, now: at(23))

        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(span.name == "Condizionatore")
        #expect(span.duration(now: at(23)) == 6 * 3600)
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
                end: to.map(at), startsBeforeWindow: false, startedByHand: false)
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

    @Test("Anche a parità di inizio le corsie restano ferme")
    func equalStartsStayPut() {
        // Il caso vero: tutto ciò che era già acceso a mezzanotte comincia
        // esattamente al bordo della finestra, quindi i pari merito sono la
        // norma e non l'eccezione. Con un ordinamento sul solo inizio decideva
        // il caso, e le barre del passato si spostavano da sole al minuto.
        let together = [span("a", 0, 5), span("b", 0, 7), span("c", 0, 3)]
        let reference = DayRibbonView.assignLanes(together, now: at(12))
        for permutation in [[2, 0, 1], [1, 2, 0], [2, 1, 0]] {
            let shuffled = permutation.map { together[$0] }
            #expect(DayRibbonView.assignLanes(shuffled, now: at(12)) == reference)
        }
    }

    @Test("Ricostruire un minuto dopo non muove il passato")
    func aMinuteLaterNothingMoves() {
        let day = DateInterval(start: base, duration: 24 * 3600)
        let uuid = UUID(), other = UUID()
        let raw = [
            HumanGestureBuilder.RawChange(accessoryUUID: uuid, accessoryName: "A", roomName: nil,
                                          state: false, brightness: nil, eventType: "outlet",
                                          at: at(7), origin: "external"),
            HumanGestureBuilder.RawChange(accessoryUUID: other, accessoryName: "B", roomName: nil,
                                          state: false, brightness: nil, eventType: "switch",
                                          at: at(9), origin: "external")
        ]
        let first = DayRibbonView.assignLanes(
            DaySpanBuilder.build(from: raw, window: day, now: at(11)), now: at(11))
        let later = DayRibbonView.assignLanes(
            DaySpanBuilder.build(from: raw, window: day, now: at(11.02)), now: at(11.02))
        #expect(first.map { ($0.span.id, $0.lane) }.map(\.1)
                == later.map { ($0.span.id, $0.lane) }.map(\.1))
    }
}

/// Cosa una barra riesce a dire di sé.
@Suite("Le barre si presentano")
struct SpanIdentityTests {

    private func span(type: String) -> DaySpan {
        DaySpan(id: "x", accessoryUUID: UUID(), name: "X", roomName: nil,
                eventType: type, start: Date(), end: nil,
                startsBeforeWindow: false, startedByHand: false)
    }

    @Test("Ogni tipo di processo ha il suo simbolo")
    func eachTypeHasASymbol() {
        #expect(DayRibbonView.spanSymbol(for: span(type: "airPurifier")) == "air.purifier")
        #expect(DayRibbonView.spanSymbol(for: span(type: "fan")) == "fan")
        #expect(DayRibbonView.spanSymbol(for: span(type: "humidifier")) == "humidifier")
        #expect(DayRibbonView.spanSymbol(for: span(type: "thermostat")) == "thermometer")
        #expect(DayRibbonView.spanSymbol(for: span(type: "outlet")) == "powerplug")
    }

    @Test("Un tipo sconosciuto non resta senza simbolo")
    func unknownTypeStillHasOne() {
        // Una barra muta costringe a toccarla per sapere cos'è, che su un
        // pannello al muro vuol dire non dirlo.
        #expect(DayRibbonView.spanSymbol(for: span(type: "qualcosa")).isEmpty == false)
    }
}

/// Dove barra e rombo raccontano lo stesso fatto, resta la barra.
@Suite("Un fatto, un oggetto")
struct SpanGestureOverlapTests {

    private let base = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ hour: Double) -> Date { base.addingTimeInterval(hour * 3600) }
    private var day: DateInterval { DateInterval(start: base, duration: 24 * 3600) }

    private func raw(_ uuid: UUID, on: Bool, at hour: Double,
                     type: String, name: String) -> HumanGestureBuilder.RawChange {
        HumanGestureBuilder.RawChange(accessoryUUID: uuid, accessoryName: name,
                                      roomName: "Studio", state: on, brightness: nil,
                                      eventType: type, at: at(hour), origin: "external")
    }

    @Test("Accendere a mano il purificatore lascia solo la barra")
    func onlyTheBarSurvives() {
        let uuid = UUID()
        let events = [raw(uuid, on: true, at: 9, type: "airPurifier", name: "Purificatore"),
                      raw(uuid, on: false, at: 11, type: "airPurifier", name: "Purificatore")]
        let spans = DaySpanBuilder.build(from: events, window: day, now: at(12))
        let gestures = HumanGestureBuilder.build(from: events, now: at(12))
        #expect(spans.count == 1)
        #expect(gestures.isEmpty == false, "il gesto esiste...")
        #expect(HumanGestureBuilder.removingCovered(gestures, by: spans).isEmpty,
                "...ma la barra lo dice già, e meglio")
    }

    @Test("Se il gesto ha toccato anche una luce, il rombo resta")
    func partialCoverageKeepsTheGesture() {
        let purifier = UUID(), lamp = UUID()
        let events = [raw(purifier, on: true, at: 9, type: "airPurifier", name: "Purificatore"),
                      raw(lamp, on: true, at: 9.01, type: "light", name: "Piantana"),
                      raw(purifier, on: false, at: 11, type: "airPurifier", name: "Purificatore")]
        let spans = DaySpanBuilder.build(from: events, window: day, now: at(12))
        let gestures = HumanGestureBuilder.build(from: events, now: at(12))
        #expect(HumanGestureBuilder.removingCovered(gestures, by: spans).count == 1,
                "la luce non produce barre: senza il rombo sparirebbe dal nastro")
    }

    @Test("Una scena riconosciuta resta anche se le barre la coprono")
    func scenesAreNeverRedundant() {
        let uuids = (0..<10).map { _ in UUID() }
        let events = uuids.enumerated().map {
            raw($0.element, on: true, at: 9 + Double($0.offset) * 0.001,
                type: "outlet", name: "Presa \($0.offset)")
        }
        let spans = DaySpanBuilder.build(from: events, window: day, now: at(12))
        let scene = HumanGestureBuilder.SceneSignature(id: UUID(), name: "Cinema",
                                                       accessoryUUIDs: Set(uuids))
        let gestures = HumanGestureBuilder.build(from: events, scenes: [scene], now: at(12))
        #expect(HumanGestureBuilder.removingCovered(gestures, by: spans).count == 1,
                "il nome della scena è informazione che nessuna barra porta")
    }

    @Test("Senza barre non si toglie niente")
    func noSpansNoRemoval() {
        let uuid = UUID()
        let events = [raw(uuid, on: true, at: 9, type: "light", name: "Piantana")]
        let gestures = HumanGestureBuilder.build(from: events, now: at(12))
        #expect(HumanGestureBuilder.removingCovered(gestures, by: []).count == gestures.count)
    }

    @Test("La barra sa se l'ha accesa una mano")
    func spanKnowsWhoStartedIt() throws {
        let uuid = UUID()
        let byHand = DaySpanBuilder.build(
            from: [raw(uuid, on: true, at: 9, type: "airPurifier", name: "P")],
            window: day, now: at(12))
        #expect(try #require(byHand.first).startedByHand)

        // Lo stesso istante, ma a ridosso di uno scatto previsto: è
        // l'automazione, e dirlo «a mano» sarebbe attribuirlo a qualcuno.
        let byAutomation = DaySpanBuilder.build(
            from: [raw(uuid, on: true, at: 9, type: "airPurifier", name: "P")],
            window: day, scheduledFires: [at(9)], now: at(12))
        #expect(try #require(byAutomation.first).startedByHand == false)
    }

    @Test("Una scrittura dell'app non è una mano")
    func appWritesAreNotHands() throws {
        let uuid = UUID()
        let engine = HumanGestureBuilder.RawChange(
            accessoryUUID: uuid, accessoryName: "P", roomName: nil, state: true,
            brightness: nil, eventType: "airPurifier", at: at(9), origin: "engine")
        let spans = DaySpanBuilder.build(from: [engine], window: day, now: at(12))
        #expect(try #require(spans.first).startedByHand == false)
    }
}

/// Quando un valore appena visto va scritto in archivio.
///
/// Una decisione sola per tre percorsi — notifica push, scrittura nostra,
/// rilettura del battito — perché erano tre copie e una si è rivelata diversa
/// dalle altre senza che nessuno lo notasse.
@Suite("Cosa conta come avvenimento")
struct AccessoryEventRecordingTests {

    @Test("Senza stato noto si impara, non si racconta")
    func firstSightingIsNotAnEvent() {
        // È il difetto che riempiva l'archivio all'avvio: con la mappa vuota
        // ogni prima consegna sembrava un cambiamento.
        #expect(AccessoryEventStore.shouldRecord(known: nil, incoming: true) == false)
        #expect(AccessoryEventStore.shouldRecord(known: nil, incoming: false) == false)
    }

    @Test("Uno stato invariato non è un avvenimento")
    func echoesAreNotEvents() {
        #expect(AccessoryEventStore.shouldRecord(known: true, incoming: true) == false)
        #expect(AccessoryEventStore.shouldRecord(known: false, incoming: false) == false)
    }

    @Test("Una transizione da uno stato noto sì")
    func transitionsAreEvents() {
        #expect(AccessoryEventStore.shouldRecord(known: true, incoming: false))
        #expect(AccessoryEventStore.shouldRecord(known: false, incoming: true))
    }

    @Test("Vale anche quando la transizione la scopre una rilettura")
    func lateDiscoveryStillCounts() {
        // Le notifiche push cadono, e su un pannello sempre acceso non c'è
        // nessun ciclo background→foreground a rimettere le cose a posto. Se
        // la rilettura del battito trova un valore diverso da quello noto, quel
        // cambiamento è avvenuto: scoprirlo in ritardo non lo rende meno vero,
        // e non registrarlo lascia un periodo che non finisce mai.
        #expect(AccessoryEventStore.shouldRecord(known: true, incoming: false))
    }
}
