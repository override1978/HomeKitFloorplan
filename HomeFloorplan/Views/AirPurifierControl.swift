import SwiftUI
import HomeKit

/// Controllo Apple-Home-style per purificatore d'aria.
/// Bottone tondo on/off + pillole modalità (Manuale/Auto) + slider ventola a tacche +
/// stato filtro + sezione ambiente (qualità aria, PM2.5, temperatura, umidità).
struct AirPurifierControl: View {
    let adapter: AirPurifierAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    
    @State private var optimisticFan: Int?
    @State private var optimisticMode: AirPurifierMode?
    @State private var writeError = false

    private let buttonDiameter: CGFloat = 80
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }
    
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var isActive: Bool { adapter.isActive }
    private var currentMode: AirPurifierMode { optimisticMode ?? adapter.currentMode }
    private var displayedFan: Int { optimisticFan ?? adapter.rotationSpeed }
    
    var body: some View {
        VStack(spacing: 20) {
            toggleButton
            modePillsRow
            if adapter.hasRotationSpeed && currentMode == .manual {
                fanSliderRow
            }
            if adapter.hasFilter {
                filterRow
            }
            
            environmentSection
            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onChange(of: adapter.currentMode) { _, _ in optimisticMode = nil }
        .onChange(of: adapter.rotationSpeed) { _, _ in optimisticFan = nil }
    }
    
    // MARK: - Toggle Button
    
    private var toggleButton: some View {
        VStack(spacing: 8) {
            Button(action: handleToggleTap) {
                ZStack {
                    Circle()
                        .fill(toggleFill)
                        .frame(width: buttonDiameter, height: buttonDiameter)
                    
                    AccessoryIconView(iconName: iconName)
                        .foregroundStyle(toggleIconColor)
                        .frame(width: buttonDiameter * 0.45,
                               height: buttonDiameter * 0.45)
                }
                .shadow(color: .black.opacity(isActive ? 0.22 : 0.12),
                        radius: isActive ? 6 : 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isActive)
            
            Text(stateLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
    
    private var toggleFill: AnyShapeStyle {
        if !isReachable { return AnyShapeStyle(.thinMaterial) }
        return isActive
            ? AnyShapeStyle(Color.yellow.opacity(0.9))
            : AnyShapeStyle(.thinMaterial)
    }
    
    private var toggleIconColor: Color {
        if !isReachable { return .secondary }
        return isActive ? .white : .primary
    }
    
    private var stateLabel: String {
        if !isReachable { return String(localized: "accessory.unreachable", defaultValue: "Non raggiungibile") }
        if !isActive { return String(localized: "accessory.state.off", defaultValue: "Spento") }
        return adapter.isPurifying
            ? String(localized: "airpurifier.state.purifying", defaultValue: "Sta purificando")
            : String(localized: "airpurifier.state.idle", defaultValue: "In attesa")
    }
    
    // MARK: - Mode pills
    
    private var modePillsRow: some View {
        HStack(spacing: 8) {
            ForEach(AirPurifierMode.allCases) { m in
                modePill(m)
            }
        }
        .padding(.horizontal, 4)
    }
    
    private func modePill(_ m: AirPurifierMode) -> some View {
        let isSelected = m == currentMode
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
        .disabled(!isReachable || !isActive)
        .opacity((isReachable && isActive) ? 1.0 : 0.5)
        .animation(.spring(response: 0.3), value: isSelected)
    }
    
    // MARK: - Fan slider (a tacche)
    
    private var fanSliderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(.secondary)
                Text(String(localized: "thermostat.fan", defaultValue: "Ventola"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(fanLabel(for: displayedFan))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            fanTicks
        }
        .padding(.horizontal, 4)
        .opacity(isReachable && isActive ? 1.0 : 0.4)
    }
    
    private var fanTicks: some View {
        let range = adapter.rotationSpeedRange
        let stepValue = max(adapter.rotationSpeedStep, 1)
        let levels = Array(stride(from: range.lowerBound, through: range.upperBound, by: stepValue))
        let current = displayedFan
        
        return HStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                fanTickButton(level: level,
                              isActive: level <= current && current > range.lowerBound,
                              isSelected: level == current)
            }
        }
    }
    
    private func fanTickButton(level: Int, isActive: Bool, isSelected: Bool) -> some View {
        Button {
            selectFan(level)
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
        .disabled(!isReachable || !self.isActive)
    }
    
    private func tickFill(isActive: Bool, isSelected: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor) }
        if isActive { return AnyShapeStyle(Color.accentColor.opacity(0.5)) }
        return AnyShapeStyle(.thinMaterial)
    }
    
    private func fanLabel(for level: Int) -> String {
        if level == 0 { return String(localized: "airpurifier.fan.off", defaultValue: "Spenta") }
        return "\(level)%"
    }
    
    private func fanShortLabel(for level: Int) -> String {
        if level == 0 { return "0" }
        return "\(level)"
    }
    
    // MARK: - Filter
    
    private var filterRow: some View {
        let needsChange = adapter.needsFilterChange
        let life = adapter.filterLifeLevel ?? 100
        let critical = needsChange || life <= 10
        let warning = !critical && life <= 30
        let color: Color = critical ? .red : (warning ? .orange : .green)
        let text: String = {
            if needsChange { return String(localized: "airpurifier.filter.replace", defaultValue: "Sostituire filtro") }
            return "\(String(localized: "airpurifier.filter.life", defaultValue: "Vita filtro")): \(life)%"
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "air.purifier")
                    .foregroundStyle(color)
                Text(String(localized: "airpurifier.filter.label", defaultValue: "Filtro"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(text)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            ProgressView(value: Double(life), total: 100)
                .tint(color)
        }
        .padding(.horizontal, 4)
    }
    
    // MARK: - Environment info
    
    private var hasEnvironmentInfo: Bool {
        adapter.hasAirQualitySensor
            || adapter.pm25Density != nil
            || adapter.temperatureCelsius != nil
            || adapter.humidityPercentage != nil
    }
    
    private var environmentSection: some View {
        EnvironmentInfoSection(
            airQuality: adapter.airQualityLabel,
            pm25: adapter.pm25Density,
            temperatureC: adapter.temperatureCelsius,
            humidity: adapter.humidityPercentage
        )
    }
    
    // MARK: - Actions

    private func triggerWriteError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.25)) { writeError = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) { writeError = false }
        }
    }

    private func handleToggleTap() {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setActive(!isActive)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func selectMode(_ m: AirPurifierMode) {
        guard m != currentMode else { return }
        optimisticMode = m
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setMode(m)
            } catch {
                optimisticMode = nil
                triggerWriteError()
            }
        }
    }

    private func selectFan(_ level: Int) {
        guard level != displayedFan else { return }
        optimisticFan = level
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setRotationSpeed(level)
            } catch {
                optimisticFan = nil
                triggerWriteError()
            }
        }
    }
}
