import HomeKit
import Observation
import SwiftUI

/// Adapter per termostati HomeKit che usano il **servizio Thermostat classico**
/// (`0000004A-...`), come molti Nest via Homebridge, Honeywell vecchi, alcuni Ecobee.
///
/// Differenze rispetto a HeaterCooler:
/// - On/Off è una modalità dentro `TargetHeatingCoolingState` (valore 0=Off)
///   invece di `Active` separato
/// - Solo `TargetTemperature` (un singolo valore) per Heat e Cool
/// - In Auto, opzionali `HeatingThreshold` e `CoolingThreshold` definiscono la banda
///
/// Mapping `TargetHeatingCoolingState` (HAP spec):
/// - 0 = Off, 1 = Heat, 2 = Cool, 3 = Auto
@MainActor
@Observable
final class LegacyThermostatAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let currentTempCharacteristic: HMCharacteristic
    private let targetTempCharacteristic: HMCharacteristic
    private let currentStateCharacteristic: HMCharacteristic?
    private let targetStateCharacteristic: HMCharacteristic
    private let heatingThresholdCharacteristic: HMCharacteristic?
    private let coolingThresholdCharacteristic: HMCharacteristic?
    private let lowBatteryCharacteristic: HMCharacteristic?
    
    static let autoBand: Double = 2.0
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        // UUID HAP spec
        let currentTempUUID = "00000011-0000-1000-8000-0026BB765291"
        let targetTempUUID = "00000035-0000-1000-8000-0026BB765291"
        let currentStateUUID = "0000000F-0000-1000-8000-0026BB765291"
        let targetStateUUID = "00000033-0000-1000-8000-0026BB765291"
        let heatingThresholdUUID = "00000012-0000-1000-8000-0026BB765291"
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let lowBatteryUUID = "00000079-0000-1000-8000-0026BB765291"
        
        guard let currentTemp = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentTempUUID),
              let targetTemp = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetTempUUID),
              let targetState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.currentTempCharacteristic = currentTemp
        self.targetTempCharacteristic = targetTemp
        self.targetStateCharacteristic = targetState
        self.currentStateCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentStateUUID)
        self.heatingThresholdCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: heatingThresholdUUID)
        self.coolingThresholdCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: coolingThresholdUUID)
        self.lowBatteryCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: lowBatteryUUID)
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        switch currentMode {
        case .off:  return "thermometer"
        case .auto: return "thermometer.variable.and.figure"
        case .heat: return "flame.fill"
        case .cool: return "snowflake"
        }
    }
    
    var isOn: Bool { currentMode != .off && (heaterCoolerState == 2 || heaterCoolerState == 3) }
    var supportsQuickToggle: Bool { accessory.isReachable }
    var primaryStatusText: String? {
        guard accessory.isReachable else { return nil }
        return String(format: "%.0f°", currentTemperature)
    }
    var markerStyle: MarkerStyle { .sensorNumeric }
    var visualUrgency: MarkerUrgency {
        guard currentMode != .off else { return .normal }
        return (heaterCoolerState == 2 || heaterCoolerState == 3) ? .active : .normal
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        try await setMode(currentMode == .off ? .auto : .off)
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(ThermostatControl(adapter: self))
    }
    
    // MARK: - State
    
    /// HAP TargetHeatingCoolingState: 0=Off, 1=Heat, 2=Cool, 3=Auto
    /// Converto nel nostro enum HeaterCoolerMode (off, auto, heat, cool)
    var currentMode: HeaterCoolerMode {
        let raw = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 0
        switch raw {
        case 0: return .off
        case 1: return .heat
        case 2: return .cool
        case 3: return .auto
        default: return .off
        }
    }
    
    var supportedModes: [HeaterCoolerMode] {
        let validRaw = targetStateCharacteristic.metadata?.validValues as? [NSNumber] ?? []
        var modes: [HeaterCoolerMode] = []
        // Ordine: Auto, Heat, Cool, Off
        if validRaw.contains(3) { modes.append(.auto) }
        if validRaw.contains(1) { modes.append(.heat) }
        if validRaw.contains(2) { modes.append(.cool) }
        // Fallback se validValues è vuoto: tutte le 3 modalità attive
        if modes.isEmpty {
            modes = [.auto, .heat, .cool]
        }
        modes.append(.off)
        return modes
    }
    
    var currentTemperature: Double {
        doubleValue(homeKit.value(for: currentTempCharacteristic) ?? currentTempCharacteristic.value) ?? 0
    }
    
    var displayTargetTemperature: Double {
        if currentMode == .auto, let h = heatingThresholdCharacteristic, let c = coolingThresholdCharacteristic {
            let hv = doubleValue(homeKit.value(for: h) ?? h.value) ?? 0
            let cv = doubleValue(homeKit.value(for: c) ?? c.value) ?? 0
            return (hv + cv) / 2
        }
        return doubleValue(homeKit.value(for: targetTempCharacteristic) ?? targetTempCharacteristic.value) ?? 0
    }
    
    var targetRange: ClosedRange<Double> {
        let min = (targetTempCharacteristic.metadata?.minimumValue as? NSNumber)?.doubleValue ?? 10
        let max = (targetTempCharacteristic.metadata?.maximumValue as? NSNumber)?.doubleValue ?? 38
        return min...max
    }
    
    var temperatureStep: Double {
        guard let step = (targetTempCharacteristic.metadata?.stepValue as? NSNumber)?.doubleValue,
              step > 0 else { return 0.5 }
        return Swift.max(step, 0.5)
    }
    
    /// 0=Inactive, 1=Heating, 2=Cooling (HAP spec).
    /// Convertiamo nello stesso significato di HeaterCooler (0=inactive, 1=idle, 2=heating, 3=cooling)
    /// per uniformare la UI.
    var heaterCoolerState: Int {
        guard let c = currentStateCharacteristic else { return 0 }
        let raw = intValue(homeKit.value(for: c) ?? c.value) ?? 0
        switch raw {
        case 1: return 2  // Heating attivo
        case 2: return 3  // Cooling attivo
        default: return 0
        }
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    var hasLowBattery: Bool {
        guard let c = lowBatteryCharacteristic else { return false }
        return intValue(homeKit.value(for: c) ?? c.value) == 1
    }
    
    // MARK: - Display units (riuso enum di ThermostatAdapter)
    
    var displayUnit: ThermostatAdapter.TemperatureUnit {
        let displayUnitsUUID = "00000036-0000-1000-8000-0026BB765291"
        guard let c = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: displayUnitsUUID) else {
            return .celsius
        }
        let raw = intValue(homeKit.value(for: c) ?? c.value) ?? 0
        return raw == 1 ? .fahrenheit : .celsius
    }
    
    func celsiusToDisplay(_ celsius: Double) -> Double {
        switch displayUnit {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9.0 / 5.0 + 32.0
        }
    }
    
    func displayToCelsius(_ display: Double) -> Double {
        switch displayUnit {
        case .celsius: return display
        case .fahrenheit: return (display - 32.0) * 5.0 / 9.0
        }
    }
    
    // MARK: - Rotation speed (non standard in Thermostat classico)
    
    var hasRotationSpeed: Bool { false }
    var rotationSpeed: Int { 0 }
    var rotationSpeedRange: ClosedRange<Int> { 0...0 }
    var rotationSpeedStep: Int { 1 }
    func setRotationSpeed(_ value: Int) async throws {}
    
    // MARK: - Writes
    
    /// Mappa il nostro enum sul TargetHeatingCoolingState HAP.
    func setMode(_ mode: HeaterCoolerMode) async throws {
        let raw: Int
        switch mode {
        case .off:  raw = 0
        case .heat: raw = 1
        case .cool: raw = 2
        case .auto: raw = 3
        }
        try await homeKit.write(raw, to: targetStateCharacteristic)
    }
    
    func setTargetTemperature(_ value: Double) async throws {
        let range = targetRange
        let clamped = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        let step = temperatureStep
        let snapped = (clamped / step).rounded() * step
        
        switch currentMode {
        case .auto:
            // Se ci sono entrambi i threshold, scrivi banda ±autoBand;
            // altrimenti aggiorna solo TargetTemperature
            if let h = heatingThresholdCharacteristic, let c = coolingThresholdCharacteristic {
                let hv = Swift.max(range.lowerBound, snapped - Self.autoBand)
                let cv = Swift.min(range.upperBound, snapped + Self.autoBand)
                try await homeKit.write(hv, to: h)
                try await homeKit.write(cv, to: c)
            }
            try await homeKit.write(snapped, to: targetTempCharacteristic)
        default:
            try await homeKit.write(snapped, to: targetTempCharacteristic)
        }
    }
    
    // MARK: - Helpers
    
    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let f = any as? Float { return Double(f) }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
    
    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let u = any as? UInt8 { return Int(u) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}

extension LegacyThermostatAdapter: ThermostatControlling {}
