import HomeKit
import Observation
import SwiftUI

/// Adapter per coperture finestre HomeKit (tende, tapparelle, veneziane).
/// Caratteristiche HomeKit principali:
/// - TargetPosition (0-100%): dove la copertura deve andare
/// - CurrentPosition (0-100%): dove è ora
/// - PositionState: decreasing/increasing/stopped
///
/// Tap rapido: toggle full-open (100%) vs full-close (0%).
/// Long press apre il pannello (futuro: slider posizione 0-100%).
@MainActor
@Observable
final class WindowCoveringAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    private let targetPositionCharacteristic: HMCharacteristic?
    private let currentPositionCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        self.accessory = accessory
        self.homeKit = homeKit
        
        let target = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeTargetPosition
        )
        let current = AccessoryAdapterFactory.findCharacteristic(
            in: accessory, type: HMCharacteristicTypeCurrentPosition
        )
        
        guard target != nil || current != nil else { return nil }
        
        self.targetPositionCharacteristic = target
        self.currentPositionCharacteristic = current
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        let pos = currentPosition
        // Position 0 = chiusa, 100 = completamente aperta
        if pos >= 90 {
            return "blinds.horizontal.open"
        } else if pos <= 10 {
            return "blinds.horizontal.closed"
        } else {
            // Posizione intermedia
            return "blinds.horizontal.open"
        }
    }
    
    /// Per le tende "isOn" significa "aperta" (anche solo parzialmente).
    var isOn: Bool {
        currentPosition > 10
    }
    
    var supportsQuickToggle: Bool {
        targetPositionCharacteristic != nil && accessory.isReachable
    }
    
    var primaryStatusText: String? {
        nil  // Mostra l'icona, non il valore numerico (nel marker resta cerchio grande)
    }
    
    var markerStyle: MarkerStyle { .controllable }
    
    var visualUrgency: MarkerUrgency {
        // Aperta = "active" (gialla); chiusa = "normal" (grigia)
        isOn ? .active : .normal
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        guard let target = targetPositionCharacteristic else { return }
        let newValue: Int = isOn ? 0 : 100
        try await homeKit.write(newValue, to: target)
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        guard targetPositionCharacteristic != nil else { return nil }
        return AnyView(WindowCoveringControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state for control views
        
    /// Posizione corrente fisica (0-100). Letta da CurrentPosition o fallback Target.
    var currentPositionValue: Int {
        let source = currentPositionCharacteristic ?? targetPositionCharacteristic
        guard let c = source else { return 0 }
        let raw = homeKit.value(for: c) ?? c.value
        return Self.intValue(raw) ?? 0
    }

    /// Posizione di destinazione (0-100). Quella verso cui la tenda si sta muovendo.
    var targetPositionValue: Int {
        guard let c = targetPositionCharacteristic else { return currentPositionValue }
        let raw = homeKit.value(for: c) ?? c.value
        return Self.intValue(raw) ?? currentPositionValue
    }

    /// Scrive direttamente una posizione (0-100).
    func setPosition(_ value: Int) async throws {
        guard let target = targetPositionCharacteristic else { return }
        let clamped = max(0, min(100, value))
        try await homeKit.write(clamped, to: target)
    }

    // MARK: - Private helpers

    /// Posizione attuale (0-100). Alias privato usato da isOn/iconName.
    private var currentPosition: Int { currentPositionValue }

    private static func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let u = raw as? UInt8 { return Int(u) }
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        return nil
    }
}
