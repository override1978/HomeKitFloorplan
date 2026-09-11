import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("HomeState — presente in memoria, freschezza e medie")
struct HomeStateTests {

    // MARK: - Fixture

    // `nonisolated`: compaiono come valori di default degli argomenti, che si
    // valutano fuori dall'isolamento della suite.
    nonisolated private static let soggiorno = UUID()
    nonisolated private static let cucina    = UUID()
    nonisolated private static let termoA    = UUID()
    nonisolated private static let termoB    = UUID()

    /// Stato senza differimento: gli ingressi si applicano subito, così i test
    /// non dipendono dal ciclo di run loop.
    private func makeState() -> HomeState { HomeState(coalescing: false) }

    private func feed(_ state: HomeState,
                      _ type: SensorServiceType,
                      _ value: Double,
                      room: UUID = HomeStateTests.soggiorno,
                      roomName: String = "Soggiorno",
                      accessory: UUID = HomeStateTests.termoA,
                      accessoryName: String = "Termo A",
                      at: Date) {
        state.ingest(type: type,
                     roomUUID: room,
                     roomName: roomName,
                     accessoryUUID: accessory,
                     accessoryName: accessoryName,
                     value: value,
                     now: at)
    }

    // MARK: - Lettura immediata

    @Test("Una misura appena arrivata si legge subito, senza fetch")
    func readsImmediately() {
        let state = makeState()
        let now = Date()
        feed(state, .temperature, 21.5, at: now)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: now) == 21.5)
        #expect(state.roomName(Self.soggiorno) == "Soggiorno")
    }

    @Test("Una stanza senza misure risponde nil, non zero")
    func missingRoomIsNil() {
        let state = makeState()
        #expect(state.value(.temperature, inRoom: Self.cucina) == nil)
    }

    @Test("Lookup per nome di stanza, per i consumatori che parlano stringhe")
    func lookupByName() {
        let state = makeState()
        let now = Date()
        feed(state, .carbonDioxide, 1340, room: Self.cucina, roomName: "Cucina", at: now)

        #expect(state.value(.carbonDioxide, inRoomNamed: "Cucina", now: now) == 1340)
        #expect(state.value(.carbonDioxide, inRoomNamed: "Bagno", now: now) == nil)
    }

    // MARK: - Le due date

    @Test("Valore invariato: `at` resta l'originale, `confirmedAt` avanza")
    func unchangedValueKeepsOriginalInstant() throws {
        let state = makeState()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(10 * 60)

        feed(state, .temperature, 21.5, at: t0)
        feed(state, .temperature, 21.5, at: t1)

        let reading = try #require(state.reading(.temperature, inRoom: Self.soggiorno, now: t1))
        #expect(reading.at == t0,          "un valore stabile non deve sembrare appena cambiato")
        #expect(reading.confirmedAt == t1, "ma il sensore si è fatto sentire adesso")
        #expect(reading.unchangedFor(now: t1) == 10 * 60)
        #expect(reading.age(now: t1) == 0)
    }

    @Test("Valore cambiato: `at` riparte")
    func changedValueResetsInstant() throws {
        let state = makeState()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(10 * 60)

        feed(state, .temperature, 21.5, at: t0)
        feed(state, .temperature, 22.0, at: t1)

        let reading = try #require(state.reading(.temperature, inRoom: Self.soggiorno, now: t1))
        #expect(reading.value == 22.0)
        #expect(reading.at == t1)
        #expect(reading.unchangedFor(now: t1) == 0)
    }

    // MARK: - Freschezza

    @Test("Oltre la soglia la lettura esce dai valori correnti")
    func staleReadingIsExcluded() {
        let state = makeState()
        let t0 = Date()
        let later = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        feed(state, .temperature, 21.5, at: t0)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: t0) == 21.5)
        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: later) == nil,
                "un sensore che tace da mezz'ora non deve più contribuire")
        #expect(state.reading(.temperature, inRoom: Self.soggiorno, now: later) == nil)
    }

    @Test("Una lettura stantia resta visibile come diagnosi, non sparisce")
    func staleReadingIsStillReportable() throws {
        let state = makeState()
        let t0 = Date()
        let later = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        feed(state, .temperature, 21.5, at: t0)

        let stale = state.staleReadings(now: later)
        #expect(stale.count == 1)
        let first = try #require(stale.first)
        #expect(first.slot.type == .temperature)
        #expect(first.reading.accessoryName == "Termo A")
        #expect(state.staleReadings(now: t0).isEmpty)
    }

    // MARK: - Più sensori nella stessa stanza

    @Test("Due sensori nella stessa stanza: media dei vivi")
    func averagesLiveSensors() {
        let state = makeState()
        let now = Date()

        feed(state, .temperature, 20.0, accessory: Self.termoA, accessoryName: "Termo A", at: now)
        feed(state, .temperature, 24.0, accessory: Self.termoB, accessoryName: "Termo B", at: now)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: now) == 22.0)
        #expect(state.allReadings(.temperature, inRoom: Self.soggiorno, now: now).count == 2)
    }

    @Test("Un sensore morto non trascina più la media della stanza")
    func deadSensorDropsOutOfTheAverage() {
        let state = makeState()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        // A si ferma a t0 con un valore assurdo, B continua a riportare.
        feed(state, .temperature, 40.0, accessory: Self.termoA, accessoryName: "Termo A", at: t0)
        feed(state, .temperature, 20.0, accessory: Self.termoB, accessoryName: "Termo B", at: t0)
        feed(state, .temperature, 20.0, accessory: Self.termoB, accessoryName: "Termo B", at: t1)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: t0) == 30.0)
        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: t1) == 20.0,
                "è esattamente il caso che oggi lascia un sensore spento dentro il punteggio")
    }

    @Test("La lettura più recente vince fra sensori vivi")
    func freshestWins() throws {
        let state = makeState()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(60)

        feed(state, .humidity, 50, accessory: Self.termoA, accessoryName: "Termo A", at: t0)
        feed(state, .humidity, 70, accessory: Self.termoB, accessoryName: "Termo B", at: t1)

        let reading = try #require(state.reading(.humidity, inRoom: Self.soggiorno, now: t1))
        #expect(reading.accessoryName == "Termo B")
    }

    // MARK: - Tipi disponibili

    @Test("I tipi disponibili seguono la freschezza, non la storia")
    func availableTypesFollowFreshness() {
        let state = makeState()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        feed(state, .temperature, 21.5, at: t0)
        feed(state, .humidity, 55, at: t0)
        feed(state, .humidity, 55, at: t1)

        #expect(state.availableTypes(inRoom: Self.soggiorno, now: t0) == [.temperature, .humidity])
        #expect(state.availableTypes(inRoom: Self.soggiorno, now: t1) == [.humidity])
    }

    // MARK: - Stanze

    @Test("Stanze diverse non si mescolano")
    func roomsAreIndependent() {
        let state = makeState()
        let now = Date()

        feed(state, .temperature, 21.5, room: Self.soggiorno, roomName: "Soggiorno", at: now)
        feed(state, .temperature, 18.0, room: Self.cucina, roomName: "Cucina",
             accessory: UUID(), accessoryName: "Termo Cucina", at: now)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: now) == 21.5)
        #expect(state.value(.temperature, inRoom: Self.cucina, now: now) == 18.0)
        #expect(Set(state.knownRoomUUIDs) == [Self.soggiorno, Self.cucina])
    }

    @Test("La stanza rinominata resta la stessa: la chiave è l'UUID")
    func renamingARoomKeepsTheSeries() {
        let state = makeState()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(60)

        feed(state, .temperature, 21.0, roomName: "Soggiorno", at: t0)
        feed(state, .temperature, 21.5, roomName: "Living", at: t1)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: t1) == 21.5,
                "rinominare in HomeKit non deve spezzare la serie in due")
        #expect(state.roomName(Self.soggiorno) == "Living")
        #expect(state.knownRoomUUIDs.count == 1)
    }

    @Test("Il reset svuota tutto")
    func resetClearsEverything() {
        let state = makeState()
        feed(state, .temperature, 21.5, at: Date())
        state.reset()

        #expect(state.knownRoomUUIDs.isEmpty)
        #expect(state.value(.temperature, inRoom: Self.soggiorno) == nil)
        #expect(state.roomName(Self.soggiorno) == nil)
    }

    // MARK: - Normalizzazione dei valori grezzi

    @Test("I numeri arrivano da HomeKit in forme diverse e vanno tutti normalizzati")
    func numericNormalization() {
        #expect(HomeState.numericValue(from: 21.5, type: .temperature) == 21.5)
        #expect(HomeState.numericValue(from: Float(21.5), type: .temperature) == 21.5)
        #expect(HomeState.numericValue(from: Int(21), type: .temperature) == 21)
        #expect(HomeState.numericValue(from: NSNumber(value: 21.5), type: .temperature) == 21.5)
        #expect(HomeState.numericValue(from: "caldo", type: .temperature) == nil)
    }

    @Test("Gli allarmi booleani diventano 0 o 1")
    func booleanAlertsNormalize() {
        #expect(SensorServiceType.smoke.isBooleanAlert)
        #expect(HomeState.numericValue(from: true, type: .smoke) == 1)
        #expect(HomeState.numericValue(from: false, type: .smoke) == 0)
    }

    @Test("Nessuna validazione di plausibilità: HomeState riporta, non giudica")
    func doesNotValidateRanges() {
        let state = makeState()
        let now = Date()
        feed(state, .temperature, -40, at: now)

        #expect(state.value(.temperature, inRoom: Self.soggiorno, now: now) == -40,
                "scartare un valore implausibile è lavoro di chi interpreta, non di chi registra")
    }
}
