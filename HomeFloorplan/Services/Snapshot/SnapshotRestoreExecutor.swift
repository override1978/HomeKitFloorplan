import Foundation
import HomeKit

// MARK: - SnapshotRestoreExecutor

/// L'unico file che **riscrive HomeKit** partendo da uno snapshot.
///
/// Lavora al livello della caratteristica, non dei draft dell'editor scene.
/// Non è una scorciatoia: i draft modellano solo ciò che l'editor sa mostrare,
/// mentre lo snapshot ha catturato quello che c'era. Passare dai draft
/// perderebbe in silenzio tutto ciò che non hanno previsto, ed è esattamente il
/// tipo di perdita che un ripristino non può permettersi.
///
/// ⚠️ **Non cancella mai niente.** Di una scena esistente rimuove solo le azioni
/// sulle **stesse caratteristiche** che sta per riscrivere: quello che hai
/// aggiunto dopo da app Casa sopravvive al ripristino. È la stessa regola che
/// `HomeKitScenesService` applica con `managedCharacteristicIDs`, qui ristretta
/// a ciò che lo snapshot conteneva davvero.
@MainActor
final class SnapshotRestoreExecutor {

    struct Outcome: Sendable {
        var restored: [String] = []
        /// Cosa non è stato fatto, e perché. Un ripristino che tace su ciò che
        /// non è riuscito è peggio di uno che fallisce.
        var skipped: [(title: String, reason: String)] = []

        var isEmpty: Bool { restored.isEmpty && skipped.isEmpty }
    }

    private let homeKit: HomeKitService
    private let scenesService: HomeKitScenesService
    private let automationsService: HomeKitAutomationsService

    init(homeKit: HomeKitService,
         scenesService: HomeKitScenesService,
         automationsService: HomeKitAutomationsService) {
        self.homeKit = homeKit
        self.scenesService = scenesService
        self.automationsService = automationsService
    }

    // MARK: - Esecuzione

    /// Ripristina le voci selezionate, **a fasi**.
    ///
    /// HomeKit non propaga subito le modifiche, quindi ogni fase rilegge lo
    /// stato prima della successiva: le stanze devono esistere prima che una
    /// zona possa contenerle, e gli accessori devono essere nelle loro stanze
    /// prima che abbia senso guardare le scene.
    func restore(_ items: [HomeSnapshotDiff.Item],
                 from snapshot: HomeConfigurationSnapshot) async -> Outcome {
        guard let home = homeKit.currentHome else {
            return Outcome(skipped: [(String(localized: "restore.skip.noHome", defaultValue: "Restore"),
                                      String(localized: "restore.skip.noHome.reason",
                                             defaultValue: "No HomeKit home available."))])
        }
        var outcome = Outcome()
        let selected = Set(items.map(\.id))

        for room in snapshot.rooms where selected.contains("room.missing.\(room.address.name)") {
            await restoreRoom(room, in: home, into: &outcome)
        }
        for zone in snapshot.zones where selected.contains("zone.missing.\(zone.name)")
            || selected.contains("zone.changed.\(zone.name)") {
            await restoreZone(zone, in: home, into: &outcome)
        }
        for scene in snapshot.scenes where selected.contains("scene.missing.\(scene.name)")
            || selected.contains("scene.changed.\(scene.name)") {
            await restoreScene(scene, in: home, into: &outcome)
        }

        // Le automazioni per ultime: la scena che eseguono deve esistere, e
        // potrebbe essere stata appena ricreata qui sopra.
        scenesService.refresh()
        for automation in snapshot.automations
        where selected.contains("auto.missing.\(automation.name)") {
            await restoreAutomation(automation, in: home, into: &outcome)
        }

        return outcome
    }

    // MARK: - Automazioni

    private func restoreAutomation(_ automation: AutomationSnapshot,
                                   in home: HMHome,
                                   into outcome: inout Outcome) async {
        guard let plan = automation.restorable else {
            outcome.skipped.append((automation.name,
                                    String(localized: "restorableAutomation.fail.unsupported",
                                           defaultValue: "this trigger cannot be recreated")))
            return
        }
        do {
            try await AutomationRestoreBridge.recreate(plan, in: home,
                                                       scenes: scenesService.scenes,
                                                       automationsService: automationsService)
            outcome.restored.append(String(format: String(localized: "restore.done.automation",
                                                          defaultValue: "Automation “%@”"),
                                           automation.name))
        } catch {
            outcome.skipped.append((automation.name, error.localizedDescription))
        }
    }

