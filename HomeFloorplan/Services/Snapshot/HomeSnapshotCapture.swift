import Foundation
import HomeKit
import UIKit

// MARK: - HomeSnapshotCapture

/// Costruisce una fotografia della **configurazione** HomeKit.
///
/// ⚠️ **Configurazione, non stato.** Non entrano valori correnti delle
/// caratteristiche, batterie, raggiungibilità né `lastExecutionDate`: cambiano
/// di continuo, farebbero risultare unico ogni scatto — distruggendo la
/// deduplica per contenuto — e affogherebbero il confronto fra due snapshot in
/// differenze irrilevanti. Lo stato si guarda dal vivo, dove è già mostrato.
///
/// ⚠️ **Il costo sta tutto nei numeri di serie.** Identità, servizi, scene e
/// automazioni sono già in memoria: leggerli costa millisecondi. Il seriale no,
/// non è una proprietà: va letto dalla caratteristica HAP `00000030`, quindi
/// una `readValue` per accessorio — su 128 dispositivi sono pochi secondi.
/// È il prezzo dell'unica identità che sopravvive a un ri-accoppiamento, e si
/// paga solo su un'azione manuale.
///
/// Ciò che **non** va fatto mai è leggere i valori di tutte le caratteristiche:
/// sarebbero ~12.000 andate e ritorno, minuti di lavoro e accessori su radio
/// lente che vanno in timeout.
@MainActor
@Observable
final class HomeSnapshotCapture {

    private static let serialNumberCharacteristicType = "00000030-0000-1000-8000-0026BB765291"

    private(set) var isCapturing = false
    private(set) var progress: Double = 0

    /// Da dove sono arrivati i numeri di serie nell'ultima cattura. Serve a
    /// distinguere «la cache non funziona» da «ci sono accessori che non
    /// rispondono e ogni volta si aspetta il loro timeout» — due cause dello
    /// stesso sintomo, con rimedi opposti.
    struct SerialStats: Sendable {
        var fromCache = 0
        var fromLiveValue = 0
        var read = 0
        var readFailed = 0
        var structurallyAbsent = 0
        var skippedKnownAbsent = 0
    }
    private(set) var lastSerialStats = SerialStats()

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

