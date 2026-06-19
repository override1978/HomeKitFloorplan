import SwiftUI
import HomeKit

/// Stile visuale del marker, indipendente dalla dimensione preferita dall'utente.
/// Indica solo "che forma deve avere".
enum MarkerStyle {
    /// Cerchio grande, per accessori controllabili (luci, prese, switch, ventilatori).
    case controllable
    /// Cerchio piccolo, per sensori booleani (contatto, movimento, fumo, ecc.).
    case sensorBoolean
    /// Pill larga con valore numerico (temperatura, umidità, ecc.).
    case sensorNumeric
    /// Rettangolo 16:9 con snapshot periodica (telecamere HomeKit).
    case camera
}

enum MarkerUrgency {
    case normal      // Marker neutro (grigio Material)
    case ok       // verde - stato "safe/protetto" (es. antifurto inserito)
    case active      // Stato "on" (giallo)
    case warning     // Attenzione (arancione) — es. movimento, porta aperta
    case alarm       // Allarme (rosso) — es. fumo, CO, perdita acqua
}

enum MarkerRuntimeState {
    case sensorTriggered
    case transitioning
    case unreachable

    var systemImage: String {
        switch self {
        case .sensorTriggered: return "dot.radiowaves.left.and.right"
        case .transitioning: return "arrow.triangle.2.circlepath"
        case .unreachable: return "wifi.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .sensorTriggered: return Color(.systemOrange)
        case .transitioning: return BrandColor.primary
        case .unreachable: return Color(.systemYellow)
        }
    }
}

@MainActor
protocol MarkerRuntimeStateProviding {
    var markerRuntimeState: MarkerRuntimeState? { get }
}

@MainActor
protocol AccessoryAdapter: AnyObject {
    var accessory: HMAccessory { get }
    var iconName: String { get }
    var isOn: Bool { get }
    var supportsQuickToggle: Bool { get }
    var primaryStatusText: String? { get }
    var markerStyle: MarkerStyle { get }
    var visualUrgency: MarkerUrgency { get }
    var markerTint: Color? { get }
    var batteryInfo: BatteryInfo? { get }
    
    /// True se questo adapter può essere piazzato come marker sul floorplan.
        /// Per pulsanti programmabili è false (sono read-only e non c'è nulla
        /// di utile da fare con un tap).
        var supportsFloorplanPlacement: Bool { get }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws
    
    var id: UUID { get }
    
        @MainActor
        func makeControlSection(homeKit: HomeKitService) -> AnyView?   // 👈 requisito obbligatorio

    
}

extension AccessoryAdapter {
    var id: UUID { accessory.uniqueIdentifier }
    var name: String { accessory.name }
    var isReachable: Bool { accessory.isReachable }
    var markerTint: Color? { nil }
}
