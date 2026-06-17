import HomeKit
import Observation
import SwiftUI

/// Modalità supportate da TargetHeaterCoolerState.
/// I valori interi corrispondono alla spec HAP HomeKit.
enum HeaterCoolerMode: Int, CaseIterable, Identifiable {
    case off = -1     // Active = 0 (non è un valore di TargetHeaterCoolerState ma uno stato Active)
    case auto = 0
    case heat = 1
    case cool = 2
    
    var id: Int { rawValue }
    
    var displayName: String {
        switch self {
        case .off:  return String(localized: "thermostat.mode.off",  defaultValue: "Spento")
        case .auto: return String(localized: "thermostat.mode.auto", defaultValue: "Auto")
        case .heat: return String(localized: "thermostat.mode.heat", defaultValue: "Caldo")
        case .cool: return String(localized: "thermostat.mode.cool", defaultValue: "Freddo")
        }
    }
    
    var symbolName: String {
        switch self {
        case .off:  return "power"
        case .auto: return "a.circle"
        case .heat: return "flame.fill"
        case .cool: return "snowflake"
        }
    }
    
    var tintColor: Color {
        switch self {
        case .off:  return .secondary
        case .auto: return .green
        case .heat: return .orange
        case .cool: return .blue
        }
    }
}

/// Adapter per termostati e condizionatori HomeKit che usano il servizio
/// **HeaterCooler** (`000000BC-...`). Si adatta dinamicamente alle modalità
/// supportate dall'accessorio leggendo `validValues` da TargetHeaterCoolerState.
@MainActor
@Observable
final class ThermostatAdapter: AccessoryAdapter {
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let activeCharacteristic: HMCharacteristic
    private let targetStateCharacteristic: HMCharacteristic
    private let currentTempCharacteristic: HMCharacteristic
    private let heatingTargetCharacteristic: HMCharacteristic?
    private let coolingTargetCharacteristic: HMCharacteristic?
    private let currentStateCharacteristic: HMCharacteristic?
    private let lowBatteryCharacteristic: HMCharacteristic?
    private let rotationSpeedCharacteristic: HMCharacteristic?
    private let humidityCharacteristic: HMCharacteristic?
    
    
    /// Banda intorno al target in modalità Auto. Quando l'utente imposta T,
    /// noi scriviamo HeatingThreshold = T - autoBand e CoolingThreshold = T + autoBand.
    static let autoBand: Double = 2.0
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        // UUID HAP standard
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let targetStateUUID = "000000B2-0000-1000-8000-0026BB765291"
        let currentTempUUID = "00000011-0000-1000-8000-0026BB765291"
        let heatingThresholdUUID = "00000012-0000-1000-8000-0026BB765291"
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let currentStateUUID = "000000B1-0000-1000-8000-0026BB765291"
        let lowBatteryUUID = "00000079-0000-1000-8000-0026BB765291"
        let rotationSpeedUUID = "00000029-0000-1000-8000-0026BB765291"
        let humidityUUID = "00000010-0000-1000-8000-0026BB765291"
        