    // MARK: - Stanze

    private func restoreRoom(_ room: RoomSnapshot, in home: HMHome, into outcome: inout Outcome) async {
        do {
            let target: HMRoom
            if let existing = home.rooms.first(where: { $0.name == room.address.name }) {
                target = existing
            } else {
                target = try await home.addRoom(named: room.address.name)
            }
            // Gli accessori tornano dove erano. Solo quelli che lo snapshot
            // dichiarava in questa stanza, e solo se sono ancora in casa.
            var moved = 0
            for name in room.accessoryNames {
                guard let accessory = home.accessories.first(where: { $0.name == name }),
                      accessory.room?.uniqueIdentifier != target.uniqueIdentifier
                else { continue }
                try await home.assignAccessory(accessory, to: target)
                moved += 1
            }
            outcome.restored.append(moved > 0
                ? String(format: String(localized: "restore.done.roomWithAccessories",
                                        defaultValue: "Room “%1$@” · %2$d accessories moved back"),
                         room.address.name, moved)
                : String(format: String(localized: "restore.done.room", defaultValue: "Room “%@”"),
                         room.address.name))
        } catch {
            outcome.skipped.append((room.address.name, error.localizedDescription))
        }
    }

    // MARK: - Zone

    private func restoreZone(_ zone: ZoneSnapshot, in home: HMHome, into outcome: inout Outcome) async {
        do {
            let target: HMZone
            if let existing = home.zones.first(where: { $0.name == zone.name }) {
                target = existing
            } else {
                target = try await home.addZone(named: zone.name)
            }
            var added = 0
            for roomName in zone.roomNames {
                guard let room = home.rooms.first(where: { $0.name == roomName }),
                      !target.rooms.contains(where: { $0.uniqueIdentifier == room.uniqueIdentifier })
                else { continue }
                try await target.addRoom(room)
                added += 1
            }
            outcome.restored.append(String(format: String(localized: "restore.done.zone",
                                                          defaultValue: "Zone “%1$@” · %2$d rooms"),
                                           zone.name, added))
        } catch {
            outcome.skipped.append((zone.name, error.localizedDescription))
        }
    }

    // MARK: - Scene

    private func restoreScene(_ scene: SceneSnapshot, in home: HMHome, into outcome: inout Outcome) async {
        guard !scene.isBuiltIn else {
            outcome.skipped.append((scene.name, String(localized: "restore.skip.builtIn",
                                                       defaultValue: "Built-in scenes cannot be changed.")))
            return
        }

        // Una scena di cui lo snapshot non ha letto nessuna azione non è
        // «irrisolvibile»: è **vuota per noi**, e dirlo così è l'unica risposta
        // onesta. Le azioni erano di un tipo che l'app non sa leggere.
        guard !scene.actions.isEmpty else {
            outcome.skipped.append((scene.name,
                String(format: String(localized: "restore.skip.noStoredActions",
                                      defaultValue: "This snapshot holds no readable action for it: its %d actions were of a kind this app cannot read."),
                       scene.foreignActionCount)))
            return
        }

        // Prima si risolve tutto, poi si scrive. Se metà delle azioni non trova
        // il suo accessorio è meglio saperlo prima di aver già toccato la scena.
        var resolved: [(characteristic: HMCharacteristic, value: Any)] = []
        var failures: [String] = []

        for action in scene.actions {
            switch resolveTarget(action, in: home) {
            case .resolved(let characteristic, let value):
                resolved.append((characteristic, value))
            case .failed(let reason):
                failures.append(reason)
            }
        }

        guard !resolved.isEmpty else {
            // Il motivo, non un verdetto: «non trovo la presa Studio» si può
            // verificare, «nessuno dei suoi accessori esiste» no.
            outcome.skipped.append((scene.name, failures.joined(separator: " · ")))
            return
        }

        do {
            let actionSet: HMActionSet
            if let existing = home.actionSets.first(where: { $0.name == scene.name }) {
                actionSet = existing
                // Solo le caratteristiche che stiamo per riscrivere: tutto il
                // resto della scena resta dov'è.
                let ours = Set(resolved.map { $0.characteristic.uniqueIdentifier })
                for action in Array(actionSet.actions) {
                    guard let write = action.homeFloorplanCharacteristicWrite,
                          ours.contains(write.characteristic.uniqueIdentifier) else { continue }
                    try await actionSet.removeAction(action)
                }
            } else {
                actionSet = try await home.addActionSet(named: scene.name)
            }

            for entry in resolved {
                guard let target = entry.value as? NSCopying else { continue }
                let action = HMCharacteristicWriteAction(characteristic: entry.characteristic,
                                                        targetValue: target)
                try await actionSet.addAction(action)
            }

            outcome.restored.append(String(format: String(localized: "restore.done.scene",
                                                          defaultValue: "Scene “%1$@” · %2$d actions"),
                                           scene.name, resolved.count))
            // Un successo parziale va detto come tale, con le voci mancate per
            // nome: altrimenti sembra riuscito tutto.
            if !failures.isEmpty {
                outcome.skipped.append((scene.name, failures.joined(separator: " · ")))
            }
        } catch {
            outcome.skipped.append((scene.name, error.localizedDescription))
        }
    }

