import Foundation
import Testing
@testable import HomeFloorplan

@MainActor
@Suite("EnvironmentViewModel — percorso vivo da HomeState")
struct EnvironmentLiveStateTests {

    nonisolated private static let soggiorno = UUID()
    nonisolated private static let cucina    = UUID()
    nonisolated private static let sensorA   = UUID()
    nonisolated private static let sensorB   = UUID()

    private func makeState() -> HomeState { HomeState(coalescing: false) }

    private func feed(_ state: HomeState,
                      _ type: SensorServiceType,
                      _ value: Double,
                      room: UUID = EnvironmentLiveStateTests.soggiorno,
                      roomName: String = "Soggiorno",
                      accessory: UUID = EnvironmentLiveStateTests.sensorA,
                      at: Date) {
        state.ingest(type: type,
                     roomUUID: room,
                     roomName: roomName,
                     accessoryUUID: accessory,
                     accessoryName: "Sensore",
                     value: value,
                     now: at)
    }

    // MARK: - Costruzione

    @Test("Costruisce le stanze senza toccare l'archivio: nessun ModelContainer configurato")
    func buildsWithoutDatabase() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .temperature, 21.5, at: now)
        feed(state, .humidity, 48, at: now)

        let rooms = vm.applyLiveState(state, now: now)

        let room = try #require(rooms.first { $0.roomName == "Soggiorno" })
        #expect(room.sensors.count == 2)
        #expect(room.sensors.contains { $0.serviceType == .temperature && $0.currentValue == 21.5 })
        #expect(room.sensors.contains { $0.serviceType == .humidity && $0.currentValue == 48 })
    }

    @Test("`lastUpdated` è l'istante in cui il sensore si è fatto sentire")
    func lastUpdatedComesFromConfirmation() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(5 * 60)

        feed(state, .temperature, 21.5, at: t0)
        feed(state, .temperature, 21.5, at: t1)

        let rooms = vm.applyLiveState(state, now: t1)
        let sensor = try #require(rooms.first?.sensors.first)
        #expect(sensor.lastUpdated == t1)
    }

    @Test("Gli UUID degli accessori restano nel formato che l'archivio usa")
    func accessoryUUIDFormatMatchesArchive() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .temperature, 21.5, accessory: Self.sensorA, at: now)

        let sensor = try #require(vm.applyLiveState(state, now: now).first?.sensors.first)
        #expect(sensor.accessoryUUIDs == [Self.sensorA.uuidString],
                "SensorLogger scrive uniqueIdentifier.uuidString: i due percorsi devono combaciare")
    }

    // MARK: - Aggregazione

    @Test("Più sensori numerici nella stessa stanza: media")
    func averagesNumericSensors() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .temperature, 20, accessory: Self.sensorA, at: now)
        feed(state, .temperature, 24, accessory: Self.sensorB, at: now)

        let sensor = try #require(vm.applyLiveState(state, now: now).first?.sensors.first)
        #expect(sensor.currentValue == 22)
        #expect(sensor.sourceCount == 2)
    }

    @Test("Allarmi e qualità aria: vince il peggiore, non la media")
    func worstCaseForAlerts() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .smoke, 0, accessory: Self.sensorA, at: now)
        feed(state, .smoke, 1, accessory: Self.sensorB, at: now)

        let sensor = try #require(vm.applyLiveState(state, now: now).first?.sensors.first)
        #expect(sensor.currentValue == 1, "mediare due rilevatori di fumo darebbe 0,5 — cioè niente")
    }

    // MARK: - Freschezza

    @Test("La stanza muta resta in scena, ma dichiarata muta")
    func silentRoomIsMarkedNotHidden() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let later = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        feed(state, .temperature, 21.5, at: t0)

        let live = try #require(vm.applyLiveState(state, now: t0).first)
        #expect(live.isSilent == false)
        #expect(live.sensors.first?.isStale == false)

        let silent = try #require(vm.applyLiveState(state, now: later).first)
        #expect(silent.isSilent, "far sparire la stanza nasconderebbe che il sensore è morto")
        #expect(silent.sensors.first?.currentValue == 21.5,
                "l'ultimo valore resta: è l'unica informazione rimasta")
        #expect(silent.sensors.first?.isStale == true)
        #expect((silent.silentFor ?? 0) > HomeState.defaultStaleInterval)
    }

    @Test("Una stanza muta non è una stanza eccellente")
    func silentRoomIsNotExcellent() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let later = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        // Valore da allarme che poi smette di aggiornarsi.
        feed(state, .carbonDioxide, 3000, at: t0)

        let alarmed = try #require(vm.applyLiveState(state, now: t0).first)
        #expect(alarmed.worstUrgency == .danger)

        let silent = try #require(vm.applyLiveState(state, now: later).first)
        #expect(silent.worstUrgency == .normal,
                "un valore fermo non deve più guidare l'urgenza: non sappiamo se vale ancora")
        #expect(silent.qualityLabel != String(localized: "quality.excellent", defaultValue: "Excellent"),
                "ed è proprio qui che il punteggio neutro mentirebbe")
        #expect(silent.liveSensors.isEmpty)
    }

    @Test("Un sensore muto fra due vivi non tinge la stanza ma resta leggibile")
    func partiallySilentRoom() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        feed(state, .carbonDioxide, 3000, at: t0)              // si ferma qui
        feed(state, .temperature, 21.0, at: t0)
        feed(state, .temperature, 21.0, at: t1)                // continua

        let room = try #require(vm.applyLiveState(state, now: t1).first)
        #expect(room.isSilent == false, "la stanza parla ancora, tramite il termometro")
        #expect(room.sensors.count == 2, "ma la CO₂ resta visibile")
        #expect(room.liveSensors.count == 1)
        #expect(room.worstUrgency == .normal,
                "la CO₂ ferma a 3000 non deve più dipingere la stanza di rosso")
        let co2 = try #require(room.sensors.first { $0.serviceType == .carbonDioxide })
        #expect(co2.isStale)
    }

    @Test("Il sensore morto non trascina il punteggio della stanza")
    func deadSensorDoesNotDragTheScore() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(HomeState.defaultStaleInterval + 60)

        // Il primo si blocca su un valore da allarme, il secondo continua sano.
        feed(state, .carbonDioxide, 3000, accessory: Self.sensorA, at: t0)
        feed(state, .carbonDioxide, 600, accessory: Self.sensorB, at: t0)
        feed(state, .carbonDioxide, 600, accessory: Self.sensorB, at: t1)

        let before = try #require(vm.applyLiveState(state, now: t0).first)
        let after  = try #require(vm.applyLiveState(state, now: t1).first)

        #expect(before.sensors.first?.sourceCount == 2)
        #expect(after.sensors.first?.sourceCount == 1)
        #expect(after.qualityScore > before.qualityScore,
                "escludere il sensore fermo deve migliorare il punteggio, non lasciarlo inchiodato")
    }

    // MARK: - Stanze

    @Test("Stanze distinte restano distinte e si ordinano per urgenza")
    func roomsAreSeparateAndSortedByUrgency() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .carbonDioxide, 400, room: Self.soggiorno, roomName: "Soggiorno", at: now)
        feed(state, .carbonDioxide, 3000, room: Self.cucina, roomName: "Cucina",
             accessory: Self.sensorB, at: now)

        let rooms = vm.applyLiveState(state, now: now)
        #expect(rooms.count == 2)
        let first = try #require(rooms.first)
        #expect(first.roomName == "Cucina", "la stanza critica va in cima")
        #expect(first.worstUrgency == .danger)
    }

    @Test("Senza soglie caricate valgono quelle di default del tipo")
    func fallsBackToDefaultThresholds() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .carbonDioxide, 400, at: now)

        let sensor = try #require(vm.applyLiveState(state, now: now).first?.sensors.first)
        #expect(sensor.warningThreshold == SensorServiceType.carbonDioxide.defaultWarning)
        #expect(sensor.dangerThreshold == SensorServiceType.carbonDioxide.defaultDanger)
    }

    @Test("Senza storico il trend è fermo, non inventato")
    func trendIsSteadyUntilTheArchiveAnswers() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .temperature, 21.5, at: now)

        let sensor = try #require(vm.applyLiveState(state, now: now).first?.sensors.first)
        #expect(sensor.trend == .steady)
    }

    @Test("L'ordine dei sensori non cambia fra due ricostruzioni identiche")
    func sensorOrderIsStable() {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        // Quattro tipi tutti tranquilli: senza spareggio l'urgenza non
        // ordinerebbe niente e l'ordine resterebbe quello del Set.
        feed(state, .temperature, 21, at: now)
        feed(state, .humidity, 45, at: now)
        feed(state, .lightSensor, 120, at: now)
        feed(state, .carbonDioxide, 500, at: now)

        let first  = vm.applyLiveState(state, now: now).first?.sensors.map(\.serviceType)
        let second = vm.applyLiveState(state, now: now).first?.sensors.map(\.serviceType)
        let third  = vm.applyLiveState(state, now: now).first?.sensors.map(\.serviceType)

        #expect(first == second)
        #expect(second == third)
        #expect(first?.count == 4)
    }

    @Test("Anche l'ordine delle stanze tranquille è stabile")
    func roomOrderIsStable() {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .temperature, 21, room: Self.soggiorno, roomName: "Soggiorno", at: now)
        feed(state, .temperature, 21, room: Self.cucina, roomName: "Cucina",
             accessory: Self.sensorB, at: now)

        let first  = vm.applyLiveState(state, now: now).map(\.roomName)
        let second = vm.applyLiveState(state, now: now).map(\.roomName)

        #expect(first == second)
        #expect(first == ["Cucina", "Soggiorno"], "a parità di urgenza decide il nome")
    }

    // MARK: - Attenzione: soglia più baseline

    @Test("All'aperto il comfort non conta: umidità e temperatura non allarmano")
    func outdoorRoomIsNotJudgedByIndoorComfort() {
        // 65% di umidità su un balcone a mezzanotte è la notte, non un'anomalia.
        let outdoor = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .humidity,
            roomName: "Balcone", currentValue: 65, lastUpdated: Date(),
            warningThreshold: 60, dangerThreshold: 75, sourceCount: 1,
            roomType: .outdoor
        )
        #expect(outdoor.urgency == .normal)

        let indoor = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .humidity,
            roomName: "Bagno", currentValue: 65, lastUpdated: Date(),
            warningThreshold: 60, dangerThreshold: 75, sourceCount: 1,
            roomType: .indoor
        )
        #expect(indoor.urgency == .warning, "lo stesso numero dentro casa resta una segnalazione")
    }

    @Test("Gli allarmi veri suonano anche all'aperto")
    func hardAlarmsIgnoreRoomType() {
        let smoke = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .smoke,
            roomName: "Balcone", currentValue: 1, lastUpdated: Date(),
            warningThreshold: 1, dangerThreshold: 1, sourceCount: 1,
            roomType: .outdoor
        )
        #expect(smoke.urgency == .danger)
    }

    @Test("Sopra soglia ma dentro il proprio normale: nessuna attenzione")
    func withinOwnNormalIsQuiet() {
        // Bagno al 75% a mezzanotte, con un normale di 72% e σ 6 → 0,5σ.
        let usual = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .humidity,
            roomName: "Bagno", currentValue: 75, lastUpdated: Date(),
            warningThreshold: 60, dangerThreshold: 80, sourceCount: 1,
            baselineSigma: 0.5
        )
        #expect(usual.urgency == .normal, "è quello che fa un bagno dopo una doccia")
    }

    @Test("Sopra soglia e fuori dal normale: attenzione")
    func beyondOwnNormalStillAlerts() {
        // Cucina a 930 ppm con un normale di 600 e σ 100 → 3,3σ.
        let unusual = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .carbonDioxide,
            roomName: "Cucina", currentValue: 930, lastUpdated: Date(),
            warningThreshold: 800, dangerThreshold: 1500, sourceCount: 1,
            baselineSigma: 3.3
        )
        #expect(unusual.urgency == .warning)
    }

    @Test("Senza baseline non si sopprime niente")
    func noBaselineKeepsOldBehaviour() {
        let noBaseline = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .humidity,
            roomName: "Bagno", currentValue: 75, lastUpdated: Date(),
            warningThreshold: 60, dangerThreshold: 80, sourceCount: 1
        )
        #expect(noBaseline.baselineSigma == nil)
        #expect(noBaseline.urgency == .warning,
                "meglio un falso positivo che un falso silenzio finché non conosciamo la stanza")
    }

    @Test("Il monossido non si smorza mai con la statistica")
    func carbonMonoxideIsNeverSuppressed() {
        let co = SensorData(
            id: UUID(), accessoryUUIDs: ["a"], serviceType: .carbonMonoxide,
            roomName: "Cucina", currentValue: 60, lastUpdated: Date(),
            warningThreshold: 50, dangerThreshold: 100, sourceCount: 1,
            baselineSigma: 0.1
        )
        #expect(co.urgency == .warning, "abituarsi al monossido non è un normale accettabile")
    }

    // MARK: - Identità

    @Test("L'identità di una stanza non cambia fra due ricostruzioni")
    func roomIdentityIsStable() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let now = Date()

        feed(state, .temperature, 21, room: Self.soggiorno, roomName: "Soggiorno", at: now)
        feed(state, .temperature, 19, room: Self.cucina, roomName: "Cucina",
             accessory: Self.sensorB, at: now)

        let first  = vm.applyLiveState(state, now: now).map(\.id)
        let second = vm.applyLiveState(state, now: now.addingTimeInterval(1)).map(\.id)

        #expect(first == second,
                "con identità nuove a ogni giro SwiftUI smonta e rimonta le card invece di aggiornarle")
    }

    @Test("L'identità sopravvive anche a un cambio di valore")
    func roomIdentitySurvivesValueChange() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(60)

        feed(state, .temperature, 21, at: t0)
        let before = try #require(vm.applyLiveState(state, now: t0).first)

        feed(state, .temperature, 24, at: t1)
        let after = try #require(vm.applyLiveState(state, now: t1).first)

        #expect(before.id == after.id, "è la stessa stanza: deve aggiornarsi, non rinascere")
        #expect(after.sensors.first?.currentValue == 24)
    }

    @Test("Due ViewModel diversi danno alla stessa stanza la stessa identità")
    func roomIdentityIsDeterministicAcrossInstances() throws {
        let state = makeState()
        let now = Date()
        feed(state, .temperature, 21, at: now)

        let a = try #require(EnvironmentViewModel().applyLiveState(state, now: now).first)
        let b = try #require(EnvironmentViewModel().applyLiveState(state, now: now).first)
        #expect(a.id == b.id)
    }

    @Test("Stato vuoto: nessuna stanza, nessun crash")
    func emptyStateYieldsNoRooms() {
        let vm = EnvironmentViewModel()
        #expect(vm.applyLiveState(makeState()).isEmpty)
    }

    @Test("Una nuova misura riallinea la schermata senza toccare il disco")
    func newReadingRefreshesRooms() throws {
        let state = makeState()
        let vm = EnvironmentViewModel()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(60)

        feed(state, .temperature, 21.0, at: t0)
        #expect(vm.applyLiveState(state, now: t0).first?.sensors.first?.currentValue == 21.0)

        // Come se HomeKit avesse appena consegnato una notifica.
        feed(state, .temperature, 23.4, at: t1)
        let sensor = try #require(vm.applyLiveState(state, now: t1).first?.sensors.first)
        #expect(sensor.currentValue == 23.4)
        #expect(sensor.lastUpdated == t1)
    }
}
