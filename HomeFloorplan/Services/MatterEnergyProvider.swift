import Foundation
import HomeKit
import Matter

struct MatterEnergyDeviceSnapshot: Identifiable {
    let id: String
    let accessoryUUIDs: [UUID]
    let accessoryName: String
    let manufacturer: String
    let source: EnergySnapshotSource
    let nodeID: UInt64
    let powerEndpointID: UInt16?
    let energyEndpointID: UInt16?
    let activePowerWatts: Double?
    let cumulativeEnergyKilowattHours: Double?
    let measuredAt: Date
    let powerLatencyMilliseconds: Int?
    let energyLatencyMilliseconds: Int?
    let powerStatus: String
    let energyStatus: String

    var nodeIDText: String {
        if source == .eveLegacy {
            return "Eve legacy"
        }
        return "0x" + String(format: "%016llX", nodeID)
    }
}

enum EnergySnapshotSource: String {
    case matter = "Matter"
    case eveLegacy = "Eve legacy"
}

struct MatterEnergyLiveReport {
    let snapshots: [MatterEnergyDeviceSnapshot]
    let diagnostics: [String]
}

struct MatterEnergyProvider {
    private let evePowerCharacteristicType = "E863F10D-079E-48FF-8F27-9C2605A29F52"
    private let eveEnergyCharacteristicTypes = [
        "E863F10C-079E-48FF-8F27-9C2605A29F52",
        "E863F126-079E-48FF-8F27-9C2605A29F52"
    ]

    private let descriptorClusterID = NSNumber(value: 0x0000001D)
    private let serverListAttributeID = NSNumber(value: 0x00000001)
    private let electricalPowerMeasurementClusterID = NSNumber(value: 0x00000090)
    private let electricalEnergyMeasurementClusterID = NSNumber(value: 0x00000091)
    private let activePowerAttributeID = NSNumber(value: 0x00000008)
    private let cumulativeEnergyImportedAttributeID = NSNumber(value: 0x00000001)

    func readLiveEnergy(home: HMHome) async -> MatterEnergyLiveReport {
        let controller = MTRDeviceController.sharedController(
            withID: home.matterControllerID as NSString,
            xpcConnect: home.matterControllerXPCConnectBlock
        )
        let nodeGroups = Dictionary(grouping: home.accessories.compactMap(NodeAccessory.init(accessory:)), by: \.nodeID)
            .map { nodeID, nodeAccessories in
                MatterNodeGroup(nodeID: nodeID, accessories: nodeAccessories.map(\.accessory))
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        var snapshots: [MatterEnergyDeviceSnapshot] = []
        var diagnostics: [String] = []

        for nodeGroup in nodeGroups {
            let device = MTRBaseDevice(nodeID: NSNumber(value: nodeGroup.nodeID), controller: controller)
            let descriptorRead = await readDescriptorServerList(device: device)
            guard descriptorRead.error == nil else {
                diagnostics.append("\(nodeGroup.displayName): Descriptor error \(descriptorRead.statusText)")
                continue
            }

            let endpointClusters = endpointClusters(from: descriptorRead.values)
            let powerEndpointID = endpointClusters
                .filter { $0.value.contains(electricalPowerMeasurementClusterID.uint32Value) }
                .map { $0.key }
                .sorted()
                .first
            let energyEndpointID = endpointClusters
                .filter { $0.value.contains(electricalEnergyMeasurementClusterID.uint32Value) }
                .map { $0.key }
                .sorted()
                .first

            guard powerEndpointID != nil || energyEndpointID != nil else { continue }

            let powerRead: MatterAttributeReadResult? = if let powerEndpointID {
                await readAttribute(
                    device: device,
                    endpointID: NSNumber(value: powerEndpointID),
                    clusterID: electricalPowerMeasurementClusterID,
                    attributeID: activePowerAttributeID
                )
            } else {
                nil
            }
            let energyRead: MatterAttributeReadResult? = if let energyEndpointID {
                await readAttribute(
                    device: device,
                    endpointID: NSNumber(value: energyEndpointID),
                    clusterID: electricalEnergyMeasurementClusterID,
                    attributeID: cumulativeEnergyImportedAttributeID
                )
            } else {
                nil
            }

            snapshots.append(MatterEnergyDeviceSnapshot(
                id: nodeGroup.nodeIDText,
                accessoryUUIDs: nodeGroup.accessories.map(\.uniqueIdentifier),
                accessoryName: nodeGroup.displayName,
                manufacturer: manufacturer(for: nodeGroup.primaryAccessory),
                source: .matter,
                nodeID: nodeGroup.nodeID,
                powerEndpointID: powerEndpointID,
                energyEndpointID: energyEndpointID,
                activePowerWatts: powerRead?.numericValue.map { Double($0) / 1_000 },
                cumulativeEnergyKilowattHours: energyRead?.numericValue.map { Double($0) / 1_000_000 },
                measuredAt: Date(),
                powerLatencyMilliseconds: powerRead?.latencyMilliseconds,
                energyLatencyMilliseconds: energyRead?.latencyMilliseconds,
                powerStatus: powerRead?.statusText ?? "cluster assente",
                energyStatus: energyRead?.statusText ?? "cluster assente"
            ))
        }

        let matterCoveredAccessoryUUIDs = Set(snapshots.flatMap(\.accessoryUUIDs))
        for accessory in home.accessories.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            guard !matterCoveredAccessoryUUIDs.contains(accessory.uniqueIdentifier),
                  let snapshot = await readEveLegacyEnergy(accessory: accessory) else {
                continue
            }
            snapshots.append(snapshot)
        }

        return MatterEnergyLiveReport(snapshots: snapshots, diagnostics: diagnostics)
    }

