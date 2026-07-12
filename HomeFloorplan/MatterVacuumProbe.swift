import Foundation
import HomeKit
import Matter

struct MatterVacuumProbeReport: Sendable {
    let text: String
}

struct MatterVacuumProbe {
    private let descriptorClusterID = NSNumber(value: 0x0000001D)
    private let serverListAttributeID = NSNumber(value: 0x00000001)
    private let clusterRevisionAttributeID = NSNumber(value: 0x0000FFFD)
    private let basicInformationClusterID = NSNumber(value: 0x00000028)
    private let productNameAttributeID = NSNumber(value: 0x00000003)

    private let rvcRunModeClusterID: UInt32 = 0x00000054
    private let rvcCleanModeClusterID: UInt32 = 0x00000055
    private let rvcOperationalStateClusterID: UInt32 = 0x00000061
    private let serviceAreaClusterID: UInt32 = 0x00000150
    private let targetedEndpointRange: ClosedRange<UInt16> = 0...20

    func run(home: HMHome) async -> MatterVacuumProbeReport {
        let accessories = home.accessories.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let validNodeGroups = Dictionary(grouping: accessories.compactMap(NodeAccessory.init(accessory:)), by: \.nodeID)
            .map { nodeID, nodeAccessories in
                MatterNodeGroup(nodeID: nodeID, accessories: nodeAccessories.map(\.accessory))
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        let controller = MTRDeviceController.sharedController(
            withID: home.matterControllerID as NSString,
            xpcConnect: home.matterControllerXPCConnectBlock
        )

        var lines: [String] = []
        var matchingNodes = 0
        var descriptorFailures: [String] = []

        lines.append("=== SONDA MATTER VACUUM/RVC (home: \(home.name)) ===")
        lines.append("Accessori totali: \(accessories.count)")
        lines.append("Nodi Matter validi unici sondati: \(validNodeGroups.count)")
        lines.append("Cluster cercati: RVCRunMode, RVCCleanMode, RVCOperationalState, ServiceArea")
        lines.append("Fallback mirato: sui nodi con Descriptor non leggibile prova ClusterRevision su ep\(targetedEndpointRange.lowerBound)...ep\(targetedEndpointRange.upperBound)")
        lines.append("")

        for nodeGroup in validNodeGroups {
            let device = MTRBaseDevice(nodeID: NSNumber(value: nodeGroup.nodeID), controller: controller)
            let descriptorRead = await readDescriptorServerList(device: device)
            guard descriptorRead.error == nil else {
                descriptorFailures.append("\(nodeGroup.displayName): \(descriptorRead.compactStatusText)")
                let basicInfoRead = await readBasicInformationProductName(device: device)
                let targetedProbe = await readTargetedRVCClusters(device: device)
                guard !targetedProbe.endpoints.isEmpty else {
                    appendTargetedProbeFailure(
                        to: &lines,
                        nodeGroup: nodeGroup,
                        reason: "Descriptor non leggibile: \(descriptorRead.detailedStatusText)",
                        basicInfoRead: basicInfoRead,
                        probe: targetedProbe
                    )
                    continue
                }

                matchingNodes += 1
                appendNodeReport(
                    to: &lines,
                    nodeGroup: nodeGroup,
                    rvcEndpoints: targetedProbe.endpoints,
                    note: "prova mirata; Descriptor non leggibile: \(descriptorRead.detailedStatusText)"
                )
                continue
            }

            let endpointClusters = endpointClusters(from: descriptorRead.values)
            guard !endpointClusters.isEmpty else {
                descriptorFailures.append("\(nodeGroup.displayName): Descriptor ServerList vuoto/non parsabile")
                let basicInfoRead = await readBasicInformationProductName(device: device)
                let targetedProbe = await readTargetedRVCClusters(device: device)
                guard !targetedProbe.endpoints.isEmpty else {
                    appendTargetedProbeFailure(
                        to: &lines,
                        nodeGroup: nodeGroup,
                        reason: "Descriptor ServerList vuoto/non parsabile",
                        basicInfoRead: basicInfoRead,
                        probe: targetedProbe
                    )
                    continue
                }

                matchingNodes += 1
                appendNodeReport(
                    to: &lines,
                    nodeGroup: nodeGroup,
                    rvcEndpoints: targetedProbe.endpoints,
                    note: "prova mirata; Descriptor ServerList vuoto/non parsabile"
                )
                continue
            }

            let rvcEndpoints = rvcEndpointClusters(from: endpointClusters)
            guard !rvcEndpoints.isEmpty else {
                continue
            }

            matchingNodes += 1
            appendNodeReport(to: &lines, nodeGroup: nodeGroup, rvcEndpoints: rvcEndpoints, note: "Descriptor.ServerList")
        }

        lines.append("Nodi Matter con cluster Vacuum/RVC: \(matchingNodes) / \(validNodeGroups.count)")
        lines.append("Nodi validi non leggibili via Descriptor.ServerList: \(descriptorFailures.count)")
        if !descriptorFailures.isEmpty {
            lines.append("Errori Descriptor: \(descriptorFailures.prefix(10).joined(separator: " | "))\(descriptorFailures.count > 10 ? " ..." : "")")
        }

        let text = lines.joined(separator: "\n")
        print(text)
        return MatterVacuumProbeReport(text: text)
    }

    private func readDescriptorServerList(device: MTRBaseDevice) async -> ProbeAttributeReadResult {
        await readAttribute(
            device: device,
            endpointID: nil,
            clusterID: descriptorClusterID,
            attributeID: serverListAttributeID
        )
    }

    private func readBasicInformationProductName(device: MTRBaseDevice) async -> ProbeAttributeReadResult {
        await readAttribute(
            device: device,
            endpointID: NSNumber(value: 0),
            clusterID: basicInformationClusterID,
            attributeID: productNameAttributeID
        )
    }

    private func readTargetedRVCClusters(device: MTRBaseDevice) async -> TargetedProbeResult {
        var result: [UInt16: [String]] = [:]
        var attempts = 0
        var failures: [String] = []
        for endpoint in targetedEndpointRange {
            for clusterID in rvcClusterIDs {
                attempts += 1
                let read = await readAttribute(
                    device: device,
                    endpointID: NSNumber(value: endpoint),
                    clusterID: NSNumber(value: clusterID),
                    attributeID: clusterRevisionAttributeID
                )
                guard read.isSuccessfulRead,
                      let displayName = rvcClusterDisplayName(clusterID) else {
                    if failures.count < 8, let displayName = rvcClusterDisplayName(clusterID) {
                        failures.append("ep\(endpoint) \(displayName): \(read.detailedStatusText)")
                    }
                    continue
                }
                result[endpoint, default: []].append("\(displayName) ✓")
            }
        }
        return TargetedProbeResult(endpoints: result, attempts: attempts, sampleFailures: failures)
    }

    private func readAttribute(
        device: MTRBaseDevice,
        endpointID: NSNumber?,
        clusterID: NSNumber,
        attributeID: NSNumber
    ) async -> ProbeAttributeReadResult {
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
                continuation.resume(returning: ProbeAttributeReadResult(
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

    private func rvcEndpointClusters(from endpointClusters: [UInt16: [UInt32]]) -> [UInt16: [String]] {
        endpointClusters.reduce(into: [UInt16: [String]]()) { result, item in
            let clusters = item.value.compactMap(rvcClusterDisplayName)
            if !clusters.isEmpty {
                result[item.key] = clusters
            }
        }
    }

    private func rvcClusterDisplayName(_ clusterID: UInt32) -> String? {
        switch clusterID {
        case rvcRunModeClusterID:
            return "RVCRunMode"
        case rvcCleanModeClusterID:
            return "RVCCleanMode"
        case rvcOperationalStateClusterID:
            return "RVCOperationalState"
        case serviceAreaClusterID:
            return "ServiceArea"
        default:
            return nil
        }
    }

    private var rvcClusterIDs: [UInt32] {
        [
            rvcRunModeClusterID,
            rvcCleanModeClusterID,
            rvcOperationalStateClusterID,
            serviceAreaClusterID
        ]
    }

    private func appendNodeReport(
        to lines: inout [String],
        nodeGroup: MatterNodeGroup,
        rvcEndpoints: [UInt16: [String]],
        note: String
    ) {
        lines.append("\(nodeGroup.displayName) (\(manufacturer(for: nodeGroup.primaryAccessory))) — nodeID: \(nodeIDText(nodeGroup.nodeID))")
        lines.append("  Metodo: \(note)")
        if nodeGroup.accessories.count > 1 {
            lines.append("  Accessori HomeKit su questo nodo: \(nodeGroup.accessories.map(\.name).joined(separator: ", "))")
        }
        for endpoint in rvcEndpoints.keys.sorted() {
            let clusters = rvcEndpoints[endpoint] ?? []
            lines.append("  ep\(endpoint): [\(clusters.joined(separator: ", "))]")
        }
        lines.append("")
    }

    private func appendTargetedProbeFailure(
        to lines: inout [String],
        nodeGroup: MatterNodeGroup,
        reason: String,
        basicInfoRead: ProbeAttributeReadResult,
        probe: TargetedProbeResult
    ) {
        lines.append("\(nodeGroup.displayName) (\(manufacturer(for: nodeGroup.primaryAccessory))) — nodeID: \(nodeIDText(nodeGroup.nodeID))")
        lines.append("  Metodo: prova mirata negativa; \(reason)")
        lines.append("  BasicInformation.ProductName ep0: \(basicInfoRead.formattedValue) | \(basicInfoRead.detailedStatusText)")
        lines.append("  Tentativi mirati: \(probe.attempts) letture ClusterRevision su ep\(targetedEndpointRange.lowerBound)...ep\(targetedEndpointRange.upperBound)")
        if probe.sampleFailures.isEmpty {
            lines.append("  Errori campione: nessuno; nessun valore restituito")
        } else {
            lines.append("  Errori campione: \(probe.sampleFailures.joined(separator: " | "))")
        }
        lines.append("")
    }

    private func manufacturer(for accessory: HMAccessory) -> String {
        guard let informationService = accessory.services.first(where: { $0.serviceType == HMServiceTypeAccessoryInformation }),
              let characteristic = informationService.characteristics.first(where: { $0.characteristicType == "00000020-0000-1000-8000-0026BB765291" }),
              let value = characteristic.value else {
            return "—"
        }
        return String(describing: value)
    }

    private func nodeIDText(_ nodeID: UInt64) -> String {
        "0x" + String(format: "%016llX", nodeID)
    }

    private struct ProbeAttributeReadResult {
        let values: [[String: Any]]
        let error: NSError?
        let latencyMilliseconds: Int

        var isSuccessfulRead: Bool {
            error == nil && !values.isEmpty && values.allSatisfy { $0[MTRErrorKey] == nil }
        }

        var compactStatusText: String {
            if let error {
                return "errore \(error.domain)/\(error.code) \(latencyText)"
            }
            if let pathError = values.compactMap({ $0[MTRErrorKey] as? NSError }).first {
                return "errore \(pathError.domain)/\(pathError.code) \(latencyText)"
            }
            return "ok \(latencyText)"
        }

        var detailedStatusText: String {
            if let error {
                return "errore \(errorDescription(error)) \(latencyText)"
            }
            if let pathError = values.compactMap({ $0[MTRErrorKey] as? NSError }).first {
                return "errore \(errorDescription(pathError)) \(latencyText)"
            }
            return "ok \(latencyText)"
        }

        var formattedValue: String {
            guard isSuccessfulRead else {
                return "errore"
            }
            guard let data = values.first?[MTRDataKey] as? [String: Any],
                  let value = data[MTRValueKey] else {
                return "dato assente"
            }
            return String(describing: value)
        }

        private var latencyText: String {
            "(\(latencyMilliseconds) ms)"
        }

        private func errorDescription(_ error: NSError) -> String {
            let underlying = (error.userInfo[NSUnderlyingErrorKey] as? NSError)
                .map { " underlying=\($0.domain)/\($0.code) \($0.localizedDescription)" } ?? ""
            return "\(error.domain)/\(error.code) \(error.localizedDescription)\(underlying) userInfo=\(error.userInfo)"
        }
    }

    private struct TargetedProbeResult {
        let endpoints: [UInt16: [String]]
        let attempts: Int
        let sampleFailures: [String]
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
}
