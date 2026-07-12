import Foundation
import HomeKit
import Observation

@Observable
final class MatterEnergyLiveStore {
    private let provider = MatterEnergyProvider()

    private(set) var snapshots: [MatterEnergyDeviceSnapshot] = []
    private(set) var diagnostics: [String] = []
    private(set) var isRefreshing: Bool = false
    private(set) var lastRefresh: Date?

    func snapshot(for accessoryUUID: UUID) -> MatterEnergyDeviceSnapshot? {
        snapshots.first { snapshot in
            snapshot.accessoryUUIDs.contains(accessoryUUID)
        }
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
        diagnostics = report.diagnostics
        lastRefresh = Date()
    }

}
