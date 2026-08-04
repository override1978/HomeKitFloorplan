import Foundation
import HomeKit
import SwiftData
import Observation

// MARK: - AccessoryCensusService

/// Tiene allineato il censimento con la casa viva.
///
/// Una passata costa quasi niente — i dati di identità sono già in memoria e i
/// numeri di serie arrivano dalla cache di `HomeSnapshotCapture` — quindi può
/// girare a ogni `isReady` senza pesare su nulla.
///
/// Quello che la passata **non** fa è altrettanto importante: non riabilita da
/// sola una riga ritirata quando ricompare un accessorio somigliante. La
/// corrispondenza la propone, e la conferma la dà l'utente: un rimappaggio
/// riscrive marker e storico, ed è invisibile se sbaglia.
@MainActor
@Observable
final class AccessoryCensusService {

    struct SweepResult: Sendable, Equatable {
        /// Righe create censendo una casa che esisteva già prima dell'app.
        var seeded = 0
        /// Accessori mai visti prima.
        var appeared = 0
        /// Righe ritirate: erano nel censimento, non sono più in HomeKit.
        var retired = 0
        /// Rinomine e cambi di stanza: si assorbono in silenzio, sono normali.
        var updated = 0
        /// Righe già note a cui **questo** device ha aggiunto il proprio UUID.
        var adopted = 0
    }

    private(set) var lastSweep: SweepResult?
    private(set) var lastSweepAt: Date?

    private let homeKit: HomeKitService
    private let context: ModelContext
    private let serialSource: HomeSnapshotCapture

    init(homeKit: HomeKitService,
         serialSource: HomeSnapshotCapture,
         modelContainer: ModelContainer) {
        self.homeKit = homeKit
        self.serialSource = serialSource
        self.context = ModelContext(modelContainer)
    }

    // MARK: - Passata

    /// - Parameter allowSeeding: se falso, una casa senza censimento viene
    ///   lasciata stare invece di essere censita da zero.
    ///
    ///   Serve al secondo device: finché il censimento sincronizzato non è
    ///   arrivato, la tabella locale è vuota e seminarla creerebbe un censimento
    ///   parallelo della stessa casa, con ogni accessorio marcato «nuovo». È lo
    ///   stesso errore dell'onboarding saltato al primo avvio sul secondo
    ///   device: chi arriva dopo deve **adottare**, non ricominciare.
    @discardableResult
    func sweep(allowSeeding: Bool = true) async -> SweepResult? {
        guard let home = homeKit.currentHome else { return nil }
        let homeName = home.name
        let now = Date()

        let existing = fetchRows(homeName: homeName)
        let isFirstCensus = existing.isEmpty
        guard !isFirstCensus || allowSeeding else { return nil }

        let serials = await serialSource.serialNumbers(of: home.accessories)

        var result = SweepResult()
        // Solo le righe vive entrano in gioco: una ritirata resta ritirata
        // finché l'utente non conferma che è tornata.
        var unmatched = existing.filter { !$0.isRetired }
        var seenIDs: Set<UUID> = []

        for accessory in home.accessories {
            let uuid = accessory.uniqueIdentifier
            let serial = serials[uuid]

            if let index = matchIndex(for: accessory, serial: serial, in: unmatched) {
                let row = unmatched.remove(at: index)
                if row.localUUID == nil { result.adopted += 1 }
                row.recordLocalUUID(uuid)
                if apply(accessory, serial: serial, to: row) { result.updated += 1 }
                row.lastSeenAt = now
                seenIDs.insert(row.id)
                continue
            }

            let row = KnownAccessory(
                homeName: homeName,
                name: accessory.name,
                serialNumber: serial,
                manufacturer: accessory.manufacturer,
                model: accessory.model,
                roomName: accessory.room?.name,
                category: accessory.category.categoryType,
                isBridged: accessory.isBridged,
                localUUID: uuid,
                isSeeded: isFirstCensus,
                now: now
            )
            context.insert(row)
            seenIDs.insert(row.id)
            if isFirstCensus { result.seeded += 1 } else { result.appeared += 1 }
        }

        for row in unmatched where !seenIDs.contains(row.id) {
            row.retiredAt = now
            result.retired += 1
        }

        try? context.save()
        lastSweep = result
        lastSweepAt = now
        return result
    }

    // MARK: - Corrispondenza con le righe vive

    /// La scala, dalla più forte alla più debole. Ognuna deve essere **unica**
    /// fra le candidate: se due righe rispondono allo stesso criterio, quel
    /// criterio non identifica niente e si scende al successivo.
    private func matchIndex(for accessory: HMAccessory,
                            serial: String?,
                            in rows: [KnownAccessory]) -> Int? {
        let uuid = accessory.uniqueIdentifier

        // 1. Lo conosciamo già su questo device. Gli UUID di HomeKit sono
        //    stabili nel tempo sullo stesso device: qui non c'è euristica.
        if let index = rows.firstIndex(where: { $0.localUUID == uuid }) {
            return index
        }

        // 2. Numero di serie: identità hardware.
        if let serial, !serial.isEmpty {
            let candidates = rows.indices.filter { rows[$0].serialNumber == serial }
            if candidates.count == 1 { return candidates[0] }
        }

        // 3. Nome + stanza. Su un altro device non è un'euristica: nome e stanza
        //    sono dati della casa, non del device, e i due device leggono la
        //    stessa riga. Nel tempo invece è un'ipotesi, e infatti vale solo per
        //    righe che non hanno ancora un UUID qui.
        let name = accessory.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let room = accessory.room?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = rows.indices.filter {
            rows[$0].localUUID == nil
                && rows[$0].normalizedName == name
                && rows[$0].roomName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == room
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Riallinea i campi osservabili. Rinomine e spostamenti sono normali e non
    /// generano niente da chiedere: si assorbono.
    private func apply(_ accessory: HMAccessory, serial: String?, to row: KnownAccessory) -> Bool {
        var changed = false
        if row.name != accessory.name { row.name = accessory.name; changed = true }
        if row.roomName != accessory.room?.name { row.roomName = accessory.room?.name; changed = true }
        if row.manufacturer != accessory.manufacturer { row.manufacturer = accessory.manufacturer; changed = true }
        if row.model != accessory.model { row.model = accessory.model; changed = true }
        if row.isBridged != accessory.isBridged { row.isBridged = accessory.isBridged; changed = true }
        // Il seriale si scrive solo se prima mancava: un accessorio non cambia
        // numero di serie, quindi un valore diverso è una lettura sbagliata, non
        // un aggiornamento.
        if (row.serialNumber ?? "").isEmpty, let serial, !serial.isEmpty {
            row.serialNumber = serial
            changed = true
        }
        return changed
    }

    // MARK: - Lettura

    func rows(homeName: String) -> [KnownAccessory] { fetchRows(homeName: homeName) }

    /// Le righe della casa attiva. Si rilegge quando `lastSweep` cambia, che è
    /// l'unico momento in cui possono essere cambiate.
    var currentRows: [KnownAccessory] {
        guard let home = homeKit.currentHome else { return [] }
        return fetchRows(homeName: home.name)
    }

    private func fetchRows(homeName: String) -> [KnownAccessory] {
        let descriptor = FetchDescriptor<KnownAccessory>(
            predicate: #Predicate { $0.homeName == homeName }
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