    private func readEveLegacyEnergy(accessory: HMAccessory) async -> MatterEnergyDeviceSnapshot? {
        let powerCharacteristic = characteristic(in: accessory, type: evePowerCharacteristicType)
        let energyCharacteristic = eveEnergyCharacteristicTypes
            .lazy
            .compactMap { characteristic(in: accessory, type: $0) }
            .first

        guard powerCharacteristic != nil || energyCharacteristic != nil else {
            return nil
        }

        let powerRead = await readHomeKitCharacteristic(powerCharacteristic)
        let energyRead = await readHomeKitCharacteristic(energyCharacteristic)

        return MatterEnergyDeviceSnapshot(
            id: "eve-\(accessory.uniqueIdentifier.uuidString)",
            accessoryUUIDs: [accessory.uniqueIdentifier],
            accessoryName: accessory.name,
            manufacturer: manufacturer(for: accessory),
            source: .eveLegacy,
            nodeID: 0,
            powerEndpointID: nil,
            energyEndpointID: nil,
            activePowerWatts: powerRead.value,
            cumulativeEnergyKilowattHours: energyRead.value,
            measuredAt: Date(),
            powerLatencyMilliseconds: powerRead.latencyMilliseconds,
            energyLatencyMilliseconds: energyRead.latencyMilliseconds,
            powerStatus: powerRead.status,
            energyStatus: energyRead.status
        )
    }

    private func readDescriptorServerList(device: MTRBaseDevice) async -> MatterAttributeReadResult {
        await readAttribute(
            device: device,
            endpointID: nil,
            clusterID: descriptorClusterID,
            attributeID: serverListAttributeID
        )
    }

    private func readAttribute(
        device: MTRBaseDevice,
        endpointID: NSNumber?,
        clusterID: NSNumber,
        attributeID: NSNumber
    ) async -> MatterAttributeReadResult {
        let start = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            device.readAttributes(
                withEndpointID: endpointID,
                clusterID: clusterID,
                attributeID: attributeID,
                params: nil,
                queue: .main
            ) { values, error in
                let elapsed = start.duration(to: ContinuousClock.now)
                let milliseconds = max(0, Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
                continuation.resume(returning: MatterAttributeReadResult(
                    values: values ?? [],
                    error: error as NSError?,
                    latencyMilliseconds: milliseconds
                ))
            }
        }
    }

    private func endpointClusters(from values: [[String: Any]]) -> [UInt16: [UInt32]] {
        values.reduce(into: [UInt16: [UInt32]]()) { result, response in
            guard response[MTRErrorKey] == nil,
                  let path = response[MTRAttributePathKey] as? MTRAttributePath,
                  path.cluster.uint32Value == descriptorClusterID.uint32Value,
                  path.attribute.uint32Value == serverListAttributeID.uint32Value,
                  let data = response[MTRDataKey] as? [String: Any],
                  let clusters = clusterIDs(from: data) else {
                return
            }
            result[path.endpoint.uint16Value] = clusters
        }
    }

