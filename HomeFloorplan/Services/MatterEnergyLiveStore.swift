import Foundation
import HomeKit
import Matter
import Observation

@Observable
final class MatterEnergyLiveStore {
    private let provider = MatterEnergyProvider()

    private(set) var snapshots: [MatterEnergyDeviceSnapshot] = []
    private var snapshotsByAccessoryUUID: [UUID: MatterEnergyDeviceSnapshot] = [:]
    private(set) var diagnostics: [String] = []
    private(set) var isRefreshing: Bool = false
    private(set) var lastRefresh: Date?

    func snapshot(for accessoryUUID: UUID) -> MatterEnergyDeviceSnapshot? {
        snapshotsByAccessoryUUID[accessoryUUID]
    }

    @MainActor
    func refreshIfNeeded(home: HMHome, minimumInterval: TimeInterval = 15 * 60) async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < minimumInterval {
            return
        }
        await refresh(home: home)
    }

    @MainActor
    func refresh(home: HMHome) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let report = await provider.readLiveEnergy(home: home)
        snapshots = report.snapshots
        snapshotsByAccessoryUUID = Dictionary(
            uniqueKeysWithValues: report.snapshots.flatMap { snapshot in
                snapshot.accessoryUUIDs.map { ($0, snapshot) }
            }
        )
        diagnostics = report.diagnostics
        lastRefresh = Date()
    }

    @MainActor
    func applyMatterSubscriptionUpdate(
        target: MatterEnergySubscriptionTarget,
        activePowerWatts: Double?,
        cumulativeEnergyKilowattHours: Double?,
        powerStatus: String?,
        energyStatus: String?
    ) {
        let existing = snapshots.first { $0.id == target.id }
        let snapshot = MatterEnergyDeviceSnapshot(
            id: target.id,
            accessoryUUIDs: target.accessoryUUIDs,
            accessoryName: target.accessoryName,
            manufacturer: target.manufacturer,
            source: .matter,
            nodeID: target.nodeID,
            powerEndpointID: target.powerEndpointID,
            energyEndpointID: target.energyEndpointID,
            activePowerWatts: activePowerWatts ?? existing?.activePowerWatts,
            cumulativeEnergyKilowattHours: cumulativeEnergyKilowattHours ?? existing?.cumulativeEnergyKilowattHours,
            measuredAt: Date(),
            powerLatencyMilliseconds: nil,
            energyLatencyMilliseconds: nil,
            powerStatus: powerStatus ?? existing?.powerStatus ?? "subscription pending",
            energyStatus: energyStatus ?? existing?.energyStatus ?? "subscription pending"
        )
        upsert(snapshot)
        lastRefresh = Date()
    }

    @MainActor
    private func upsert(_ snapshot: MatterEnergyDeviceSnapshot) {
        if let index = snapshots.firstIndex(where: { $0.id == snapshot.id }) {
            snapshots[index] = snapshot
        } else {
            snapshots.append(snapshot)
            snapshots.sort {
                $0.accessoryName.localizedCaseInsensitiveCompare($1.accessoryName) == .orderedAscending
            }
        }

        for accessoryUUID in snapshot.accessoryUUIDs {
            snapshotsByAccessoryUUID[accessoryUUID] = snapshot
        }
    }

}

@Observable
final class MatterEnergySubscriptionService {
    private static let subscriptionQueue = DispatchQueue(label: "HomeFloorplan.MatterEnergy.subscription", qos: .utility)

    private let provider = MatterEnergyProvider()
    private var handles: [MatterEnergySubscriptionHandle] = []
    private var generation = UUID()
    private(set) var isRunning: Bool = false
    private(set) var subscribedTargetCount: Int = 0
    private(set) var lastError: String?

