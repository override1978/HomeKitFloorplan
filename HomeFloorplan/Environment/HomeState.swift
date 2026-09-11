import Foundation
import HomeKit
import Observation

// MARK: - HomeState

/// Lo stato ambientale corrente della casa, in memoria.
///
/// Nasce per rispondere a una domanda che l'app non sapeva porre: *quanto è
/// la temperatura del soggiorno, adesso?* Finora non esisteva un modo di
/// chiederlo. Ogni consumatore ricostruiva l'intero array delle stanze —
/// fetch di 500 `SensorReading`, mappatura verso DTO, cinque passaggi di
/// raggruppamento sul main actor — e poi faceva `first(where:)`. Il pattern
/// compare in una quindicina di punti, con cinque `EnvironmentViewModel` vivi
/// contemporaneamente, ognuno col proprio `ModelContext` e il proprio ciclo di
/// ricarica, senza nessuna cache condivisa.
///
/// Peggio: quel percorso legge da SwiftData, che è in ritardo di minuti. Nello
/// stesso istante lo stesso sensore aveva **tre valori diversi** — la
/// dashboard leggeva l'archivio, i marker della planimetria leggevano la cache
/// di `HomeKitService`, e le notifiche push di HomeKit aggiornavano quella
/// cache senza scrivere mai una riga.
///
/// Qui il presente ha una sola casa. La sorgente sono le notifiche che
/// HomeKit già consegna in tempo reale, più una risemina periodica dai valori
/// che il framework tiene in cache (nessun round-trip). SwiftData smette di
/// essere la verità del presente e torna a essere solo l'archivio del passato.
///
/// Leggere costa un accesso a dizionario. Non c'è I/O, non c'è `await`.
@Observable
@MainActor
final class HomeState {

    // MARK: - Tipi

    /// Una lettura viva, con la sua età.
    ///
    /// Due date, non una, perché rispondono a domande diverse: `at` dice da
    /// quanto il valore non cambia, `confirmedAt` dice da quanto il sensore
    /// non si fa sentire. Confonderle significa non saper distinguere un
    /// ambiente stabile da un sensore morto — che è esattamente l'errore che
    /// oggi lascia un sensore spento da tre giorni dentro il punteggio della
    /// stanza, con un numero che in interfaccia sembra attuale.
    struct Reading: Sendable, Equatable {
        var value: Double
        /// Quando questo valore è comparso (cioè l'ultima volta che è cambiato).
        var at: Date
        /// Quando l'abbiamo visto confermare l'ultima volta, anche invariato.
        var confirmedAt: Date
        var accessoryUUID: UUID
        var accessoryName: String