    private func clusterIDs(from data: [String: Any]) -> [UInt32]? {
        guard let array = data[MTRValueKey] as? [[String: Any]] else { return nil }
        return array.compactMap { element -> UInt32? in
            guard let nestedData = element[MTRDataKey] as? [String: Any],
                  let value = nestedData[MTRValueKey] as? NSNumber else {
                return nil
            }
            return value.uint32Value
        }
    }

    private func characteristic(in accessory: HMAccessory, type: String) -> HMCharacteristic? {
        accessory.services
            .flatMap(\.characteristics)
            .first { $0.characteristicType.uppercased() == type }
    }

    private func readHomeKitCharacteristic(_ characteristic: HMCharacteristic?) async -> EveLegacyReadResult {
        guard let characteristic else {
            return EveLegacyReadResult(value: nil, latencyMilliseconds: nil, status: "caratteristica assente")
        }

        let start = ContinuousClock.now
        let error: Error? = await withCheckedContinuation { continuation in
            characteristic.readValue { error in
                continuation.resume(returning: error)
            }
        }
        let elapsed = start.duration(to: ContinuousClock.now)
        let milliseconds = max(0, Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000))

        if let error = error as NSError? {
            return EveLegacyReadResult(
                value: nil,
                latencyMilliseconds: milliseconds,
                status: "errore \(error.domain)/\(error.code) \(error.localizedDescription)"
            )
        }

        guard let value = numericHomeKitValue(characteristic.value) else {
            return EveLegacyReadResult(value: nil, latencyMilliseconds: milliseconds, status: "valore non numerico")
        }
        return EveLegacyReadResult(value: value, latencyMilliseconds: milliseconds, status: "ok")
    }

    private func numericHomeKitValue(_ value: Any?) -> Double? {
        switch value {
        case let value as NSNumber:
            return value.doubleValue
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case let value as Int:
            return Double(value)
        default:
            return nil
        }
    }

    private func manufacturer(for accessory: HMAccessory) -> String {
        guard let informationService = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }),
              let characteristic = informationService.characteristics.first(where: { $0.characteristicType == "00000020-0000-1000-8000-0026BB765291" }),
              let value = characteristic.value else {
            return "-"
        }
        return String(describing: value)
    }

    private struct NodeAccessory {
        let nodeID: UInt64
        let accessory: HMAccessory

        init?(accessory: HMAccessory) {
            guard let nodeID = accessory.matterNodeID, nodeID != 0 else { return nil }
            self.nodeID = nodeID
            self.accessory = accessory
        }
    }

    private struct MatterNodeGroup {
        let nodeID: UInt64
        let accessories: [HMAccessory]

        var primaryAccessory: HMAccessory { accessories.first! }

        var displayName: String {
            if accessories.count == 1 { return primaryAccessory.name }
            return "\(primaryAccessory.name) +\(accessories.count - 1)"
        }

        var nodeIDText: String {
            "0x" + String(format: "%016llX", nodeID)
        }
    }
}

private struct MatterAttributeReadResult {
    let values: [[String: Any]]
    let error: NSError?
    let latencyMilliseconds: Int

    var numericValue: Int64? {
        guard error == nil,
              let first = values.first,
              first[MTRErrorKey] == nil,
              let data = first[MTRDataKey] as? [String: Any] else {
            return nil
        }
        return Self.numericMatterValue(from: data)
    }

    var statusText: String {
        if let error {
            return "errore \(error.domain)/\(error.code) \(error.localizedDescription)"
        }
        if let pathError = values.compactMap({ $0[MTRErrorKey] as? NSError }).first {
            return "errore \(pathError.domain)/\(pathError.code) \(pathError.localizedDescription)"
        }
        return "ok"
    }

    private static func numericMatterValue(from data: [String: Any]) -> Int64? {
        if let value = data[MTRValueKey] as? NSNumber {
            return value.int64Value
        }
        guard let array = data[MTRValueKey] as? [[String: Any]] else {
            return nil
        }
        return array.compactMap { element -> Int64? in
            guard let nestedData = element[MTRDataKey] as? [String: Any],
                  let value = nestedData[MTRValueKey] as? NSNumber else {
                return nil
            }
            return value.int64Value
        }.first
    }
}

private struct EveLegacyReadResult {
    let value: Double?
    let latencyMilliseconds: Int?
    let status: String
}
