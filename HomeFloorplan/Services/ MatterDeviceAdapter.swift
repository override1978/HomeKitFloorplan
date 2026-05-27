import HomeKit
import SwiftUI

/// Adapter per dispositivi Matter "opachi", che HomeKit espone come categoria generica
/// senza nessun servizio HMService accessibile dal framework pubblico.
///
/// Caso tipico: **robot vacuum Matter** (Dreame, Ecovacs, Roborock).
/// Apple gestisce i cluster RVC (Run Mode, Clean Mode, Operational State) solo
/// internamente all'app Casa, via API private. Le app di terze parti non possono
/// né leggerne lo stato né comandarli.
///
/// Firma di riconoscimento (sperimentale, su iPadOS 26):
/// 1. `category.categoryType == "0FBA259B-05AC-46F2-875F-204ABB6D9FE7"` (categoria Matter generica)
/// 2. `services.isEmpty == true` (nessun servizio esposto)
///
/// Il punto 1 da solo non basta: la stessa categoria è usata anche per luci, prese,
/// sensori e tende Matter, ma quelli hanno servizi accessibili.
///
/// Il punto 2 da solo nemmeno: in teoria potrebbero esistere altri device Matter
/// non gestiti da HomeKit con zero servizi (es. future lavatrici, frigoriferi).
/// Per ora trattiamo qualsiasi Matter opaco come robot vacuum, e in futuro
/// potremo discriminare se Apple esporrà più informazioni.
final class MatterDeviceAdapter: AccessoryAdapter {
    
    private static let opaqueMatterCategoryUUID = "0FBA259B-05AC-46F2-875F-204ABB6D9FE7"
    
    let accessory: HMAccessory
    
    init?(accessory: HMAccessory) {
        let isOpaqueMatter = accessory.category.categoryType
            .caseInsensitiveCompare(Self.opaqueMatterCategoryUUID) == .orderedSame
        guard isOpaqueMatter, accessory.services.isEmpty else {
            return nil
        }
        self.accessory = accessory
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? { nil }
    
    @MainActor
    var batteryInfo: BatteryInfo? { nil }
    
    var supportsFloorplanPlacement: Bool { true }
    
    var iconName: String { "arrow.triangle.2.circlepath.circle.fill" }
    var isOn: Bool { false }
    var supportsQuickToggle: Bool { false }
    var primaryStatusText: String? { "Robot" }
    var markerStyle: MarkerStyle { .controllable }
    var visualUrgency: MarkerUrgency { .normal }
    
    func performQuickToggle(via homeKit: HomeKitService) async {
        // No-op: nessuna characteristic scrivibile esposta al framework pubblico.
    }
}
