import HomeKit
import Observation
import SwiftUI

/// Modalità del purificatore (HAP TargetAirPurifierState).
enum AirPurifierMode: Int, CaseIterable, Identifiable {
    case manual = 0
    case auto = 1
    
    var id: Int { rawValue }
    
    var displayName: String {
        switch self {
        case .manual: return "Manuale"
        case .auto:   return "Auto"
        }
    }
    
    var symbolName: String {
        switch self {
        case .manual: return "hand.tap.fill"
        case .auto:   return "a.circle"
        }
    }
    
    var tintColor: Color {
        switch self {
        case .manual: return .orange
        case .auto:   return .green
        }
    }
}

/// Adapter per purificatori d'aria HomeKit (servizio AirPurifier `000000BB-...`).
/// Caratteristiche: Active, CurrentState, TargetState, RotationSpeed, FilterMaintenance.
/// Sensori integrati (qualità aria, PM2.5, temperatura, umidità) opzionali.
@MainActor
@Observable
final class AirPurifierAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let activeCharacteristic: HMCharacteristic
    private let currentStateCharacteristic: HMCharacteristic
    private let targetStateCharacteristic: HMCharacteristic
    private let rotationSpeedCharacteristic: HMCharacteristic?
    private let filterChangeCharacteristic: HMCharacteristic?
    private let filterLifeCharacteristic: HMCharacteristic?
    private let lockPhysicalControlsCharacteristic: HMCharacteristic?
    
    // Sensori integrati (opzionali)
    private let airQualityCharacteristic: HMCharacteristic?
    private let pm25Characteristic: HMCharacteristic?
    private let temperatureCharacteristic: HMCharacteristic?
    private let humidityCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        // Service AirPurifier required
        let purifierServiceUUID = "000000BB-0000-1000-8000-0026BB765291"
        guard accessory.services.contains(where: { $0.serviceType == purifierServiceUUID }) else {
            return nil
        }
        
        // Characteristic obbligatorie
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let currentStateUUID = "000000A9-0000-1000-8000-0026BB765291"
        let targetStateUUID = "000000A8-0000-1000-8000-0026BB765291"
        
        guard let active = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: activeUUID),
              let currentState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentStateUUID),
              let targetState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID)
        else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.activeCharacteristic = active
        self.currentStateCharacteristic = currentState
        self.targetStateCharacteristic = targetState
        
        // Opzionali
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"
        let filterChangeUUID = "000000AC-0000-1000-8000-0026BB765291"
        let filterLifeUUID = "000000AB-0000-1000-8000-0026BB765291"
        let lockUUID = "000000A7-0000-1000-8000-0026BB765291"
        let airQualityUUID = "00000095-0000-1000-8000-0026BB765291"
        let pm25UUID = "000000C6-0000-1000-8000-0026BB765291"
        let temperatureUUID = "00000011-0000-1000-8000-0026BB765291"
        let humidityUUID = "00000010-0000-1000-8000-0026BB765291"
        
        self.rotationSpeedCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: rotationSpeedUUID)
        self.filterChangeCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: filterChangeUUID)
        self.filterLifeCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: filterLifeUUID)
        self.lockPhysicalControlsCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: lockUUID)
        self.airQualityCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: airQualityUUID)
        self.pm25Characteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: pm25UUID)
        self.temperatureCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: temperatureUUID)
        self.humidityCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: humidityUUID)
    }
    
    // MARK: - AccessoryAdapter
    
    var iconName: String {
        isActive ? "air.purifier.fill" : "air.purifier"
    }
    
    var isOn: Bool { isActive }
    var supportsQuickToggle: Bool { true }
    
    var primaryStatusText: String? {
        guard isActive else { return nil }
        return currentMode.displayName
    }
    
    var markerStyle: MarkerStyle { .controllable }
    var visualUrgency: MarkerUrgency { isActive ? .active : .normal }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        try await homeKit.write(isActive ? 0 : 1, to: activeCharacteristic)
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(AirPurifierControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state
    
    var isActive: Bool {
        intValue(homeKit.value(for: activeCharacteristic) ?? activeCharacteristic.value) == 1
    }
    
    /// 0=inactive, 1=idle, 2=purifying
    var currentPurifierState: Int {
        intValue(homeKit.value(for: currentStateCharacteristic) ?? currentStateCharacteristic.value) ?? 0
    }
    
    var isPurifying: Bool { currentPurifierState == 2 }
    
    var currentMode: AirPurifierMode {
        let raw = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 0
        return AirPurifierMode(rawValue: raw) ?? .manual
    }
    
    // Ventola
    
    var hasRotationSpeed: Bool { rotationSpeedCharacteristic != nil }
    
    var rotationSpeed: Int {
        guard let c = rotationSpeedCharacteristic else { return 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    var rotationSpeedRange: ClosedRange<Int> {
        guard let c = rotationSpeedCharacteristic else { return 0...0 }
        let min = (c.metadata?.minimumValue as? NSNumber)?.intValue ?? 0
        let max = (c.metadata?.maximumValue as? NSNumber)?.intValue ?? 100
        return min...max
    }
    
    var rotationSpeedStep: Int {
        guard let c = rotationSpeedCharacteristic else { return 1 }
        return (c.metadata?.stepValue as? NSNumber)?.intValue ?? 1
    }
    
    // Filtro
    
    var hasFilter: Bool { filterLifeCharacteristic != nil || filterChangeCharacteristic != nil }
    
    /// Vita residua filtro (0-100). Nil se non disponibile.
    var filterLifeLevel: Int? {
        guard let c = filterLifeCharacteristic else { return nil }
        return intValue(homeKit.value(for: c) ?? c.value)
    }
    
    /// True se il purificatore segnala che il filtro va cambiato (FilterChangeIndication).
    var needsFilterChange: Bool {
        guard let c = filterChangeCharacteristic else { return false }
        return intValue(homeKit.value(for: c) ?? c.value) == 1
    }
    
    // Sensori integrati
    
    var hasAirQualitySensor: Bool { airQualityCharacteristic != nil }
    
    /// 0=unknown, 1=excellent, 2=good, 3=fair, 4=inferior, 5=poor
    var airQualityLevel: Int {
        guard let c = airQualityCharacteristic else { return 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    var airQualityLabel: String? {
        guard airQualityLevel > 0 else { return nil }
        switch airQualityLevel {
        case 1: return "Ottima"
        case 2: return "Buona"
        case 3: return "Media"
        case 4: return "Scarsa"
        case 5: return "Pessima"
        default: return nil
        }
    }
    
    var supportsFloorplanPlacement: Bool { true }
    
    var pm25Density: Double? {
        guard let c = pm25Characteristic else { return nil }
        return doubleValue(homeKit.value(for: c) ?? c.value)
    }
    
    var temperatureCelsius: Double? {
        guard let c = temperatureCharacteristic else { return nil }
        return doubleValue(homeKit.value(for: c) ?? c.value)
    }
    
    var humidityPercentage: Double? {
        guard let c = humidityCharacteristic else { return nil }
        return doubleValue(homeKit.value(for: c) ?? c.value)
    }
    
    // MARK: - Writes
    
    func setActive(_ on: Bool) async throws {
        try await homeKit.write(on ? 1 : 0, to: activeCharacteristic)
    }
    
    func setMode(_ mode: AirPurifierMode) async throws {
        if !isActive {
            try await homeKit.write(1, to: activeCharacteristic)
        }
        try await homeKit.write(mode.rawValue, to: targetStateCharacteristic)
    }
    
    func setRotationSpeed(_ value: Int) async throws {
        guard let c = rotationSpeedCharacteristic else { return }
        let r = rotationSpeedRange
        let clamped = Swift.min(Swift.max(value, r.lowerBound), r.upperBound)
        try await homeKit.write(clamped, to: c)
    }
    
    // MARK: - Helpers
    
    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let u = any as? UInt8 { return Int(u) }
        if let n = any as? NSNumber { return n.intValue }
        if let d = any as? Double { return Int(d) }
        return nil
    }
    
    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let f = any as? Float { return Double(f) }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return nil
    }
}
