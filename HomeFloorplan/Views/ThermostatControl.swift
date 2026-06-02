import SwiftUI
import HomeKit

/// Controllo Apple-Home-style per termostati e condizionatori (servizio HeaterCooler).
/// Mostra:
/// - Temperatura target grande (si adatta alla modalità)
/// - Temperatura corrente piccola sotto
/// - Stepper ±0.5°C
/// - Pillole modalità affiancate (Auto / Caldo / Freddo / Spento)
/// - Status line (Sta riscaldando / Sta raffreddando / Inattivo / Spento)
/// - Indicatore batteria scarica (se rilevato)
struct ThermostatControl: View {
    let adapter: ThermostatControlling
    
    @Environment(HomeKitService.self) private var homeKit
    
    /// Target ottimistico durante l'interazione (per UI reattiva), in Celsius (come l'adapter).
    @State private var optimisticTarget: Double?
    @State private var optimisticFan: Int?

    /// Target in unità di display (°C o °F).
    private var displayTarget: Double {
        adapter.celsiusToDisplay(optimisticTarget ?? adapter.displayTargetTemperature)
    }
    
    private var mode: HeaterCoolerMode { adapter.currentMode }
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var canEditTemperature: Bool { isReachable && mode != .off }
    
    var body: some View {
        VStack(spacing: 22) {
            targetDisplay
            stepperRow
            modePillsRow
            if adapter.hasRotationSpeed {
                        fanSliderRow
                    }
            statusLine
            
            EnvironmentInfoSection(
                        humidity: adapter.environmentHumidity
                    )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onChange(of: adapter.displayTargetTemperature) { _, newValue in
            // optimisticTarget è in Celsius: confronta con il nuovo valore Celsius dall'adapter
            if let optimistic = optimisticTarget,
               abs(newValue - optimistic) < 0.05 {
                optimisticTarget = nil
            }
        }
        .onChange(of: adapter.rotationSpeed) { _, newValue in
                if let optimistic = optimisticFan, newValue == optimistic {
                    optimisticFan = nil
                }
            }
    }
    
    // MARK: - Target grande
    
    private var targetDisplay: some View {
        VStack(spacing: 4) {
            Text(formatted(displayTarget))
                .font(.system(size: 72, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(targetColor)
            
            Text("\(String(localized: "thermostat.now", defaultValue: "Ora")) \(formatted(adapter.celsiusToDisplay(adapter.currentTemperature)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
    
    private var targetColor: Color {
        if !isReachable || mode == .off { return .secondary }
        switch adapter.heaterCoolerState {
        case 2: return .orange   // heating
        case 3: return .blue     // cooling
        default: return .primary
        }
    }
    
    // MARK: - Stepper ± 0.5°C
    
    private var stepperRow: some View {
        HStack(spacing: 36) {
            stepperButton(systemImage: "minus", delta: -1)
            stepperButton(systemImage: "plus", delta: +1)
        }
    }
    
    private func stepperButton(systemImage: String, delta: Double) -> some View {
        Button {
            adjustTarget(by: delta)
        } label: {
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .frame(width: 56, height: 56)
                Image(systemName: systemImage)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canEditTemperature)
        .opacity(canEditTemperature ? 1.0 : 0.4)
    }
    
    // MARK: - Pillole modalità
    
    private var modePillsRow: some View {
        HStack(spacing: 8) {
            ForEach(adapter.supportedModes) { m in
                modePill(m)
            }
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Fan slider (discreto)

    private var displayedFanLevel: Int {
        optimisticFan ?? adapter.rotationSpeed
    }

    private var fanSliderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(.secondary)
                Text(String(localized: "thermostat.fan", defaultValue: "Ventola"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(fanLabel(for: displayedFanLevel))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            
            fanTicks
        }
        .padding(.horizontal, 4)
        .opacity(canControlFan ? 1.0 : 0.4)
    }

    private var canControlFan: Bool {
        isReachable && mode != .off
    }

    private var fanTicks: some View {
        let range = adapter.rotationSpeedRange
        let stepValue = adapter.rotationSpeedStep
        let levels = Array(stride(from: range.lowerBound, through: range.upperBound, by: stepValue))
        let current = displayedFanLevel
        
        return HStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                fanTickButton(level: level, isActive: level <= current && current > range.lowerBound,
                              isSelected: level == current)
            }
        }
    }

    private func fanTickButton(level: Int, isActive: Bool, isSelected: Bool) -> some View {
        Button {
            selectFan(level: level)
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tickFill(isActive: isActive, isSelected: isSelected))
                    .frame(height: 28)
                
                Text(fanShortLabel(for: level))
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!canControlFan)
    }

    private func tickFill(isActive: Bool, isSelected: Bool) -> AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor)
        }
        if isActive {
            return AnyShapeStyle(Color.accentColor.opacity(0.5))
        }
        return AnyShapeStyle(.thinMaterial)
    }

    private func fanLabel(for level: Int) -> String {
        if level == adapter.rotationSpeedRange.lowerBound {
            return String(localized: "thermostat.mode.auto", defaultValue: "Auto")
        }
        return String(format: String(localized: "thermostat.fan.level", defaultValue: "Livello %d"), level)
    }

    private func fanShortLabel(for level: Int) -> String {
        if level == adapter.rotationSpeedRange.lowerBound { return "A" }
        return "\(level)"
    }

    private func selectFan(level: Int) {
        guard level != displayedFanLevel else { return }
        optimisticFan = level
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setRotationSpeed(level)
            } catch {
                optimisticFan = nil
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
    
    private func modePill(_ m: HeaterCoolerMode) -> some View {
        let isSelected = m == mode
        return Button {
            selectMode(m)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: m.symbolName)
                    .font(.title3)
                Text(m.displayName)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : m.tintColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(m.tintColor)
                          : AnyShapeStyle(.thinMaterial))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
        .animation(.spring(response: 0.3), value: isSelected)
    }
    
    // MARK: - Status line
    
    private var statusLine: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                Text(statusText)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            
            if adapter.hasLowBattery {
                HStack(spacing: 4) {
                    Image(systemName: "battery.25percent")
                    Text(String(localized: "accessory.battery.low", defaultValue: "Batteria"))
                }
                .font(.subheadline)
                .foregroundStyle(.red)
            }
        }
    }
    
