import HomeKit

// MARK: - EnvironmentReadable

/// Protocollo per qualsiasi accessorio HomeKit che espone letture ambientali numeriche.
/// Implementato da SensorAdapter, ThermostatAdapter e LegacyThermostatAdapter.
@MainActor
protocol EnvironmentReadable: AnyObject {
    /// Accessorio HomeKit sottostante (per ricavare nome stanza).
    var accessory: HMAccessory { get }

    // MARK: Metriche numeriche (nil se l'accessorio non espone la caratteristica)
    var environmentTemperature: Double? { get }
    var environmentHumidity:    Double? { get }
    var environmentCO2:         Double? { get }
    var environmentPM25:        Double? { get }
    var environmentPM10:        Double? { get }
    var environmentVOC:         Double? { get }
    var environmentAirQuality:  String? { get }
    var environmentLightLevel:  Int?    { get }
}