        func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(confirmedAt) }
        func isStale(after interval: TimeInterval, now: Date = Date()) -> Bool {
            age(now: now) > interval
        }
        /// Da quanto il valore non si muove, indipendentemente dalla vitalità.
        func unchangedFor(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(at) }
    }

    /// Coordinata di una misura: dove e di che tipo.
    ///
    /// La chiave è l'UUID della stanza e non il nome. I nomi sono denormalizzati
    /// ovunque nell'archivio, e una stanza rinominata in HomeKit vi spezza lo
    /// storico in due serie che non si riuniscono più. Qui il nome resta solo
    /// per la presentazione, in `roomNames`.
    struct Slot: Hashable, Sendable {
        var roomUUID: UUID
        var type: SensorServiceType
    }

    // MARK: - Stato

    /// Letture correnti, per coordinata e poi per accessorio.
    ///
    /// Il secondo livello esiste perché una stanza può avere due termometri, e
    /// tenerli distinti è l'unico modo di scartarne uno quando muore invece di
    /// lasciarlo pesare nella media.
    private(set) var readings: [Slot: [UUID: Reading]] = [:]

    /// Nome corrente di ogni stanza, per la sola presentazione.
    private(set) var roomNames: [UUID: String] = [:]

    /// Istante dell'ultima applicazione di nuovi valori.
    ///
    /// Serve come appiglio di osservazione: `readings` è un dizionario annidato
    /// e osservarlo direttamente da una vista significa ridisegnare a ogni
    /// mutazione di qualunque stanza. Qui un `onChange` su una singola data
    /// basta a sapere che c'è qualcosa di nuovo, e chi lo riceve decide cosa
    /// rileggere.
    private(set) var lastChange: Date = .distantPast

    /// Oltre questa età una lettura non concorre più ai valori aggregati.
    ///
    /// Trenta minuti: l'heartbeat di osservazione rilegge ogni dieci, quindi un
    /// sensore vivo viene confermato tre volte dentro la finestra.
    ///
    /// `nonisolated` perché compare come valore di default negli argomenti, e
    /// quelli si valutano fuori dall'isolamento del metodo.
    nonisolated static let defaultStaleInterval: TimeInterval = 30 * 60

    // MARK: - Coalescing

    /// Aggiornamenti in attesa di essere applicati alla fine del tick.
    ///
    /// Stessa ragione del batching già presente in `HomeKitService`: una
    /// riconnessione HomeKit ripubblica decine di caratteristiche nello stesso
    /// giro di run loop, e `readings` è una proprietà osservata — mutarla una
    /// volta per evento farebbe ridisegnare ogni vista che legge lo stato, a
    /// raffica. Accumulando e applicando una volta sola, gli osservatori si
    /// svegliano una volta per tick invece che una volta per sensore.
    private var pending: [Slot: [UUID: Reading]] = [:]
    private var pendingRoomNames: [UUID: String] = [:]
    private var flushScheduled = false

    /// Quando è falso ogni ingresso si applica subito.
    ///
    /// Esiste per i test, ma come parametro di costruzione e non come metodo
    /// di comodo: il differimento è una proprietà dell'oggetto, non un
    /// dettaglio che si aggira dall'esterno.
    private let coalescing: Bool

    // MARK: - Init

    init(coalescing: Bool = true) {
        self.coalescing = coalescing
    }

    // MARK: - Lettura

    /// Le stanze di cui conosciamo almeno una misura.
    var knownRoomUUIDs: [UUID] { Array(Set(readings.keys.map(\.roomUUID))) }

    /// La lettura più fresca per una coordinata, scartando quelle stantie.
    func reading(_ type: SensorServiceType,
                 inRoom roomUUID: UUID,
                 staleAfter: TimeInterval = HomeState.defaultStaleInterval,
                 now: Date = Date()) -> Reading? {
        readings[Slot(roomUUID: roomUUID, type: type)]?
            .values
            .filter { !$0.isStale(after: staleAfter, now: now) }
            .max { $0.confirmedAt < $1.confirmedAt }
    }

    /// Il valore corrente di una coordinata: media dei sensori vivi.
    ///
    /// `nil` quando non c'è nessuna misura fresca — che è un'informazione, non
    /// un errore, e va mostrata come tale invece di essere sostituita da zero
    /// o dall'ultimo numero noto.
    func value(_ type: SensorServiceType,
               inRoom roomUUID: UUID,
               staleAfter: TimeInterval = HomeState.defaultStaleInterval,
               now: Date = Date()) -> Double? {
        let live = (readings[Slot(roomUUID: roomUUID, type: type)] ?? [:])
            .values
            .filter { !$0.isStale(after: staleAfter, now: now) }
        guard !live.isEmpty else { return nil }
        return live.reduce(0) { $0 + $1.value } / Double(live.count)
    }

    /// Tutte le letture vive di una coordinata, sensore per sensore.
    func allReadings(_ type: SensorServiceType,
                     inRoom roomUUID: UUID,
                     staleAfter: TimeInterval = HomeState.defaultStaleInterval,
                     now: Date = Date()) -> [Reading] {
        (readings[Slot(roomUUID: roomUUID, type: type)] ?? [:])
            .values
            .filter { !$0.isStale(after: staleAfter, now: now) }
            .sorted { $0.confirmedAt > $1.confirmedAt }
    }

    /// I tipi di misura disponibili in una stanza, esclusi i sensori muti.
    func availableTypes(inRoom roomUUID: UUID,
                        staleAfter: TimeInterval = HomeState.defaultStaleInterval,
                        now: Date = Date()) -> Set<SensorServiceType> {
        var out: Set<SensorServiceType> = []
        for (slot, byAccessory) in readings where slot.roomUUID == roomUUID {
            if byAccessory.values.contains(where: { !$0.isStale(after: staleAfter, now: now) }) {
                out.insert(slot.type)
            }
        }
        return out
    }

    /// Le letture che esistono ma hanno smesso di aggiornarsi.
    ///
    /// Serve a dirlo invece di nasconderlo: un sensore che tace è una
    /// diagnosi, e oggi finisce silenziosamente dentro le medie.
    func staleReadings(staleAfter: TimeInterval = HomeState.defaultStaleInterval,
                       now: Date = Date()) -> [(slot: Slot, reading: Reading)] {
        readings.flatMap { slot, byAccessory in
            byAccessory.values
                .filter { $0.isStale(after: staleAfter, now: now) }
                .map { (slot: slot, reading: $0) }
        }
    }

    func roomName(_ roomUUID: UUID) -> String? { roomNames[roomUUID] }

    /// Variante per nome, per i consumatori che ancora parlano di stanze come
    /// stringhe. Risolve attraverso `roomNames`, quindi non introduce una
    /// seconda chiave: resta una comodità, non un secondo indice.
    func value(_ type: SensorServiceType,
               inRoomNamed name: String,
               staleAfter: TimeInterval = HomeState.defaultStaleInterval,
               now: Date = Date()) -> Double? {
        guard let uuid = roomNames.first(where: { $0.value == name })?.key else { return nil }
        return value(type, inRoom: uuid, staleAfter: staleAfter, now: now)
    }

    // MARK: - Ingresso

    /// Accoglie una misura appena arrivata.
    ///
    /// Prende valori primitivi e non oggetti HomeKit: così resta chiamabile da
    /// una sorgente che non sia il framework — un bridge, un import, un test —
    /// senza dover costruire finti `HMAccessory`.
    func ingest(type: SensorServiceType,
                roomUUID: UUID,
                roomName: String,
                accessoryUUID: UUID,
                accessoryName: String,
                value: Double,
                now: Date = Date()) {
        stage(type: type,
              roomUUID: roomUUID,
              roomName: roomName,
              accessoryUUID: accessoryUUID,
              accessoryName: accessoryName,
              value: value,
              now: now)
        scheduleFlush()
    }

    /// Variante per chi ha in mano gli oggetti HomeKit: il delegate delle
    /// notifiche e la risemina. Scarta in silenzio ciò che non è una misura
    /// ambientale, una stanza nota o un numero.
    func ingest(characteristic: HMCharacteristic, value: Any, accessory: HMAccessory) {
        guard let type = Self.sensorType(for: characteristic),
              let room = accessory.room,
              let numeric = Self.numericValue(from: value, type: type)
        else { return }
        ingest(type: type,
               roomUUID: room.uniqueIdentifier,
               roomName: room.name,
               accessoryUUID: accessory.uniqueIdentifier,
               accessoryName: accessory.name,
               value: numeric)
    }

    /// Ripopola lo stato dai valori che HomeKit tiene già in cache.
    ///
    /// Non fa I/O: `HMCharacteristic.value` è l'ultimo valore noto al
    /// framework, non una rilettura. Serve a dare uno stato pieno all'avvio,
    /// quando nessuna push è ancora arrivata, e a ri-confermare le letture
    /// sull'heartbeat, che una rilettura vera l'ha appena fatta.
    ///
    /// `isReachable` non è un dettaglio ma il cuore della correttezza: la cache
    /// di HomeKit resta popolata anche quando l'accessorio è offline, quindi
    /// riseminare senza filtro confermerebbe pure i sensori morti e la
    /// freschezza diventerebbe una finzione — nulla risulterebbe mai stantio.
    /// Filtrando sulla raggiungibilità, un sensore che smette di rispondere
    /// smette anche di essere confermato, invecchia, ed esce dalle medie.
    ///
    /// `at` invece sopravvive: se il valore non è cambiato resta quello
    /// originale, così «stabile da tre ore» e «visto tre minuti fa» restano
    /// due fatti distinti.
    func seed(from home: HMHome, isReachable: (HMAccessory) -> Bool) {
        let now = Date()
        for accessory in home.accessories {
            guard let room = accessory.room, isReachable(accessory) else { continue }
            for service in accessory.services {
                for characteristic in service.characteristics {
                    guard let type = Self.sensorType(for: characteristic),
                          let raw = characteristic.value,
                          let numeric = Self.numericValue(from: raw, type: type)
                    else { continue }
                    stage(type: type,
                          roomUUID: room.uniqueIdentifier,
                          roomName: room.name,
                          accessoryUUID: accessory.uniqueIdentifier,
                          accessoryName: accessory.name,
                          value: numeric,
                          now: now)
                }
            }
        }
        scheduleFlush()
    }

    /// Svuota tutto. Usato al cambio di casa attiva.
    func reset() {
        readings.removeAll()
        roomNames.removeAll()
        pending.removeAll()
        pendingRoomNames.removeAll()
        lastChange = Date()
    }

    // MARK: - Private

    private func stage(type: SensorServiceType,
                       roomUUID: UUID,
                       roomName: String,
                       accessoryUUID: UUID,
                       accessoryName: String,
                       value: Double,
                       now: Date) {
        let slot = Slot(roomUUID: roomUUID, type: type)

        // Il precedente può stare nel già applicato o nel pending di questo
        // tick: guardare solo `readings` perderebbe `at` quando due valori per
        // lo stesso sensore arrivano nello stesso giro.
        let previous = pending[slot]?[accessoryUUID] ?? readings[slot]?[accessoryUUID]

        let reading = Reading(
            value: value,
            at: (previous?.value == value) ? (previous?.at ?? now) : now,
            confirmedAt: now,
            accessoryUUID: accessoryUUID,
            accessoryName: accessoryName
        )

        pending[slot, default: [:]][accessoryUUID] = reading
        pendingRoomNames[roomUUID] = roomName
    }

    private func scheduleFlush() {
        guard coalescing else { flush(); return }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor [weak self] in
            // Lascia accumulare gli altri aggiornamenti dello stesso tick.
            await Task.yield()
            guard let self else { return }
            self.flush()
        }
    }

    private func flush() {
        defer {
            pending.removeAll()
            pendingRoomNames.removeAll()
            flushScheduled = false
        }
        guard !pending.isEmpty || !pendingRoomNames.isEmpty else { return }

        var next = readings
        for (slot, byAccessory) in pending {
            next[slot, default: [:]].merge(byAccessory) { _, new in new }
        }
        readings = next

        if !pendingRoomNames.isEmpty {
            var names = roomNames
            names.merge(pendingRoomNames) { _, new in new }
            roomNames = names
        }

        lastChange = Date()
    }

    // MARK: - Mappatura HomeKit

    /// Stessa regola usata da `SensorEventRouter`: un solo posto dove si
    /// decide che una caratteristica è una misura ambientale.
    static func sensorType(for characteristic: HMCharacteristic) -> SensorServiceType? {
        SensorServiceType.allCases.first {
            !$0.isWeatherKitSource && $0.hmCharacteristicType == characteristic.characteristicType
        }
    }

    /// Normalizzazione dei valori grezzi di HomeKit.
    ///
    /// Nessuna validazione di intervallo qui di proposito: `HomeState` riporta
    /// ciò che il sensore dice. Decidere che −40 °C è implausibile è lavoro di
    /// chi interpreta, non di chi registra.
    static func numericValue(from value: Any, type: SensorServiceType) -> Double? {
        if let d = value as? Double { return d }
        if let f = value as? Float  { return Double(f) }
        if let i = value as? Int    { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if type.isBooleanAlert, let b = value as? Bool { return b ? 1 : 0 }
        return nil
    }
}
