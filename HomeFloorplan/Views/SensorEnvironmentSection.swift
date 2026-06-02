import SwiftUI

/// Sezione "centrale" per sensori HomeKit nella DetailView.
/// Si adatta dinamicamente al tipo di sensore:
/// - Sensori booleani (porta/perdita/fumo/CO/movimento): icona grande + label
/// - Sensori numerici singoli (umidità sola, lux solo): valore gigante
/// - Multi-sensori (qualità aria IKEA con CO2/PM2.5/temp): solo chip ambiente
struct SensorEnvironmentSection: View {
    let adapter: SensorAdapter
    
    @State private var pulse: Bool = false
    
    private var readingsCount: Int {
        [
            adapter.environmentAirQuality != nil,
            adapter.environmentPM25 != nil,
            adapter.environmentPM10 != nil,
            adapter.environmentTemperature != nil,
            adapter.environmentHumidity != nil,
            adapter.environmentLightLevel != nil,
            adapter.environmentCO2 != nil,
            adapter.environmentVOC != nil
        ].filter { $0 }.count
    }
    
    /// Layout principale.
    var body: some View {
        VStack(spacing: 14) {
            if let bool = booleanState {
                booleanDisplay(bool)
            } else if readingsCount <= 1 {
                primaryReading
            }
            
            EnvironmentInfoSection(
                airQuality: adapter.environmentAirQuality,
                pm25: adapter.environmentPM25,
                pm10: adapter.environmentPM10,
                temperatureC: adapter.environmentTemperature,
                humidity: adapter.environmentHumidity,
                lightLevel: adapter.environmentLightLevel,
                co2: adapter.environmentCO2,
                voc: adapter.environmentVOC
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            if booleanState?.isAlarm == true { startPulse() }
        }
        .onChange(of: booleanState?.isAlarm ?? false) { _, isAlarm in
            if isAlarm { startPulse() } else { pulse = false }
        }
    }
    
    // MARK: - Big primary (per sensori numerici 0 o 1 reading)
    
    @ViewBuilder
    private var primaryReading: some View {
        if let primary = adapter.primaryStatusText, !primary.isEmpty {
            Text(primary)
                .font(.system(size: 64, weight: .light, design: .rounded))
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
    }
    
    // MARK: - Boolean state display
    
    private func booleanDisplay(_ state: BooleanSensorState) -> some View {
        let appearance = AccessoryAppearance.from(adapter)
        
        return VStack(spacing: 10) {
            Image(systemName: state.symbolName)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(state.isAlarm
                                 ? AnyShapeStyle(Color.red.opacity(pulse ? 1.0 : 0.65))
                                 : AnyShapeStyle(appearance.statusColor))
                .animation(state.isAlarm
                           ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                           : .default,
                           value: pulse)
            Text(state.label)
                .font(.title3.weight(.semibold))
                .foregroundStyle(state.isAlarm ? .red : appearance.statusColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    /// Determina lo stato booleano in base alla tipologia di sensore primario.
    private var booleanState: BooleanSensorState? {
        BooleanSensorState.from(adapter: adapter)
    }
    
    private func startPulse() {
        pulse = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pulse = true
        }
    }
}

// MARK: - Mapping sensore boolean → display

/// Rappresenta lo stato di un sensore booleano: icona, label, e isAlarm.
struct BooleanSensorState {
    let symbolName: String
    let label: String
    let isAlarm: Bool
    
    @MainActor
    static func from(adapter: SensorAdapter) -> BooleanSensorState? {
        // Smoke
        if let s = adapter.smokeDetected {
            return s
                ? BooleanSensorState(symbolName: "smoke.fill",
                                     label: String(localized: "sensor.smoke.detected",    defaultValue: "Fumo rilevato"),
                                     isAlarm: true)
                : BooleanSensorState(symbolName: "smoke",
                                     label: String(localized: "sensor.smoke.clear",       defaultValue: "Nessun fumo"),
                                     isAlarm: false)
        }
        // Carbon Monoxide
        if let s = adapter.carbonMonoxideDetected {
            return s
                ? BooleanSensorState(symbolName: "exclamationmark.triangle.fill",
                                     label: String(localized: "sensor.co.detected",       defaultValue: "CO rilevato"),
                                     isAlarm: true)
                : BooleanSensorState(symbolName: "checkmark.shield",
                                     label: String(localized: "sensor.co.clear",          defaultValue: "Aria sicura"),
                                     isAlarm: false)
        }
        // Leak
        if let s = adapter.leakDetected {
            return s
                ? BooleanSensorState(symbolName: "drop.fill",
                                     label: String(localized: "sensor.leak.detected",     defaultValue: "Perdita rilevata"),
                                     isAlarm: true)
                : BooleanSensorState(symbolName: "drop",
                                     label: String(localized: "sensor.leak.clear",        defaultValue: "Asciutto"),
                                     isAlarm: false)
        }
        // Contact
        if let s = adapter.contactDetected {
            return s
                ? BooleanSensorState(symbolName: "door.left.hand.open",
                                     label: String(localized: "sensor.contact.open",      defaultValue: "Aperta"),
                                     isAlarm: false)
                : BooleanSensorState(symbolName: "door.left.hand.closed",
                                     label: String(localized: "sensor.contact.closed",    defaultValue: "Chiusa"),
                                     isAlarm: false)
        }
        // Motion
        if let s = adapter.motionDetected {
            return s
                ? BooleanSensorState(symbolName: "figure.walk.motion",
                                     label: String(localized: "sensor.motion.detected",   defaultValue: "Movimento rilevato"),
                                     isAlarm: false)
                : BooleanSensorState(symbolName: "figure.stand",
                                     label: String(localized: "sensor.motion.clear",      defaultValue: "Nessun movimento"),
                                     isAlarm: false)
        }
        // Occupancy
        if let s = adapter.occupancyDetected {
            return s
                ? BooleanSensorState(symbolName: "person.fill",
                                     label: String(localized: "sensor.occupancy.detected",defaultValue: "Presenza rilevata"),
                                     isAlarm: false)
                : BooleanSensorState(symbolName: "person",
                                     label: String(localized: "sensor.occupancy.clear",   defaultValue: "Nessuna presenza"),
                                     isAlarm: false)
        }
        return nil
    }
}
