import Foundation
import HomeKit

struct FloorplanRuntimeContextController {
    let floorplan: Floorplan
    let homeKit: HomeKitService
    let isAIEnabled: Bool
    let pendingPatternCount: Int

    func overlayContext() -> FloorplanOverlayContext {
        FloorplanOverlayContext(
            hasEnvironmentData: !floorplan.linkedRooms.isEmpty,
            hasSecurityDevices: hasSecurityDevices,
            hasAIService: isAIEnabled,
            hasIntelligenceSuggestions: isAIEnabled && pendingPatternCount > 0
        )
    }

    func securityAdapter() -> SecuritySystemAdapter? {
        guard let home = homeKit.currentHome else { return nil }
        for accessory in home.accessories {
            if let adapter = AccessoryAdapterFactory.adapter(for: accessory, homeKit: homeKit) as? SecuritySystemAdapter {
                return adapter
            }
        }
        return nil
    }

    func updatedSecurityActivationDate(
        previousRawMode: Int,
        currentActivationDate: TimeInterval,
        now: Date = .now
    ) -> (rawMode: Int, activationDate: TimeInterval)? {
        guard let adapter = securityAdapter() else { return nil }

        let rawMode = adapter.currentMode.rawValue
        guard rawMode != previousRawMode else {
            return (rawMode: previousRawMode, activationDate: currentActivationDate)
        }

        return (rawMode: rawMode, activationDate: now.timeIntervalSince1970)
    }

    private var hasSecurityDevices: Bool {
        homeKit.allAccessories.contains { accessory in
            if accessory.category.categoryType == HMAccessoryCategoryTypeIPCamera ||
                accessory.category.categoryType == HMAccessoryCategoryTypeVideoDoorbell {
                return true
            }

            return accessory.services.contains { service in
                service.serviceType == HMServiceTypeLockMechanism
                    || service.serviceType == HMServiceTypeSecuritySystem
                    || service.serviceType == HMServiceTypeGarageDoorOpener
                    || service.serviceType == HMServiceTypeDoorbell
                    || service.serviceType == HMServiceTypeContactSensor
            }
        }
    }
}