    func capture() async throws -> HomeConfigurationSnapshot {
        guard let home = homeKit.currentHome else {
            throw NSError(domain: "HomeSnapshotCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "HomeKit home not available"])
        }
        guard !isCapturing else {
            throw NSError(domain: "HomeSnapshotCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "A capture is already running"])
        }
        isCapturing = true
        progress = 0
        defer { isCapturing = false }

        let serials = await serialNumbers(of: home.accessories)

        return HomeConfigurationSnapshot(
            formatVersion: HomeConfigurationSnapshot.currentFormatVersion,
            id: UUID(),
            capturedAt: Date(),
            capturedOnDevice: UIDevice.current.name,
            appVersion: Bundle.main.appVersionString,
            homeName: home.name,
            homeUUID: home.uniqueIdentifier.uuidString,
            rooms: home.rooms.map(roomSnapshot),
            zones: home.zones.map(zoneSnapshot),
            serviceGroups: home.serviceGroups.map { serviceGroupSnapshot($0, serials: serials) },
            accessories: {
                let bridges = bridgeMap(of: home.accessories)
                return home.accessories.map {
                    accessorySnapshot($0, serial: serials[$0.uniqueIdentifier],
                                      bridges: bridges, serials: serials)
                }
            }(),
            scenes: home.actionSets.map { sceneSnapshot($0, serials: serials) },
            automations: {
                // Il catalogo si costruisce una volta sola: serve a decodificare
                // i trigger, e ricalcolarlo per automazione costerebbe 78 giri
                // sull'intera casa.
                let capabilities = AutomationCapabilityCatalog.capabilities(in: home)
                return home.triggers.map {
                    automationSnapshot($0, serials: serials, capabilities: capabilities)
                }
            }()
        )
    }

    // MARK: - Numeri di serie

    /// Cache persistente dei seriali, per UUID locale dell'accessorio.
    ///
    /// Un numero di serie è inciso nell'hardware: **non cambia mai**. Senza
    /// questa cache ogni cattura ripagava 128 letture di rete — misurato su
    /// una casa vera: **25,3 secondi**, che per un'azione da ripetere è troppo.
    /// Con la cache, dalla seconda cattura in poi il costo è zero.
    ///
    /// Se un accessorio viene ri-accoppiato cambia UUID e quindi non trova la
    /// voce: rileggerlo è esattamente ciò che serve.
    private static let serialCacheKey = "snapshot.serialNumbers.v1"
    private static let serialFailuresKey = "snapshot.serialFailures.v1"

    /// Dopo quanti tentativi a vuoto si smette di chiedere. Due bastano a
    /// distinguere un accessorio che non ha il seriale da uno che quella volta
    /// non ha risposto — e senza un tetto si aspetta il loro timeout **a ogni**
    /// cattura, per sempre.
    private static let maxSerialReadAttempts = 2

    private var serialCache: [String: String] {
        get { Self.decodeDefaults(Self.serialCacheKey) }
        set { Self.encodeDefaults(newValue, Self.serialCacheKey) }
    }

    /// Quante volte di fila un accessorio non ha risposto. Una lettura riuscita
    /// azzera il contatore.
    private var serialFailures: [String: Int] {
        get { Self.decodeDefaults(Self.serialFailuresKey) }
        set { Self.encodeDefaults(newValue, Self.serialFailuresKey) }
    }

    private static func decodeDefaults<T: Decodable>(_ key: String) -> [String: T] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: T].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func encodeDefaults<T: Encodable>(_ value: [String: T], _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Svuota cache e contatori: rimette in gioco anche gli accessori dati per
    /// senza seriale. Da offrire come «riprova tutto», non da fare da sé.
    func forgetSerialNumbers() {
        UserDefaults.standard.removeObject(forKey: Self.serialCacheKey)
        UserDefaults.standard.removeObject(forKey: Self.serialFailuresKey)
    }

    /// I numeri di serie, dalla cache dove c'è e letti dove manca.
    ///
    /// Non è privato perché serve anche al censimento: se ognuno tenesse la
    /// propria cache si pagherebbero due volte le stesse letture, e la seconda
    /// tornerebbe a costare i 25 secondi misurati.
    func serialNumbers(of accessories: [HMAccessory]) async -> [UUID: String] {
        var cache = serialCache
        var failures = serialFailures
        var stats = SerialStats()
        var result: [UUID: String] = [:]

        // Chi non espone affatto la caratteristica non costa niente: è una
        // proprietà della struttura, non una lettura.
        var pending: [(uuid: UUID, characteristic: HMCharacteristic)] = []
        for accessory in accessories {
            let uuid = accessory.uniqueIdentifier
            if let cached = cache[uuid.uuidString] {
                result[uuid] = cached
                stats.fromCache += 1
                continue
            }
            guard let info = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }),
                  let characteristic = info.characteristics.first(where: {
                      $0.characteristicType == Self.serialNumberCharacteristicType
                  })
            else {
                stats.structurallyAbsent += 1
                continue
            }

            if let live = characteristic.value.map({ "\($0)" }),
               !live.trimmingCharacters(in: .whitespaces).isEmpty {
                result[uuid] = live
                cache[uuid.uuidString] = live
                failures[uuid.uuidString] = nil
                stats.fromLiveValue += 1
                continue
            }
            guard (failures[uuid.uuidString] ?? 0) < Self.maxSerialReadAttempts else {
                stats.skippedKnownAbsent += 1
                continue
            }
            pending.append((uuid, characteristic))
        }

        if pending.isEmpty {
            progress = 1
            serialCache = cache
            serialFailures = failures
            lastSerialStats = stats
            return result
        }

        // A gruppi, non tutte insieme e non una alla volta. Tutte insieme
        // significa inondare radio lente — Thread, Zigbee dietro bridge — e
        // raccogliere timeout invece di risposte; una alla volta sono i 25
        // secondi misurati. Otto è un compromesso che regge su un impianto reale.
        let batchSize = 8
        var completed = 0
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            let read = await withTaskGroup(of: (UUID, String?).self) { group in
                for entry in batch {
                    group.addTask { @MainActor in
                        (entry.uuid, await Self.readValue(of: entry.characteristic))
                    }
                }
                var collected: [(UUID, String?)] = []
                for await outcome in group { collected.append(outcome) }
                return collected
            }
            for (uuid, serial) in read {
                guard let serial else {
                    failures[uuid.uuidString] = (failures[uuid.uuidString] ?? 0) + 1
                    stats.readFailed += 1
                    continue
                }
                result[uuid] = serial
                cache[uuid.uuidString] = serial
                failures[uuid.uuidString] = nil
                stats.read += 1
            }
            completed += batch.count
            progress = Double(completed) / Double(pending.count)
        }

