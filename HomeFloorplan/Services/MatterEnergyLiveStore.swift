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