    @MainActor
    func start(home: HMHome, liveStore: MatterEnergyLiveStore) async {
        guard !isRunning else {
            dprint("[MatterEnergySub] start skipped: already running targets=\(subscribedTargetCount)")
            return
        }
        isRunning = true
        lastError = nil
        generation = UUID()
        let currentGeneration = generation

        dprint("[MatterEnergySub] start home=\(home.name)")
        let targets = await provider.discoverMatterEnergyTargets(home: home)
        dprint("[MatterEnergySub] discovered targets=\(targets.count)")
        let controller = MTRDeviceController.sharedController(
            withID: home.matterControllerID as NSString,
            xpcConnect: home.matterControllerXPCConnectBlock
        )

        var newHandles: [MatterEnergySubscriptionHandle] = []
        for target in targets {
            dprint("[MatterEnergySub] target \(target.accessoryName) node=\(target.nodeIDText) powerEndpoint=\(target.powerEndpointText) energyEndpoint=\(target.energyEndpointText)")
            let device = MTRBaseDevice(nodeID: NSNumber(value: target.nodeID), controller: controller)
            let handle = MatterEnergySubscriptionHandle(target: target, device: device)

            if let powerEndpointID = target.powerEndpointID {
                subscribeActivePower(
                    device: device,
                    endpointID: powerEndpointID,
                    target: target,
                    liveStore: liveStore,
                    generation: currentGeneration
                )
                handle.hasPowerSubscription = true
            }

            if let energyEndpointID = target.energyEndpointID {
                subscribeCumulativeEnergy(
                    device: device,
                    endpointID: energyEndpointID,
                    target: target,
                    liveStore: liveStore,
                    generation: currentGeneration
                )
                handle.hasEnergySubscription = true
            }

            if handle.hasPowerSubscription || handle.hasEnergySubscription {
                newHandles.append(handle)
            }
        }

        handles = newHandles
        subscribedTargetCount = newHandles.count
        isRunning = !newHandles.isEmpty
        dprint("[MatterEnergySub] started handles=\(newHandles.count) running=\(isRunning)")
    }

    @MainActor
    func stop() {
        guard isRunning || !handles.isEmpty else { return }
        dprint("[MatterEnergySub] stop handles=\(handles.count)")
        generation = UUID()
        handles.removeAll()
        subscribedTargetCount = 0
        isRunning = false
    }

    private func subscribeActivePower(
        device: MTRBaseDevice,
        endpointID: UInt16,
        target: MatterEnergySubscriptionTarget,
        liveStore: MatterEnergyLiveStore,
        generation: UUID
    ) {
        device.subscribeToAttributes(
            withEndpointID: NSNumber(value: endpointID),
            clusterID: NSNumber(value: MTRClusterIDType.electricalPowerMeasurementID.rawValue),
            attributeID: NSNumber(value: MTRAttributeIDType.clusterElectricalPowerMeasurementAttributeActivePowerID.rawValue),
            params: subscribeParams(),
            queue: Self.subscriptionQueue
        ) { [weak self, weak liveStore] values, error in
            guard let self, let liveStore else { return }
            Task { @MainActor in
                guard self.generation == generation else {
                    dprint("[MatterEnergySub] \(target.accessoryName) power report ignored: stale generation")
                    return
                }
                if let error {
                    let detail = Self.describe(error)
                    dprint("[MatterEnergySub] \(target.accessoryName) power subscription error: \(detail)")
                    self.lastError = "\(target.accessoryName): power \(detail)"
                    liveStore.applyMatterSubscriptionUpdate(
                        target: target,
                        activePowerWatts: nil,
                        cumulativeEnergyKilowattHours: nil,
                        powerStatus: "subscription error",
                        energyStatus: nil
                    )
                    return
                }

                guard let milliwatts = Self.firstNumericValue(from: values) else {
                    dprint("[MatterEnergySub] \(target.accessoryName) power report had no numeric value values=\(values?.description ?? "nil")")
                    return
                }

                let watts = Double(truncating: milliwatts) / 1_000
                dprint("[MatterEnergySub] \(target.accessoryName) device power report raw=\(milliwatts) watts=\(String(format: "%.2f", watts))")
                liveStore.applyMatterSubscriptionUpdate(
                    target: target,
                    activePowerWatts: watts,
                    cumulativeEnergyKilowattHours: nil,
                    powerStatus: "subscribed",
                    energyStatus: nil
                )
            }
        } subscriptionEstablished: {
            dprint("[MatterEnergySub] \(target.accessoryName) device power subscription established endpoint=\(target.powerEndpointText)")
        }
    }