        serialCache = cache
        serialFailures = failures
        lastSerialStats = stats
        return result
    }

    /// Quanto si aspetta una risposta prima di passare oltre.
    ///
    /// Misurato: **25 accessori su 128 non rispondono mai** — tipicamente quelli
    /// dietro un bridge — e aspettare il timeout di HomeKit per ognuno costava
    /// 21 secondi. Un dispositivo che a una richiesta banale non risponde entro
    /// due secondi non risponderà: meglio rinunciare e riprovare alla prossima
    /// cattura, tanto la lettura parte comunque e se arriva tardi il valore
    /// resta nella cache di HomeKit, pronto per il giro dopo.
    private static let readTimeout: TimeInterval = 2

    /// Chi dei due arriva primo — la risposta o lo scadere del tempo — decide.
    /// La scatola serve perché entrambe le chiusure devono poter dire «ho già
    /// concluso io»: riprendere due volte una `CheckedContinuation` fa crashare.
    private final class ResumeGuard {
        private var hasResumed = false
        func claim() -> Bool {
            guard !hasResumed else { return false }
            hasResumed = true
            return true
        }
    }

    /// Una lettura fallita **non** viene messa in cache come «non ce l'ha»:
    /// sull'iPhone tre accessori che il seriale ce l'hanno non avevano risposto,
    /// e trasformare quel silenzio in un verdetto lo renderebbe definitivo. A
    /// contarli ci pensa il tetto ai tentativi.
    @MainActor
    private static func readValue(of characteristic: HMCharacteristic) async -> String? {
        let didRead: Bool = await withCheckedContinuation { continuation in
            let guardBox = ResumeGuard()

            characteristic.readValue { error in
                Task { @MainActor in
                    guard guardBox.claim() else { return }
                    continuation.resume(returning: error == nil)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(readTimeout))
                guard guardBox.claim() else { return }
                continuation.resume(returning: false)
            }
        }
        guard didRead, let raw = characteristic.value else { return nil }
        let value = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Costruzione degli elementi

    private func roomSnapshot(_ room: HMRoom) -> RoomSnapshot {
        RoomSnapshot(
            address: RoomAddress(name: room.name, localUUID: room.uniqueIdentifier.uuidString),
            accessoryNames: room.accessories.map(\.name).sorted()
        )
    }

    private func zoneSnapshot(_ zone: HMZone) -> ZoneSnapshot {
        ZoneSnapshot(name: zone.name,
                     roomNames: zone.rooms.map(\.name).sorted(),
                     localUUID: zone.uniqueIdentifier.uuidString)
    }

    private func serviceGroupSnapshot(_ group: HMServiceGroup,
                                      serials: [UUID: String]) -> ServiceGroupSnapshot {
        let members = group.services.compactMap { service -> ServiceGroupMemberSnapshot? in
            guard let accessory = service.accessory else { return nil }
            var ordinal = 0
            for candidate in accessory.services where candidate.serviceType == service.serviceType {
                if candidate.uniqueIdentifier == service.uniqueIdentifier { break }
                ordinal += 1
            }
            return ServiceGroupMemberSnapshot(
                accessoryName: accessory.name,
                accessorySerialNumber: serials[accessory.uniqueIdentifier],
                serviceType: service.serviceType,
                ordinal: ordinal,
                serviceName: service.name
            )
        }
        return ServiceGroupSnapshot(name: group.name,
                                    serviceCount: group.services.count,
                                    localUUID: group.uniqueIdentifier.uuidString,
                                    members: members)
    }

    private func address(of accessory: HMAccessory, serial: String?) -> AccessoryAddress {
        AccessoryAddress(
            serialNumber: serial,
            manufacturer: accessory.manufacturer,
            model: accessory.model,
            name: accessory.name,
            roomName: accessory.room?.name,
            category: accessory.category.categoryType,
            isBridged: accessory.isBridged,
            localUUID: accessory.uniqueIdentifier.uuidString
        )
    }

    private func accessorySnapshot(_ accessory: HMAccessory,
                                   serial: String?,
                                   bridges: [UUID: HMAccessory],
                                   serials: [UUID: String]) -> AccessorySnapshot {
        let bridge = bridges[accessory.uniqueIdentifier]
        return AccessorySnapshot(
            address: address(of: accessory, serial: serial),
            bridgeName: bridge?.name,
            bridgeSerialNumber: bridge.flatMap { serials[$0.uniqueIdentifier] },
            firmwareVersion: accessory.firmwareVersion,
            services: serviceSnapshots(of: accessory)
        )
    }

    /// `figlio → bridge`. Il legame si legge solo dal lato del bridge, che
    /// elenca i suoi, quindi va rovesciato una volta sola.
    private func bridgeMap(of accessories: [HMAccessory]) -> [UUID: HMAccessory] {
        var map: [UUID: HMAccessory] = [:]
        for bridge in accessories {
            for child in bridge.uniqueIdentifiersForBridgedAccessories ?? [] {
                map[child] = bridge
            }
        }
        return map
    }

    /// L'ordinale si calcola sull'ordine in cui HomeKit espone i servizi, che è
    /// lo stesso criterio già usato da `MultiOutletAdapter` per distinguere le
    /// prese di una multipresa.
    private func serviceSnapshots(of accessory: HMAccessory) -> [ServiceSnapshot] {
        var seenByType: [String: Int] = [:]
        return accessory.services.map { service in
            let ordinal = seenByType[service.serviceType, default: 0]
            seenByType[service.serviceType] = ordinal + 1
            return ServiceSnapshot(
                address: ServiceAddress(
                    serviceType: service.serviceType,
                    ordinal: ordinal,
                    name: service.name,
                    isPrimary: service.isPrimaryService,
                    localUUID: service.uniqueIdentifier.uuidString
                ),
                characteristics: service.characteristics.map { characteristic in
                    CharacteristicSnapshot(
                        characteristicType: characteristic.characteristicType,
                        properties: characteristic.properties,
                        format: formatHint(characteristic.metadata)
                    )
                },
                associatedServiceType: service.associatedServiceType,
                isUserInteractive: service.isUserInteractive
            )
        }
    }

    private func formatHint(_ metadata: HMCharacteristicMetadata?) -> CharacteristicFormatHint? {
        guard let metadata else { return nil }
        return CharacteristicFormatHint(
            format: metadata.format,
            units: metadata.units,
            minimumValue: metadata.minimumValue?.doubleValue,
            maximumValue: metadata.maximumValue?.doubleValue,
            stepValue: metadata.stepValue?.doubleValue
        )
    }

    // MARK: - Scene

    private func sceneSnapshot(_ actionSet: HMActionSet, serials: [UUID: String]) -> SceneSnapshot {
        let item = SceneItem(actionSet: actionSet)
        let writes = actionSet.actions.compactMap { action -> SceneActionSnapshot? in
            guard let write = action.homeFloorplanCharacteristicWrite else { return nil }
            return actionSnapshot(characteristic: write.characteristic,
                                  value: write.targetValue,
                                  serials: serials)
        }
        return SceneSnapshot(
            name: item.name,
            actionSetType: actionSet.actionSetType,
            isBuiltIn: item.isBuiltIn,
            isTriggerOwned: HomeKitAutomationsService.isTriggerOwned(actionSet),
            localUUID: actionSet.uniqueIdentifier.uuidString,
            actions: writes,
            foreignActionCount: actionSet.actions.count - writes.count
        )
    }

    private func actionSnapshot(characteristic: HMCharacteristic,
                                value: Any?,
                                serials: [UUID: String]) -> SceneActionSnapshot? {
        guard let service = characteristic.service,
              let accessory = service.accessory else { return nil }

        var ordinal = 0
        for candidate in accessory.services where candidate.serviceType == service.serviceType {
            if candidate.uniqueIdentifier == service.uniqueIdentifier { break }
            ordinal += 1
        }

        return SceneActionSnapshot(
            target: CharacteristicAddress(
                accessory: address(of: accessory, serial: serials[accessory.uniqueIdentifier]),
                service: ServiceAddress(
                    serviceType: service.serviceType,
                    ordinal: ordinal,
                    name: service.name,
                    isPrimary: service.isPrimaryService,
                    localUUID: service.uniqueIdentifier.uuidString
                ),
                characteristicType: characteristic.characteristicType,
                characteristicName: characteristic.localizedDescription
            ),
            value: SnapshotValue(value),
            format: formatHint(characteristic.metadata)
        )
    }

    // MARK: - Automazioni

    private func automationSnapshot(_ trigger: HMTrigger,
                                    serials: [UUID: String],
                                    capabilities: [AutomationCharacteristicCapability]) -> AutomationSnapshot {
        let item = AutomationItem(trigger: trigger)
        let sets = trigger.actionSets
        let inlineSets = sets.filter(HomeKitAutomationsService.isTriggerOwned)
        let everyAction = sets.flatMap { Array($0.actions) }
        let readable = everyAction.filter { $0.homeFloorplanCharacteristicWrite != nil }

        let content: AutomationSnapshot.Content
        if everyAction.isEmpty {
            content = .empty
        } else if inlineSets.isEmpty {
            content = .scene
        } else if !readable.isEmpty {
            content = .readableInlineActions
        } else if everyAction.contains(where: { String(describing: type(of: $0)) == "HMShortcutAction" }) {
            content = .shortcut
        } else {
            content = .other
        }

        let actions = readable.compactMap { action -> SceneActionSnapshot? in
            guard let write = action.homeFloorplanCharacteristicWrite else { return nil }
            return actionSnapshot(characteristic: write.characteristic,
                                  value: write.targetValue,
                                  serials: serials)
        }

        let restorability = AutomationRestoreBridge.restorable(from: trigger,
                                                               capabilities: capabilities,
                                                               serials: serials,
                                                               readableActions: actions)
        return AutomationSnapshot(
            name: item.name,
            localUUID: trigger.uniqueIdentifier.uuidString,
            isEnabled: trigger.isEnabled,
            triggerKind: item.triggerType.rawValue,
            content: content,
            humanSummary: item.summary,
            conditionSummaries: item.conditionSummaries,
            actionSetNames: item.actionSetNames,
            actions: actions,
            restorable: restorability.plan,
            notRestorableReason: restorability.reason
        )
    }
}

// MARK: - Conversione dei valori

extension SnapshotValue {
    init(_ value: Any?) {
        switch value {
        case let number as NSNumber:
            // `NSNumber` non distingue un Bool da un Int se non guardando il tipo
            // codificato: senza questo controllo ogni interruttore diventerebbe 0/1.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let text as String:
            self = .string(text)
        case let flag as Bool:
            self = .bool(flag)
        case .none:
            self = .unsupported(description: "nil")
        case .some(let other):
            self = .unsupported(description: String(describing: type(of: other)))
        }
    }
}

extension Bundle {
    var appVersionString: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