    // MARK: - Risoluzione

    /// Risolve una singola azione, **dicendo dove si è fermata**.
    ///
    /// I quattro passi possono fallire per ragioni diverse e con rimedi diversi:
    /// un accessorio non trovato è un problema di identità, un servizio non
    /// trovato è un accessorio cambiato sotto, un valore non scrivibile è un
    /// tipo che HomeKit non accetta. Un unico messaggio per tutti e quattro non
    /// permette di capire quale.
    private enum TargetResolution {
        case resolved(characteristic: HMCharacteristic, value: Any)
        case failed(String)
    }

    private func resolveTarget(_ action: SceneActionSnapshot, in home: HMHome) -> TargetResolution {
        let target = action.target
        guard let accessory = resolveAccessory(target.accessory, in: home) else {
            return .failed(String(format: String(localized: "restore.fail.accessory",
                                                  defaultValue: "“%@” not found in this home"),
                                   target.accessory.name))
        }
        let sameType = accessory.services.filter { $0.serviceType == target.service.serviceType }
        guard target.service.ordinal < sameType.count else {
            return .failed(String(format: String(localized: "restore.fail.service",
                                                  defaultValue: "“%@” no longer exposes that service"),
                                   accessory.name))
        }
        guard let characteristic = sameType[target.service.ordinal].characteristics.first(where: {
            $0.characteristicType == target.characteristicType
        }) else {
            return .failed(String(format: String(localized: "restore.fail.characteristic",
                                                  defaultValue: "“%1$@” no longer has %2$@"),
                                   accessory.name,
                                   SnapshotCharacteristicNames.readable(target.characteristicType)))
        }
        guard let value = Self.targetValue(action.value, for: characteristic) else {
            return .failed(String(format: String(localized: "restore.fail.value",
                                                  defaultValue: "“%1$@”: HomeKit does not accept the stored value for %2$@"),
                                   accessory.name,
                                   SnapshotCharacteristicNames.readable(target.characteristicType)))
        }
        return .resolved(characteristic: characteristic, value: value)
    }

    /// Dall'indirizzo salvato alla caratteristica viva.
    ///
    /// Ogni criterio deve essere **univoco** fra i candidati: se due accessori
    /// rispondono allo stesso, quel criterio non identifica niente e si scende.
    /// Meglio non scrivere che scrivere sull'accessorio sbagliato — un valore
    /// finito nel posto errato è silenzioso.
    private func resolve(_ address: CharacteristicAddress, in home: HMHome) -> HMCharacteristic? {
        guard let accessory = resolveAccessory(address.accessory, in: home) else { return nil }

        let sameType = accessory.services
            .filter { $0.serviceType == address.service.serviceType }
        guard address.service.ordinal < sameType.count else { return nil }
        let service = sameType[address.service.ordinal]

        return service.characteristics.first {
            $0.characteristicType == address.characteristicType
        }
    }

