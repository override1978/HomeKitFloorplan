import Foundation
import HomeKit
import Matter

struct MatterEnergyProbeReport: Sendable {
    let text: String
}

struct MatterEnergyProbe {
    private let descriptorClusterID = NSNumber(value: 0x0000001D)
    private let serverListAttributeID = NSNumber(value: 0x00000001)
    private let electricalPowerMeasurementClusterID = NSNumber(value: 0x00000090)
    private let electricalEnergyMeasurementClusterID = NSNumber(value: 0x00000091)
    private let activePowerAttributeID = NSNumber(value: 0x00000008)
    private let cumulativeEnergyImportedAttributeID = NSNumber(value: 0x00000001)

    func run(home: HMHome) async -> MatterEnergyProbeReport {
        let accessories = home.accessories.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let hapOnlyAccessories = accessories.filter { $0.matterNodeID == nil }
        let zeroNodeAccessories = accessories.filter { $0.matterNodeID == 0 }
        let validNodeGroups = Dictionary(grouping: accessories.compactMap(NodeAccessory.init(accessory:)), by: \.nodeID)
            .map { nodeID, nodeAccessories in
                MatterNodeGroup(nodeID: nodeID, accessories: nodeAccessories.map(\.accessory))
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        var lines: [String] = []
        lines.append("=== SONDA MATTER ENERGIA (home: \(home.name)) ===")
        lines.append("Accessori totali: \(accessories.count)")
        lines.append("HAP-only (matterNodeID nil): \(hapOnlyAccessories.count)")
        lines.append("matterNodeID = 0, non sondabile come nodo Matter diretto: \(zeroNodeAccessories.count)")
        lines.append("Nodi Matter validi unici sondati: \(validNodeGroups.count)")
        lines.append("")

        if !hapOnlyAccessories.isEmpty {
            lines.append("HAP-only: \(hapOnlyAccessories.map(\.name).joined(separator: ", "))")
        }
        if !zeroNodeAccessories.isEmpty {
            lines.append("matterNodeID=0: \(zeroNodeAccessories.prefix(20).map(\.name).joined(separator: ", "))\(zeroNodeAccessories.count > 20 ? " ..." : "")")
        }
        lines.append("")

        let controller = MTRDeviceController.sharedController(
            withID: home.matterControllerID as NSString,
            xpcConnect: home.matterControllerXPCConnectBlock
        )

        var matterNodesWithEnergyClusters = 0
        var matterNodesWithUsefulCapabilities = 0
        var hiddenNodesWithoutUsefulCapabilities = 0
        var descriptorFailures: [String] = []

        for nodeGroup in validNodeGroups {
            let device = MTRBaseDevice(nodeID: NSNumber(value: nodeGroup.nodeID), controller: controller)
            let endpointClusters = await readEndpointClusters(device: device)
            if endpointClusters.isEmpty {
                let read = await readDescriptorRaw(device: device)
                descriptorFailures.append("\(nodeGroup.displayName): \(read.statusText)")
                continue
            }

            let usefulEndpoints = usefulEndpointClusters(from: endpointClusters)
            if usefulEndpoints.isEmpty {
                hiddenNodesWithoutUsefulCapabilities += 1
                continue
            }

            let hasEnergyCluster = endpointClusters.values.contains { clusters in
                clusters.contains(electricalPowerMeasurementClusterID.uint32Value) || clusters.contains(electricalEnergyMeasurementClusterID.uint32Value)
            }
            if hasEnergyCluster {
                matterNodesWithEnergyClusters += 1
            }
            matterNodesWithUsefulCapabilities += 1

            lines.append("\(nodeGroup.displayName) (\(manufacturer(for: nodeGroup.primaryAccessory))) — nodeID: \(nodeIDText(nodeGroup.nodeID))")
            lines.append("  Capability utili: \(usefulCapabilitySummary(from: usefulEndpoints))")
            if nodeGroup.accessories.count > 1 {
                lines.append("  Accessori HomeKit su questo nodo: \(nodeGroup.accessories.map(\.name).joined(separator: ", "))")
            }
            for endpoint in usefulEndpoints.keys.sorted() {
                let clusters = usefulEndpoints[endpoint] ?? []
                lines.append("  ep\(endpoint): [\(clusters.joined(separator: ", "))]")
            }

            let powerEndpoints = endpointClusters
                .filter { $0.value.contains(electricalPowerMeasurementClusterID.uint32Value) }
                .map { $0.key }
                .sorted()
            if let endpoint = powerEndpoints.first {
                let read = await readSingleAttribute(
                    device: device,
                    endpointID: NSNumber(value: endpoint),
                    clusterID: electricalPowerMeasurementClusterID,
                    attributeID: activePowerAttributeID
                )
                lines.append("  Lettura potenza:  \(read.formattedValue(unit: .milliwatts)) (\(read.latencyMilliseconds) ms) | \(read.statusText)")
            } else {
                lines.append("  Lettura potenza:  n/a | cluster assente")
            }

            let energyEndpoints = endpointClusters
                .filter { $0.value.contains(electricalEnergyMeasurementClusterID.uint32Value) }
                .map { $0.key }
                .sorted()
            if let endpoint = energyEndpoints.first {
                let read = await readSingleAttribute(
                    device: device,
                    endpointID: NSNumber(value: endpoint),
                    clusterID: electricalEnergyMeasurementClusterID,
                    attributeID: cumulativeEnergyImportedAttributeID
                )
                lines.append("  Lettura energia:  \(read.formattedValue(unit: .milliwattHours)) (\(read.latencyMilliseconds) ms) | \(read.statusText)")
            } else {
                lines.append("  Lettura energia:  n/a | cluster assente")
            }
            lines.append("")
        }

        lines.append("Nodi Matter con capability utili: \(matterNodesWithUsefulCapabilities) / \(validNodeGroups.count)")
        lines.append("Nodi Matter con cluster energia: \(matterNodesWithEnergyClusters) / \(validNodeGroups.count)")
        lines.append("Nodi validi nascosti perché senza capability utile nota: \(hiddenNodesWithoutUsefulCapabilities)")
        lines.append("Nodi validi non leggibili via Descriptor.ServerList: \(descriptorFailures.count)")
        if !descriptorFailures.isEmpty {
            lines.append("Errori Descriptor: \(descriptorFailures.prefix(10).joined(separator: " | "))\(descriptorFailures.count > 10 ? " ..." : "")")
        }

        let text = lines.joined(separator: "\n")
        print(text)
        return MatterEnergyProbeReport(text: text)
    }

    private func nodeIDText(_ nodeID: UInt64) -> String {
        "0x" + String(format: "%016llX", nodeID)
    }

    private func readEndpointClusters(device: MTRBaseDevice) async -> [UInt16: [UInt32]] {
        let read = await readDescriptorRaw(device: device)
        guard read.error == nil else { return [:] }

        var endpointClusters: [UInt16: [UInt32]] = [:]
        for response in read.values {
            if let error = response[MTRErrorKey] as? NSError {
                print("Matter Descriptor per-path error: \(error.domain)/\(error.code) \(error.localizedDescription)")
                continue
            }
            guard let path = response[MTRAttributePathKey] as? MTRAttributePath,
                  path.cluster.uint32Value == descriptorClusterID.uint32Value,
                  path.attribute.uint32Value == serverListAttributeID.uint32Value,
                  let data = response[MTRDataKey] as? [String: Any],
                  let clusters = clusterIDs(from: data) else {
                continue
            }
            endpointClusters[path.endpoint.uint16Value] = clusters
        }
        return endpointClusters
    }

    private func readDescriptorRaw(device: MTRBaseDevice) async -> AttributeReadResult {
        await readSingleAttribute(
            device: device,
            endpointID: nil,
            clusterID: descriptorClusterID,
            attributeID: serverListAttributeID
        )
    }

    private func readSingleAttribute(
        device: MTRBaseDevice,
        endpointID: NSNumber?,
        clusterID: NSNumber,
        attributeID: NSNumber
    ) async -> AttributeReadResult {
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
                continuation.resume(returning: AttributeReadResult(
                    values: values ?? [],
                    error: error as NSError?,
                    latencyMilliseconds: milliseconds
                ))
            }
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

    private func usefulEndpointClusters(from endpointClusters: [UInt16: [UInt32]]) -> [UInt16: [String]] {
        endpointClusters.reduce(into: [UInt16: [String]]()) { result, item in
            let usefulClusters = item.value.compactMap(usefulClusterDisplayName)
            if !usefulClusters.isEmpty {
                result[item.key] = usefulClusters
            }
        }
    }

    private func usefulCapabilitySummary(from usefulEndpoints: [UInt16: [String]]) -> String {
        let capabilities = usefulEndpoints.values
            .flatMap { $0 }
            .map { $0.replacingOccurrences(of: " ⚡", with: "") }
        let unique = Array(Set(capabilities)).sorted()
        return unique.joined(separator: ", ")
    }

    private func manufacturer(for accessory: HMAccessory) -> String {
        guard let informationService = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }),
              let characteristic = informationService.characteristics.first(where: { $0.characteristicType == "00000020-0000-1000-8000-0026BB765291" }),
              let value = characteristic.value else {
            return "—"
        }
        return String(describing: value)
    }

    private func clusterDisplayName(_ clusterID: UInt32) -> String {
        switch clusterID {
        case 0x0000001D:
            return "Descriptor"
        case 0x00000006:
            return "OnOff"
        case 0x00000008:
            return "LevelControl"
        case 0x0000001F:
            return "AccessControl"
        case 0x00000028:
            return "BasicInformation"
        case 0x0000002F:
            return "PowerSource"
        case 0x00000030:
            return "GeneralCommissioning"
        case 0x00000031:
            return "NetworkCommissioning"
        case 0x0000003E:
            return "OperationalCredentials"
        case electricalPowerMeasurementClusterID.uint32Value:
            return "ElectricalPowerMeasurement ⚡"
        case electricalEnergyMeasurementClusterID.uint32Value:
            return "ElectricalEnergyMeasurement ⚡"
        default:
            return String(format: "0x%08X", clusterID)
        }
    }

    private func usefulClusterDisplayName(_ clusterID: UInt32) -> String? {
        switch clusterID {
        case 0x00000006:
            return "OnOff"
        case 0x00000008:
            return "LevelControl"
        case 0x00000045:
            return "BooleanState"
        case 0x00000047:
            return "Timer"
        case 0x00000048:
            return "OvenCavityOperationalState"
        case 0x00000049:
            return "OvenMode"
        case 0x0000004A:
            return "LaundryDryerControls"
        case 0x00000050:
            return "ModeSelect"
        case 0x00000051:
            return "LaundryWasherMode"
        case 0x00000052:
            return "RefrigeratorMode"
        case 0x00000053:
            return "LaundryWasherControls"
        case 0x00000054:
            return "RVCRunMode"
        case 0x00000055:
            return "RVCCleanMode"
        case 0x00000056:
            return "TemperatureControl"
        case 0x00000057:
            return "RefrigeratorAlarm"
        case 0x00000059:
            return "DishwasherMode"
        case 0x0000005B:
            return "AirQuality"
        case 0x0000005C:
            return "SmokeCOAlarm"
        case 0x0000005D:
            return "DishwasherAlarm"
        case 0x0000005E:
            return "MicrowaveOvenMode"
        case 0x0000005F:
            return "MicrowaveOvenControl"
        case 0x00000060:
            return "OperationalState"
        case 0x00000061:
            return "RVCOperationalState"
        case 0x00000071:
            return "HEPAFilterMonitoring"
        case 0x00000072:
            return "CarbonFilterMonitoring"
        case 0x00000079:
            return "WaterTankLevelMonitoring"
        case 0x00000080:
            return "BooleanStateConfiguration"
        case 0x00000081:
            return "ValveConfigurationAndControl"
        case electricalPowerMeasurementClusterID.uint32Value:
            return "ElectricalPowerMeasurement ⚡"
        case electricalEnergyMeasurementClusterID.uint32Value:
            return "ElectricalEnergyMeasurement ⚡"
        case 0x00000094:
            return "WaterHeaterManagement"
        case 0x00000098:
            return "DeviceEnergyManagement"
        case 0x00000099:
            return "EnergyEVSE"
        case 0x0000009C:
            return "PowerTopology"
        case 0x0000009D:
            return "EnergyEVSEMode"
        case 0x0000009E:
            return "WaterHeaterMode"
        case 0x0000009F:
            return "DeviceEnergyManagementMode"
        case 0x00000101:
            return "DoorLock"
        case 0x00000102:
            return "WindowCovering"
        case 0x00000150:
            return "ServiceArea"
        case 0x00000200:
            return "PumpConfigurationAndControl"
        case 0x00000201:
            return "Thermostat"
        case 0x00000202:
            return "FanControl"
        case 0x00000300:
            return "ColorControl"
        case 0x00000400:
            return "IlluminanceMeasurement"
        case 0x00000402:
            return "TemperatureMeasurement"
        case 0x00000403:
            return "PressureMeasurement"
        case 0x00000404:
            return "FlowMeasurement"
        case 0x00000405:
            return "RelativeHumidityMeasurement"
        case 0x00000406:
            return "OccupancySensing"
        case 0x0000040C:
            return "CarbonMonoxideMeasurement"
        case 0x0000040D:
            return "CarbonDioxideMeasurement"
        case 0x0000042A:
            return "PM2.5Measurement"
        case 0x0000042B:
            return "FormaldehydeMeasurement"
        case 0x0000042C:
            return "PM1Measurement"
        case 0x0000042D:
            return "PM10Measurement"
        case 0x0000042E:
            return "VOCMeasurement"
        case 0x0000042F:
            return "RadonMeasurement"
        case 0x00000503:
            return "WakeOnLAN"
        case 0x00000504:
            return "Channel"
        case 0x00000505:
            return "TargetNavigator"
        case 0x00000506:
            return "MediaPlayback"
        case 0x0000050A:
            return "ContentLauncher"
        case 0x0000050C:
            return "ApplicationLauncher"
        default:
            return nil
        }
    }

    private struct AttributeReadResult {
        let values: [[String: Any]]
        let error: NSError?
        let latencyMilliseconds: Int

        func formattedValue(unit: MatterValueUnit) -> String {
            if error != nil {
                return "errore"
            }
            guard let first = values.first else {
                return "nessun valore"
            }
            if let pathError = first[MTRErrorKey] as? NSError {
                return "errore \(pathError.domain)/\(pathError.code)"
            }
            guard let data = first[MTRDataKey] as? [String: Any] else {
                return "dato assente"
            }
            guard let rawValue = MatterEnergyProbe.numericMatterValue(from: data) else {
                return "\(MatterEnergyProbe.describeMatterData(data)) raw"
            }
            return unit.format(rawValue)
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
    }

    private static func describeMatterData(_ data: [String: Any]) -> String {
        if let value = data[MTRValueKey] {
            return "\(value)"
        }
        return "null/struttura senza valore raw"
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

    private struct NodeAccessory {
        let nodeID: UInt64
        let accessory: HMAccessory

        init?(accessory: HMAccessory) {
            guard let nodeID = accessory.matterNodeID, nodeID != 0 else {
                return nil
            }
            self.nodeID = nodeID
            self.accessory = accessory
        }
    }

    private struct MatterNodeGroup {
        let nodeID: UInt64
        let accessories: [HMAccessory]

        var primaryAccessory: HMAccessory {
            accessories.first!
        }

        var displayName: String {
            if accessories.count == 1 {
                return primaryAccessory.name
            }
            return "\(primaryAccessory.name) +\(accessories.count - 1)"
        }
    }

    private enum MatterValueUnit {
        case milliwatts
        case milliwattHours

        func format(_ rawValue: Int64) -> String {
            switch self {
            case .milliwatts:
                let watts = Double(rawValue) / 1_000
                return "\(rawValue) mW (\(Self.decimal(watts)) W)"
            case .milliwattHours:
                let kilowattHours = Double(rawValue) / 1_000_000
                return "\(rawValue) mWh (\(Self.decimal(kilowattHours)) kWh)"
            }
        }

        private static func decimal(_ value: Double) -> String {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 3
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }
    }
}