        guard let active = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: activeUUID),
              let targetState = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: targetStateUUID),
              let currentTemp = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentTempUUID)
        else { return nil }
        
        let heating = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: heatingThresholdUUID)
        let cooling = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: coolingThresholdUUID)
        guard heating != nil || cooling != nil else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.activeCharacteristic = active
        self.targetStateCharacteristic = targetState
        self.currentTempCharacteristic = currentTemp
        self.heatingTargetCharacteristic = heating
        self.coolingTargetCharacteristic = cooling
        self.currentStateCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: currentStateUUID)
        self.lowBatteryCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: lowBatteryUUID)
        self.rotationSpeedCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: rotationSpeedUUID)
        self.humidityCharacteristic = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: humidityUUID)
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
    
    /// Step di temperatura dichiarato dall'accessorio (di solito 0.5 o 1°C).
    /// Fallback: 0.5°C.
    /// Step UI di temperatura. Legge il metadata della characteristic ma applica
    /// un floor a 0.5°C per evitare step troppo fini (es. Tado dichiara step=0.1
    /// ma uno stepper UI a 0.1°C è frustrante da usare).
    var temperatureStep: Double {
        let source = heatingTargetCharacteristic ?? coolingTargetCharacteristic
        guard let s = source,
              let step = (s.metadata?.stepValue as? NSNumber)?.doubleValue,
              step > 0
        else { return 0.5 }
        return max(step, 0.5)   // 👈 modifica qui
    }
    
    // MARK: - Display units

    enum DisplayUnit {
        case celsius, fahrenheit
        var symbol: String {
            switch self {
            case .celsius: return "°C"
            case .fahrenheit: return "°F"
            }
        }
    }

    /// Unità preferita di display.
    /// Legge la preferenza utente da UserDefaults (chiave "temperatureUnit", impostabile
    /// in Impostazioni → Ambiente). Fallback: controlla la characteristic HomeKit UUID 00000036.
    var displayUnit: DisplayUnit {
        // Legge la preferenza utente (impostata in Impostazioni → Ambiente).
        let saved = UserDefaults.standard.string(forKey: TemperatureUnit.appStorageKey) ?? ""
        if let pref = TemperatureUnit(rawValue: saved) {
            return pref == .fahrenheit ? .fahrenheit : .celsius
        }
        // Fallback: caratteristica HomeKit TemperatureDisplayUnits (UUID 00000036)
        let displayUnitsUUID = "00000036-0000-1000-8000-0026BB765291"
        if let c = AccessoryAdapterFactory.findCharacteristic(in: accessory, type: displayUnitsUUID) {
            let raw = intValue(homeKit.value(for: c) ?? c.value) ?? 0
            return raw == 1 ? .fahrenheit : .celsius
        }
        return .celsius
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
    
    var isOn: Bool { currentMode != .off && isHeatingOrCoolingActive }
    
    var supportsQuickToggle: Bool { false }
    
    var supportsFloorplanPlacement: Bool { true }
    
    var primaryStatusText: String? {
        guard homeKit.isReachable(accessory) else { return nil }
        let display = celsiusToDisplay(currentTemperature)
        return String(format: "%.0f%@", display, displayUnit.symbol)
    }
    
    var markerStyle: MarkerStyle { .sensorNumeric }
    
    var visualUrgency: MarkerUrgency {
        guard currentMode != .off else { return .normal }
        switch heaterCoolerState {
        case 2, 3: return .active   // heating o cooling attivo
        default: return .normal
        }
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        try await setMode(currentMode == .off ? .auto : .off)
    }
    
    @MainActor
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(ThermostatControl(adapter: self))
    }
    
    @MainActor
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    // MARK: - Public state for control view
    
    /// Modalità correntemente in HomeKit.
    var currentMode: HeaterCoolerMode {
        guard isActive else { return .off }
        let target = intValue(homeKit.value(for: targetStateCharacteristic) ?? targetStateCharacteristic.value) ?? 0
        return HeaterCoolerMode(rawValue: target) ?? .auto
    }
    
    /// Modalità supportate dall'accessorio (in base a validValues di TargetHeaterCoolerState),
    /// ordinate Auto / Caldo / Freddo / Spento. "Spento" è sempre incluso (è sempre possibile).
    var supportedModes: [HeaterCoolerMode] {
        let validRaw = targetStateCharacteristic.metadata?.validValues as? [NSNumber] ?? []
        var modes: [HeaterCoolerMode] = []
        // Ordine: Auto, Caldo, Freddo, Spento
        if validRaw.contains(0) { modes.append(.auto) }
        if validRaw.contains(1), heatingTargetCharacteristic != nil { modes.append(.heat) }
        if validRaw.contains(2), coolingTargetCharacteristic != nil { modes.append(.cool) }
        // Fallback: se validValues è vuoto, deduce dalle characteristic presenti
        if modes.isEmpty {
            if heatingTargetCharacteristic != nil && coolingTargetCharacteristic != nil {
                modes.append(.auto)
            }
            if heatingTargetCharacteristic != nil { modes.append(.heat) }
            if coolingTargetCharacteristic != nil { modes.append(.cool) }
        }
        modes.append(.off)
        return modes
    }
    
    var currentTemperature: Double {
        doubleValue(homeKit.value(for: currentTempCharacteristic) ?? currentTempCharacteristic.value) ?? 0
    }
    
    /// Target "logico" mostrato all'utente. Si adatta alla modalità:
    /// - Heat: HeatingThreshold
    /// - Cool: CoolingThreshold
    /// - Auto: media tra Heating e Cooling (centro della banda)
    /// - Off: ultima T conosciuta
    var displayTargetTemperature: Double {
        switch currentMode {
        case .heat:
            return heatingValue
        case .cool:
            return coolingValue
        case .auto:
            return (heatingValue + coolingValue) / 2
        case .off:
            // Mostriamo l'ultima T impostata (preferiamo Heating se esiste)
            return heatingTargetCharacteristic != nil ? heatingValue : coolingValue
        }
    }
    
    private var heatingValue: Double {
        guard let c = heatingTargetCharacteristic else { return 0 }
        return doubleValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    private var coolingValue: Double {
        guard let c = coolingTargetCharacteristic else { return 0 }
        return doubleValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    /// Range valido del target. Usa quello della characteristic di modalità corrente.
    var targetRange: ClosedRange<Double> {
        let source: HMCharacteristic? = {
            switch currentMode {
            case .cool: return coolingTargetCharacteristic ?? heatingTargetCharacteristic
            default:    return heatingTargetCharacteristic ?? coolingTargetCharacteristic
            }
        }()
        guard let s = source else { return 5...30 }
        let min = (s.metadata?.minimumValue as? NSNumber)?.doubleValue ?? 5
        let max = (s.metadata?.maximumValue as? NSNumber)?.doubleValue ?? 30
        return min...max
    }
    
    var isActive: Bool {
        intValue(homeKit.value(for: activeCharacteristic) ?? activeCharacteristic.value) == 1
    }
    
    /// 0=inactive, 1=idle, 2=heating, 3=cooling
    var heaterCoolerState: Int {
        guard let c = currentStateCharacteristic else { return 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    var isHeatingOrCoolingActive: Bool {
        heaterCoolerState == 2 || heaterCoolerState == 3
    }
    
    var hasLowBattery: Bool {
        guard let c = lowBatteryCharacteristic else { return false }
        return intValue(homeKit.value(for: c) ?? c.value) == 1
    }
    
    var environmentHumidity: Double? {
        guard let c = humidityCharacteristic else { return nil }
        let raw = homeKit.value(for: c) ?? c.value
        if let d = raw as? Double { return d }
        if let f = raw as? Float { return Double(f) }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }
    
    // MARK: - Rotation speed (ventola AC)

    /// True se l'accessorio espone una characteristic RotationSpeed.
    var hasRotationSpeed: Bool {
        rotationSpeedCharacteristic != nil
    }

    /// Valore corrente della velocità ventola, come Int (sempre intero per UI).
    var rotationSpeed: Int {
        guard let c = rotationSpeedCharacteristic else { return 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }

    /// Range valido di RotationSpeed (es. 0...5 per AC discreti, 0...100 per continui).
    var rotationSpeedRange: ClosedRange<Int> {
        guard let c = rotationSpeedCharacteristic else { return 0...0 }
        let min = (c.metadata?.minimumValue as? NSNumber)?.intValue ?? 0
        let max = (c.metadata?.maximumValue as? NSNumber)?.intValue ?? 100
        return min...max
    }

    /// Step dichiarato (di solito 1 per AC discreti).
    var rotationSpeedStep: Int {
        guard let c = rotationSpeedCharacteristic else { return 1 }
        return (c.metadata?.stepValue as? NSNumber)?.intValue ?? 1
    }

    /// Scrive la velocità ventola.
    func setRotationSpeed(_ value: Int) async throws {
        guard let c = rotationSpeedCharacteristic else { return }
        let range = rotationSpeedRange
        let clamped = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        try await homeKit.write(clamped, to: c)
    }
    
    // MARK: - Writes
    
    /// Imposta la modalità. Gestisce Active + TargetHeaterCoolerState.
    func setMode(_ mode: HeaterCoolerMode) async throws {
        if mode == .off {
            try await homeKit.write(0, to: activeCharacteristic)  // Active = 0
            return
        }
        // Assicurati che sia attivo
        if !isActive {
            try await homeKit.write(1, to: activeCharacteristic)
        }
        try await homeKit.write(mode.rawValue, to: targetStateCharacteristic)
    }
    
    /// Imposta la temperatura target. Si adatta alla modalità corrente:
    /// - Heat: scrive su HeatingThreshold
    /// - Cool: scrive su CoolingThreshold
    /// - Auto: scrive Heating = T - autoBand, Cooling = T + autoBand
    /// - Off: scrive comunque su Heating (se presente) per memorizzare il valore
    func setTargetTemperature(_ value: Double) async throws {
        let range = targetRange
        let clamped = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        let snapped = (clamped * 2).rounded() / 2  // step 0.5
        
        switch currentMode {
        case .heat, .off:
            if let c = heatingTargetCharacteristic {
                try await homeKit.write(snapped, to: c)
            }
        case .cool:
            if let c = coolingTargetCharacteristic {
                try await homeKit.write(snapped, to: c)
            }
        case .auto:
            let heatingValue = Swift.max(range.lowerBound, snapped - Self.autoBand)
            let coolingValue = Swift.min(range.upperBound, snapped + Self.autoBand)
            if let h = heatingTargetCharacteristic {
                try await homeKit.write(heatingValue, to: h)
            }
            if let c = coolingTargetCharacteristic {
                try await homeKit.write(coolingValue, to: c)
            }
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

// MARK: - EnvironmentReadable

extension ThermostatAdapter: EnvironmentReadable {
    var environmentTemperature: Double? { currentTemperature }
    var environmentCO2:         Double? { nil }
    var environmentPM25:        Double? { nil }
    var environmentPM10:        Double? { nil }
    var environmentVOC:         Double? { nil }
    var environmentAirQuality:  String? { nil }
    var environmentLightLevel:  Int?    { nil }
}
