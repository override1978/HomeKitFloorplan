import Foundation
import HomeKit

/// Protocollo di astrazione per i due tipi di termostato:
/// - `ThermostatAdapter` (servizio HeaterCooler moderno, `000000BC-...`)
/// - `LegacyThermostatAdapter` (servizio Thermostat classico, `0000004A-...`)
///
/// La UI `ThermostatControl` lavora su questo protocollo, ignorando il
/// servizio HomeKit sottostante.
@MainActor
protocol ThermostatControlling: AnyObject {
    var accessory: HMAccessory { get }
    
    // Stato corrente
    var currentMode: HeaterCoolerMode { get }
    var supportedModes: [HeaterCoolerMode] { get }
    var currentTemperature: Double { get }
    var displayTargetTemperature: Double { get }
    var targetRange: ClosedRange<Double> { get }
    var temperatureStep: Double { get }
    
    // Stato secondario
    var heaterCoolerState: Int { get }   // 0=inactive, 1=idle, 2=heating, 3=cooling
    var hasLowBattery: Bool { get }
    
    /// Umidità relativa ambientale (se l'accessorio espone un servizio HumiditySensor).
     var environmentHumidity: Double? { get }
    
    // Unità
    var displayUnit: ThermostatAdapter.DisplayUnit { get }
    func celsiusToDisplay(_ celsius: Double) -> Double
    func displayToCelsius(_ display: Double) -> Double
    
    // Ventola (opzionale)
    var hasRotationSpeed: Bool { get }
    var rotationSpeed: Int { get }
    var rotationSpeedRange: ClosedRange<Int> { get }
    var rotationSpeedStep: Int { get }
    func setRotationSpeed(_ value: Int) async throws
    
    // Writes
    func setMode(_ mode: HeaterCoolerMode) async throws
    func setTargetTemperature(_ value: Double) async throws
}