    private func subscribeCumulativeEnergy(
        device: MTRBaseDevice,
        endpointID: UInt16,
        target: MatterEnergySubscriptionTarget,
        liveStore: MatterEnergyLiveStore,
        generation: UUID
    ) {
        device.subscribeToAttributes(
            withEndpointID: NSNumber(value: endpointID),
            clusterID: NSNumber(value: MTRClusterIDType.electricalEnergyMeasurementID.rawValue),
            attributeID: NSNumber(value: MTRAttributeIDType.clusterElectricalEnergyMeasurementAttributeCumulativeEnergyImportedID.rawValue),
            params: subscribeParams(),
            queue: Self.subscriptionQueue
        ) { [weak self, weak liveStore] values, error in
            guard let self, let liveStore else { return }
            Task { @MainActor in
                guard self.generation == generation else {
                    dprint("[MatterEnergySub] \(target.accessoryName) energy report ignored: stale generation")
                    return
                }
                if let error {
                    let detail = Self.describe(error)
                    dprint("[MatterEnergySub] \(target.accessoryName) energy subscription error: \(detail)")
                    self.lastError = "\(target.accessoryName): energy \(detail)"
                    liveStore.applyMatterSubscriptionUpdate(
                        target: target,
                        activePowerWatts: nil,
                        cumulativeEnergyKilowattHours: nil,
                        powerStatus: nil,
                        energyStatus: "subscription error"
                    )
                    return
                }

                guard let microwattHours = Self.firstEnergyValue(from: values) else {
                    dprint("[MatterEnergySub] \(target.accessoryName) energy report had no energy value values=\(values?.description ?? "nil")")
                    return
                }

                let kilowattHours = Double(truncating: microwattHours) / 1_000_000
                dprint("[MatterEnergySub] \(target.accessoryName) device energy report raw=\(microwattHours) kWh=\(String(format: "%.4f", kilowattHours))")
                liveStore.applyMatterSubscriptionUpdate(
                    target: target,
                    activePowerWatts: nil,
                    cumulativeEnergyKilowattHours: kilowattHours,
                    powerStatus: nil,
                    energyStatus: "subscribed"
                )
            }
        } subscriptionEstablished: {
            dprint("[MatterEnergySub] \(target.accessoryName) device energy subscription established endpoint=\(target.energyEndpointText)")
        }
    }

    private func subscribeParams() -> MTRSubscribeParams {
        let params = MTRSubscribeParams(
            minInterval: NSNumber(value: 5),
            maxInterval: NSNumber(value: 5 * 60)
        )
        params.shouldResubscribeAutomatically = true
        params.shouldReplaceExistingSubscriptions = false
        params.shouldReportEventsUrgently = false
        return params
    }

    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)/\(nsError.code) \(nsError.localizedDescription)"
    }

    private static func firstNumericValue(from values: [[String: Any]]?) -> NSNumber? {
        values?.compactMap { response -> NSNumber? in
            guard response[MTRErrorKey] == nil,
                  let data = response[MTRDataKey] as? [String: Any] else {
                return nil
            }
            return data[MTRValueKey] as? NSNumber
        }.first
    }

    private static func firstEnergyValue(from values: [[String: Any]]?) -> NSNumber? {
        values?.compactMap { response -> NSNumber? in
            guard response[MTRErrorKey] == nil,
                  let data = response[MTRDataKey] as? [String: Any],
                  let fields = data[MTRValueKey] as? [[String: Any]] else {
                return nil
            }

            return fields.compactMap { field -> NSNumber? in
                guard let contextTag = field[MTRContextTagKey] as? NSNumber,
                      contextTag.uint8Value == 0,
                      let fieldData = field[MTRDataKey] as? [String: Any] else {
                    return nil
                }
                return fieldData[MTRValueKey] as? NSNumber
            }.first
        }.first
    }
}

private extension MatterEnergySubscriptionTarget {
    var nodeIDText: String {
        "0x" + String(format: "%016llX", nodeID)
    }

    var powerEndpointText: String {
        powerEndpointID.map(String.init) ?? "-"
    }

    var energyEndpointText: String {
        energyEndpointID.map(String.init) ?? "-"
    }
}

private final class MatterEnergySubscriptionHandle {
    let target: MatterEnergySubscriptionTarget
    let device: MTRBaseDevice
    var hasPowerSubscription = false
    var hasEnergySubscription = false

    init(target: MatterEnergySubscriptionTarget, device: MTRBaseDevice) {
        self.target = target
        self.device = device
    }
}