    private var statusText: String {
        if !isReachable { return String(localized: "accessory.unreachable",       defaultValue: "Non raggiungibile") }
        if mode == .off  { return String(localized: "thermostat.mode.off",        defaultValue: "Spento") }
        switch adapter.heaterCoolerState {
        case 2: return String(localized: "thermostat.status.heating", defaultValue: "Sta riscaldando")
        case 3: return String(localized: "thermostat.status.cooling", defaultValue: "Sta raffreddando")
        default: return String(localized: "thermostat.status.idle",   defaultValue: "Temperatura raggiunta")
        }
    }
    
    private var statusIcon: String {
        if !isReachable { return "wifi.slash" }
        if mode == .off { return "power" }
        switch adapter.heaterCoolerState {
        case 2: return "flame.fill"
        case 3: return "snowflake"
        default: return "checkmark.circle"
        }
    }
    
    // MARK: - Actions
    
    private func adjustTarget(by delta: Double) {
        let step = adapter.temperatureStep
        let direction = delta > 0 ? 1.0 : -1.0
        // Lavora in unità display per lo step visivo
        let rawDisplay = displayTarget + (step * direction)
        let snappedDisplay = (rawDisplay / step).rounded() * step
        // Riconverti in Celsius per il range e la scrittura su HomeKit
        let snappedCelsius = adapter.displayToCelsius(snappedDisplay)
        let range = adapter.targetRange
        let clampedCelsius = min(max(snappedCelsius, range.lowerBound), range.upperBound)
        guard abs(clampedCelsius - (optimisticTarget ?? adapter.displayTargetTemperature)) > 0.01 else { return }

        optimisticTarget = clampedCelsius  // sempre in Celsius
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()

        Task {
            do {
                try await adapter.setTargetTemperature(clampedCelsius)
            } catch {
                optimisticTarget = nil
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
    
    private func selectMode(_ m: HeaterCoolerMode) {
        guard m != mode else { return }
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        Task {
            try? await adapter.setMode(m)
        }
    }
    
    // MARK: - Format

    /// Formatta un valore già convertito in unità display, aggiungendo il simbolo corretto.
    private func formatted(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        let symbol = adapter.displayUnit.symbol
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f%@", rounded, symbol)
        } else {
            return String(format: "%.1f%@", rounded, symbol)
        }
    }
}
