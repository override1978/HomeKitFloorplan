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

        let serials = await readSerialNumbers(of: home.accessories)

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
            serviceGroups: home.serviceGroups.map(serviceGroupSnapshot),
            accessories: home.accessories.map { accessorySnapshot($0, serial: serials[$0.uniqueIdentifier]) },
            scenes: home.actionSets.map { sceneSnapshot($0, serials: serials) },
            automations: home.triggers.map { automationSnapshot($0, serials: serials) }
        )
    }

    // MARK: - Numeri di serie

    /// In sequenza e non in parallelo: un impianto reale ha decine di dispositivi
    /// su radio lente (Thread, Zigbee dietro bridge) e interrogarli tutti insieme
    /// produce timeout invece che risposte.
    private func readSerialNumbers(of accessories: [HMAccessory]) async -> [UUID: String] {
        var result: [UUID: String] = [:]
        for (index, accessory) in accessories.enumerated() {
            if let serial = await readSerialNumber(of: accessory) {
                result[accessory.uniqueIdentifier] = serial
            }
            progress = Double(index + 1) / Double(max(1, accessories.count))
        }
        return result
    }

    private func readSerialNumber(of accessory: HMAccessory) async -> String? {
        guard let info = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }),
              let characteristic = info.characteristics.first(where: {
                  $0.characteristicType == Self.serialNumberCharacteristicType
              })
        else { return nil }

        // La cache va benissimo: un numero di serie non cambia, e rileggerlo
        // costerebbe un giro di rete per nulla.
        if let cached = characteristic.value.map({ "\($0)" }),
           !cached.trimmingCharacters(in: .whitespaces).isEmpty {
            return cached
        }
        let didRead = await withCheckedContinuation { continuation in
            characteristic.readValue { error in continuation.resume(returning: error == nil) }
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

    private func serviceGroupSnapshot(_ group: HMServiceGroup) -> ServiceGroupSnapshot {
        ServiceGroupSnapshot(name: group.name,
                             serviceCount: group.services.count,
                             localUUID: group.uniqueIdentifier.uuidString)
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

    private func accessorySnapshot(_ accessory: HMAccessory, serial: String?) -> AccessorySnapshot {
        AccessorySnapshot(
            address: address(of: accessory, serial: serial),
            firmwareVersion: accessory.firmwareVersion,
            services: serviceSnapshots(of: accessory)
        )
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
                }
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
                characteristicType: characteristic.characteristicType
            ),
            value: SnapshotValue(value),
            format: formatHint(characteristic.metadata)
        )
    }

    // MARK: - Automazioni

    private func automationSnapshot(_ trigger: HMTrigger, serials: [UUID: String]) -> AutomationSnapshot {
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

        return AutomationSnapshot(
            name: item.name,
            localUUID: trigger.uniqueIdentifier.uuidString,
            isEnabled: trigger.isEnabled,
            triggerKind: item.triggerType.rawValue,
            content: content,
            humanSummary: item.summary,
            conditionSummaries: item.conditionSummaries,
            actionSetNames: item.actionSetNames,
            actions: actions
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