    private func resolveAccessory(_ address: AccessoryAddress, in home: HMHome) -> HMAccessory? {
        // Sullo stesso device gli identificatori di HomeKit sono stabili nel
        // tempo: quando c'è, non c'è niente da indovinare.
        if let raw = address.localUUID, let uuid = UUID(uuidString: raw),
           let match = home.accessories.first(where: { $0.uniqueIdentifier == uuid }) {
            return match
        }
        let byName = home.accessories.filter { $0.name == address.name }
        if byName.count == 1 { return byName[0] }

        let byModel = home.accessories.filter {
            $0.manufacturer == address.manufacturer
                && $0.model == address.model
                && $0.room?.name == address.roomName
        }
        return byModel.count == 1 ? byModel[0] : nil
    }

    // MARK: - Valori

    /// Riporta un valore salvato nel tipo che **questa** caratteristica accetta.
    ///
    /// Il formato si legge dal vivo, non dallo snapshot: è HomeKit a validare la
    /// scrittura, e scrivere un `Double` dove aspetta un `UInt8` fallisce. Il
    /// valore viene anche riportato nell'intervallo dichiarato, perché un fuori
    /// scala viene rifiutato in blocco.
    private static func targetValue(_ value: SnapshotValue, for characteristic: HMCharacteristic) -> Any? {
        let format = characteristic.metadata?.format

        switch value {
        case .bool(let flag):
            if format == HMCharacteristicMetadataFormatBool { return NSNumber(value: flag) }
            return NSNumber(value: flag ? 1 : 0)

        case .int(let number):
            return clamped(Double(number), characteristic, integer: true)

        case .double(let number):
            return clamped(number, characteristic, integer: isIntegerFormat(format))

        case .string(let text):
            return format == HMCharacteristicMetadataFormatString ? text as NSString : nil

        case .unsupported:
            return nil
        }
    }

    private static func isIntegerFormat(_ format: String?) -> Bool {
        switch format {
        case HMCharacteristicMetadataFormatInt, HMCharacteristicMetadataFormatUInt8,
             HMCharacteristicMetadataFormatUInt16, HMCharacteristicMetadataFormatUInt32,
             HMCharacteristicMetadataFormatUInt64:
            return true
        default:
            return false
        }
    }

    private static func clamped(_ value: Double,
                                _ characteristic: HMCharacteristic,
                                integer: Bool) -> NSNumber {
        var result = value
        if let minimum = characteristic.metadata?.minimumValue?.doubleValue {
            result = max(result, minimum)
        }
        if let maximum = characteristic.metadata?.maximumValue?.doubleValue {
            result = min(result, maximum)
        }
        return integer ? NSNumber(value: Int(result.rounded())) : NSNumber(value: result)
    }
}

// MARK: - Ponti async sulle callback di HomeKit

private extension HMHome {
    func addRoom(named name: String) async throws -> HMRoom {
        try await withCheckedThrowingContinuation { continuation in
            addRoom(withName: name) { room, error in
                if let error { continuation.resume(throwing: error) }
                else if let room { continuation.resume(returning: room) }
                else { continuation.resume(throwing: SnapshotRestoreError.noResult) }
            }
        }
    }

    func addZone(named name: String) async throws -> HMZone {
        try await withCheckedThrowingContinuation { continuation in
            addZone(withName: name) { zone, error in
                if let error { continuation.resume(throwing: error) }
                else if let zone { continuation.resume(returning: zone) }
                else { continuation.resume(throwing: SnapshotRestoreError.noResult) }
            }
        }
    }

    func addActionSet(named name: String) async throws -> HMActionSet {
        try await withCheckedThrowingContinuation { continuation in
            addActionSet(withName: name) { actionSet, error in
                if let error { continuation.resume(throwing: error) }
                else if let actionSet { continuation.resume(returning: actionSet) }
                else { continuation.resume(throwing: SnapshotRestoreError.noResult) }
            }
        }
    }

    func assignAccessory(_ accessory: HMAccessory, to room: HMRoom) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            assignAccessory(accessory, to: room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

private extension HMZone {
    func addRoom(_ room: HMRoom) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            addRoom(room) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

private extension HMActionSet {
    func addAction(_ action: HMAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            addAction(action) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func removeAction(_ action: HMAction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            removeAction(action) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

enum SnapshotRestoreError: LocalizedError {
    case noResult

    var errorDescription: String? {
        String(localized: "restore.error.noResult", defaultValue: "HomeKit accepted the request but returned nothing.")
    }
}
