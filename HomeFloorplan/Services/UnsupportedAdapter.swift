import HomeKit
import Observation
import SwiftUI

/// Adapter per accessori che non sappiamo (ancora) come gestire.
/// Mostra un'icona neutra, niente tap rapido, apre il pannello dei dettagli.
@MainActor
@Observable
final class UnsupportedAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    
    init(accessory: HMAccessory) {
        self.accessory = accessory
    }
    
    var markerStyle: MarkerStyle { .controllable }

    var visualUrgency: MarkerUrgency { .normal }
    
    var iconName: String {
        switch accessory.category.categoryType {
        case HMAccessoryCategoryTypeThermostat: return "thermometer"
        case HMAccessoryCategoryTypeSensor: return "sensor.fill"
        case HMAccessoryCategoryTypeDoorLock: return "lock.fill"
        case HMAccessoryCategoryTypeWindow,
             HMAccessoryCategoryTypeWindowCovering: return "blinds.horizontal.closed"
        case HMAccessoryCategoryTypeGarageDoorOpener: return "door.garage.closed"
        case HMAccessoryCategoryTypeIPCamera,
             HMAccessoryCategoryTypeVideoDoorbell: return "video.fill"
        case HMAccessoryCategoryTypeSecuritySystem: return "shield.fill"
        case HMAccessoryCategoryTypeSprinkler: return "drop.fill"
        default: return "questionmark.circle"
        }
    }
    
    var isOn: Bool { false }
    var supportsQuickToggle: Bool { false }
    var primaryStatusText: String? { nil }
    var supportsFloorplanPlacement: Bool { true }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        // Noop: questo adapter non supporta tap rapido
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? { nil }
    
    @MainActor
    var batteryInfo: BatteryInfo? { nil }
}

extension ThermostatAdapter: ThermostatControlling {}
