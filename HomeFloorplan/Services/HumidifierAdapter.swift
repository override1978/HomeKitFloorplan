import HomeKit
import Observation
import SwiftUI

enum HumidifierMode: Int, CaseIterable, Identifiable {
    case auto = 0
    case humidify = 1
    case dehumidify = 2
    
    var id: Int { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return String(localized: "humidifier.mode.auto", defaultValue: "Auto")
        case .humidify: return String(localized: "humidifier.mode.humidify", defaultValue: "Umidifica")
        case .dehumidify: return String(localized: "humidifier.mode.dehumidify", defaultValue: "Deumidifica")
        }
    }
    
    var symbolName: String {
        switch self {
        case .auto: return "a.circle"
        case .humidify: return "humidity.fill"
        case .dehumidify: return "drop.triangle.fill"
        }
    }
    
    var tintColor: Color {
        switch self {
        case .auto: return .green
        case .humidify: return .cyan
        case .dehumidify: return .orange
        }
    }
}

@MainActor
@Observable
final class HumidifierAdapter: AccessoryAdapter {
    static let serviceType = "000000BD-0000-1000-8000-0026BB765291"
    
    private static let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
    private static let currentStateUUID = "000000B3-0000-1000-8000-0026BB765291"
    private static let targetStateUUID = "000000B4-0000-1000-8000-0026BB765291"
    private static let currentHumidityUUID = "00000010-0000-1000-8000-0026BB765291"
    private static let humidifierThresholdUUID = "000000CA-0000-1000-8000-0026BB765291"
    private static let dehumidifierThresholdUUID = "000000C9-0000-1000-8000-0026BB765291"
    private static let waterLevelUUID = "000000B5-0000-1000-8000-0026BB765291"
    private static let lightServiceType = "00000043-0000-1000-8000-0026BB765291"
    private static let brightnessUUID = "00000008-0000-1000-8000-0026BB765291"
    private static let powerUUID = "00000025-0000-1000-8000-0026BB765291"
    
    let accessory: HMAccessory
    private let homeKit: HomeKitService
    
    private let service: HMService
    private let activeCharacteristic: HMCharacteristic
    private let currentStateCharacteristic: HMCharacteristic?
    private let targetStateCharacteristic: HMCharacteristic?
    private let currentHumidityCharacteristic: HMCharacteristic?
    private let humidifierThresholdCharacteristic: HMCharacteristic?
    private let dehumidifierThresholdCharacteristic: HMCharacteristic?
    private let waterLevelCharacteristic: HMCharacteristic?
    private let lightPowerCharacteristic: HMCharacteristic?
    private let lightBrightnessCharacteristic: HMCharacteristic?
    
    init?(accessory: HMAccessory, homeKit: HomeKitService) {
        guard let service = accessory.services.first(where: { $0.serviceType == Self.serviceType }),
              let active = service.characteristics.first(where: { $0.characteristicType == Self.activeUUID })
        else { return nil }
        
        self.accessory = accessory
        self.homeKit = homeKit
        self.service = service
        self.activeCharacteristic = active
        self.currentStateCharacteristic = Self.characteristic(Self.currentStateUUID, in: service)
        self.targetStateCharacteristic = Self.characteristic(Self.targetStateUUID, in: service)
        self.currentHumidityCharacteristic = Self.characteristic(Self.currentHumidityUUID, in: service)
        self.humidifierThresholdCharacteristic = Self.characteristic(Self.humidifierThresholdUUID, in: service)
        self.dehumidifierThresholdCharacteristic = Self.characteristic(Self.dehumidifierThresholdUUID, in: service)
        self.waterLevelCharacteristic = Self.characteristic(Self.waterLevelUUID, in: service)
        
        let lightService = accessory.services.first { $0.serviceType == Self.lightServiceType }
        self.lightPowerCharacteristic = lightService.flatMap { Self.characteristic(Self.powerUUID, in: $0) }
        self.lightBrightnessCharacteristic = lightService.flatMap { Self.characteristic(Self.brightnessUUID, in: $0) }
    }
    
    var iconName: String {
        isActive ? "humidifier.fill" : "humidifier"
    }
    
    var isOn: Bool { isActive }
    var supportsQuickToggle: Bool { false }
    var markerStyle: MarkerStyle { .controllable }
    var markerTint: Color? {
        guard isActive else { return nil }
        switch currentState {
        case 3: return .orange
        case 2: return .cyan
        default: return currentMode.tintColor
        }
    }
    var visualUrgency: MarkerUrgency { isActive ? .active : .normal }
    var supportsFloorplanPlacement: Bool { true }
    
    var primaryStatusText: String? {
        if let humidity = currentHumidity {
            return "\(Int(humidity.rounded()))%"
        }
        return isActive ? currentStateLabel : nil
    }
    
    var batteryInfo: BatteryInfo? {
        BatteryReader.read(from: accessory, via: homeKit)
    }
    
    func performQuickToggle(via homeKit: HomeKitService) async throws {
        try await setActive(!isActive)
    }
    
    func makeControlSection(homeKit: HomeKitService) -> AnyView? {
        AnyView(HumidifierControl(adapter: self))
    }
    
    var isActive: Bool {
        intValue(homeKit.value(for: activeCharacteristic) ?? activeCharacteristic.value) == 1
    }
    
    var currentState: Int {
        guard let c = currentStateCharacteristic else { return isActive ? 1 : 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    var currentStateLabel: String {
        switch currentState {
        case 0: return String(localized: "humidifier.state.inactive", defaultValue: "Spento")
        case 1: return String(localized: "humidifier.state.idle", defaultValue: "In attesa")
        case 2: return String(localized: "humidifier.state.humidifying", defaultValue: "Sta umidificando")
        case 3: return String(localized: "humidifier.state.dehumidifying", defaultValue: "Sta deumidificando")
        default: return String(localized: "humidifier.state.unknown", defaultValue: "Stato sconosciuto")
        }
    }
    
    var currentMode: HumidifierMode {
        guard let c = targetStateCharacteristic else { return .humidify }
        let raw = intValue(homeKit.value(for: c) ?? c.value) ?? HumidifierMode.humidify.rawValue
        return HumidifierMode(rawValue: raw) ?? .humidify
    }
    
    var supportedModes: [HumidifierMode] {
        guard let c = targetStateCharacteristic else { return [] }
        if let validRaw = c.metadata?.validValues as? [NSNumber], !validRaw.isEmpty {
            return HumidifierMode.allCases.filter { mode in
                validRaw.contains(NSNumber(value: mode.rawValue))
            }
        }
        let min = (c.metadata?.minimumValue as? NSNumber)?.intValue
        let max = (c.metadata?.maximumValue as? NSNumber)?.intValue
        if let min, let max, min <= max {
            return HumidifierMode.allCases.filter { min...max ~= $0.rawValue }
        }
        return [.auto, .humidify, .dehumidify]
    }
    
    var currentHumidity: Double? {
        guard let c = currentHumidityCharacteristic else { return nil }
        return doubleValue(homeKit.value(for: c) ?? c.value)
    }
    
    var targetHumidity: Double? {
        guard let c = targetThresholdCharacteristic else { return nil }
        return doubleValue(homeKit.value(for: c) ?? c.value)
    }
    
    var targetHumidityRange: ClosedRange<Double> {
        guard let c = targetThresholdCharacteristic else { return 0...100 }
        let min = (c.metadata?.minimumValue as? NSNumber)?.doubleValue ?? 0
        let max = (c.metadata?.maximumValue as? NSNumber)?.doubleValue ?? 100
        return min...max
    }
    
    var targetHumidityStep: Double {
        guard let c = targetThresholdCharacteristic else { return 1 }
        let step = (c.metadata?.stepValue as? NSNumber)?.doubleValue ?? 1
        return max(step, 1)
    }
    
    var waterLevel: Double? {
        guard let c = waterLevelCharacteristic else { return nil }
        return doubleValue(homeKit.value(for: c) ?? c.value)
    }
    
    var hasSecondaryLight: Bool {
        lightPowerCharacteristic != nil || lightBrightnessCharacteristic != nil
    }
    
    var canSetLightBrightness: Bool {
        lightBrightnessCharacteristic?.properties.contains(HMCharacteristicPropertyWritable) == true
    }
    
    var isLightOn: Bool {
        if let c = lightPowerCharacteristic {
            let raw = homeKit.value(for: c) ?? c.value
            if let b = raw as? Bool { return b }
            if let n = raw as? NSNumber { return n.boolValue }
            if let i = raw as? Int { return i != 0 }
        }
        return lightBrightness > 0
    }
    
    var lightBrightness: Int {
        guard let c = lightBrightnessCharacteristic else { return isLightOn ? 100 : 0 }
        return intValue(homeKit.value(for: c) ?? c.value) ?? 0
    }
    
    var canSetTargetHumidity: Bool {
        targetThresholdCharacteristic?.properties.contains(HMCharacteristicPropertyWritable) == true
    }
    
    func setActive(_ on: Bool) async throws {
        try await homeKit.write(on ? 1 : 0, to: activeCharacteristic)
    }
    
    func setMode(_ mode: HumidifierMode) async throws {
        guard let c = targetStateCharacteristic else { return }
        if !isActive {
            try await homeKit.write(1, to: activeCharacteristic)
        }
        try await homeKit.write(mode.rawValue, to: c)
    }
    
    func setTargetHumidity(_ value: Double) async throws {
        guard let c = targetThresholdCharacteristic else { return }
        let range = targetHumidityRange
        let clamped = Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
        let step = targetHumidityStep
        let snapped = (clamped / step).rounded() * step
        if !isActive {
            try await homeKit.write(1, to: activeCharacteristic)
        }
        try await homeKit.write(snapped, to: c)
    }
    
    func setLightOn(_ on: Bool) async throws {
        if let c = lightPowerCharacteristic {
            try await homeKit.write(on, to: c)
        } else if let c = lightBrightnessCharacteristic {
            try await homeKit.write(on ? max(lightBrightness, 100) : 0, to: c)
        }
    }
    
    func setLightBrightness(_ value: Int) async throws {
        guard let c = lightBrightnessCharacteristic else { return }
        let clamped = max(0, min(100, value))
        if clamped == 0 {
            try await setLightOn(false)
            return
        }
        if clamped > 0, !isLightOn {
            try await setLightOn(true)
        }
        try await homeKit.write(clamped, to: c)
    }
    
    private var targetThresholdCharacteristic: HMCharacteristic? {
        switch currentMode {
        case .dehumidify:
            return dehumidifierThresholdCharacteristic ?? humidifierThresholdCharacteristic
        default:
            return humidifierThresholdCharacteristic ?? dehumidifierThresholdCharacteristic
        }
    }
    
    private static func characteristic(_ type: String, in service: HMService) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == type }
    }
    
    private func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let u = raw as? UInt8 { return Int(u) }
        if let n = raw as? NSNumber { return n.intValue }
        if let d = raw as? Double { return Int(d) }
        return nil
    }
    
    private func doubleValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let f = raw as? Float { return Double(f) }
        if let i = raw as? Int { return Double(i) }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }
}

extension HumidifierAdapter: EnvironmentReadable {
    var environmentTemperature: Double? { nil }
    var environmentHumidity: Double? { currentHumidity }
    var environmentCO2: Double? { nil }
    var environmentPM25: Double? { nil }
    var environmentPM10: Double? { nil }
    var environmentVOC: Double? { nil }
    var environmentAirQuality: String? { nil }
    var environmentLightLevel: Int? { nil }
}

private struct HumidifierControl: View {
    let adapter: HumidifierAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    
    @State private var optimisticMode: HumidifierMode?
    @State private var optimisticTarget: Double?
    @State private var humiditySliderDraft: Double = 0
    @State private var isDraggingHumidity = false
    @State private var lightSliderDraft: Double = 0
    @State private var isDraggingLight = false
    @State private var writeError = false
    
    private let buttonDiameter: CGFloat = 80
    private let sliderHeight: CGFloat = 60
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }
    
    private var isReachable: Bool { homeKit.isReachable(adapter.accessory) }
    private var isActive: Bool { adapter.isActive }
    private var currentMode: HumidifierMode { optimisticMode ?? adapter.currentMode }
    private var targetHumidity: Double? { optimisticTarget ?? adapter.targetHumidity }
    
    var body: some View {
        VStack(spacing: 20) {
            toggleButton
            if adapter.supportedModes.count > 1 {
                modePillsRow
            }
            humiditySection
            if let waterLevel = adapter.waterLevel {
                waterLevelRow(waterLevel)
            }
            if adapter.hasSecondaryLight {
                lightSection
            }
            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            humiditySliderDraft = adapter.targetHumidity ?? 0
            lightSliderDraft = Double(adapter.lightBrightness)
        }
        .onChange(of: adapter.currentMode) { _, _ in optimisticMode = nil }
        .onChange(of: adapter.targetHumidity) { _, _ in optimisticTarget = nil }
        .onChange(of: adapter.targetHumidity) { _, newValue in
            if !isDraggingHumidity, let newValue {
                humiditySliderDraft = newValue
            }
        }
        .onChange(of: adapter.lightBrightness) { _, newValue in
            if !isDraggingLight {
                lightSliderDraft = Double(newValue)
            }
        }
    }
    
    private var toggleButton: some View {
        VStack(spacing: 8) {
            Button(action: handleToggleTap) {
                ZStack {
                    Circle()
                        .fill(toggleFill)
                        .frame(width: buttonDiameter, height: buttonDiameter)
                    
                    AccessoryIconView(iconName: iconName)
                        .foregroundStyle(toggleIconColor)
                        .frame(width: buttonDiameter * 0.45, height: buttonDiameter * 0.45)
                }
                .shadow(color: .black.opacity(isActive ? 0.22 : 0.12),
                        radius: isActive ? 6 : 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            
            Text(stateLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
    
    private var toggleFill: AnyShapeStyle {
        if !isReachable { return AnyShapeStyle(.thinMaterial) }
        return isActive ? AnyShapeStyle(Color.cyan.opacity(0.9)) : AnyShapeStyle(.thinMaterial)
    }
    
    private var toggleIconColor: Color {
        if !isReachable { return .secondary }
        return isActive ? .white : .primary
    }
    
    private var stateLabel: String {
        if !isReachable {
            return String(localized: "accessory.unreachable", defaultValue: "Non raggiungibile")
        }
        return adapter.currentStateLabel
    }
    
    private var modePillsRow: some View {
        HStack(spacing: 8) {
            ForEach(adapter.supportedModes) { mode in
                modePill(mode)
            }
        }
        .padding(.horizontal, 4)
    }
    
    private func modePill(_ mode: HumidifierMode) -> some View {
        let isSelected = mode == currentMode
        return Button {
            selectMode(mode)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: mode.symbolName)
                    .font(.title3)
                Text(mode.displayName)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : mode.tintColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(mode.tintColor) : AnyShapeStyle(.thinMaterial))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isReachable || !isActive)
        .opacity((isReachable && isActive) ? 1.0 : 0.5)
    }
    
    private var humiditySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "humidity.fill")
                    .foregroundStyle(.cyan)
                Text(String(localized: "humidifier.humidity.current", defaultValue: "Umidità"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let humidity = adapter.currentHumidity {
                    Text("\(Int(humidity.rounded()))%")
                        .font(.subheadline.weight(.semibold))
                        .contentTransition(.numericText())
                }
            }
            
            if adapter.canSetTargetHumidity, let targetHumidity {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "humidifier.humidity.target", defaultValue: "Soglia"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(targetHumidity.rounded()))%")
                            .font(.subheadline.weight(.semibold))
                    }
                    humidityThresholdSlider(currentValue: targetHumidity)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
    }
    
    private func waterLevelRow(_ waterLevel: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "drop.fill")
                    .foregroundStyle(.blue)
                Text(String(localized: "humidifier.waterLevel", defaultValue: "Livello acqua"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(waterLevel.rounded()))%")
                    .font(.subheadline.weight(.semibold))
            }
            ProgressView(value: waterLevel, total: 100)
                .tint(.blue)
        }
        .padding(.horizontal, 4)
    }
    
    private func humidityThresholdSlider(currentValue: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let range = adapter.targetHumidityRange
                let span = max(range.upperBound - range.lowerBound, 1)
                let normalized = (humiditySliderDraft - range.lowerBound) / span
                let fillWidth = geo.size.width * CGFloat(min(1, max(0, normalized)))
                
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                    
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.cyan.opacity(0.85))
                        .frame(width: max(0, fillWidth))
                        .animation(isDraggingHumidity ? nil : .spring(response: 0.4), value: fillWidth)
                    
                    HStack {
                        Spacer()
                        Text("\(Int((isDraggingHumidity ? humiditySliderDraft : currentValue).rounded()))%")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(sliderTextColor(fillWidth: fillWidth, totalWidth: geo.size.width))
                            .contentTransition(.numericText())
                        Spacer()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isReachable else { return }
                            isDraggingHumidity = true
                            let pct = min(1, max(0, value.location.x / geo.size.width))
                            let raw = range.lowerBound + Double(pct) * span
                            humiditySliderDraft = snappedHumidity(raw)
                            optimisticTarget = humiditySliderDraft
                        }
                        .onEnded { _ in
                            guard isReachable else { return }
                            isDraggingHumidity = false
                            setTargetHumidity(humiditySliderDraft)
                        }
                )
            }
            .frame(height: sliderHeight)
            .opacity(isReachable ? 1.0 : 0.4)
        }
    }
    
    private var lightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: adapter.isLightOn ? "lightbulb.fill" : "lightbulb")
                    .foregroundStyle(adapter.isLightOn ? .yellow : .secondary)
                Text(String(localized: "humidifier.light.title", defaultValue: "Luce"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    toggleLight()
                } label: {
                    Image(systemName: adapter.isLightOn ? "power.circle.fill" : "power.circle")
                        .font(.title3)
                        .foregroundStyle(adapter.isLightOn ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(!isReachable)
            }
            
            if adapter.canSetLightBrightness {
                lightBrightnessSlider
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
    }
    
    private var lightBrightnessSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "light.label.brightness", defaultValue: "Brightness"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            GeometryReader { geo in
                let fillWidth = geo.size.width * CGFloat(lightSliderDraft / 100)
                
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                    
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.yellow.opacity(0.85))
                        .frame(width: max(0, fillWidth))
                        .animation(isDraggingLight ? nil : .spring(response: 0.4), value: fillWidth)
                    
                    HStack {
                        Spacer()
                        Text("\(Int(lightSliderDraft))%")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(lightTextColor(fillWidth: fillWidth, totalWidth: geo.size.width))
                            .contentTransition(.numericText())
                        Spacer()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isReachable else { return }
                            isDraggingLight = true
                            let pct = (value.location.x / geo.size.width) * 100
                            lightSliderDraft = min(100, max(0, pct))
                        }
                        .onEnded { _ in
                            guard isReachable else { return }
                            isDraggingLight = false
                            setLightBrightness(Int(lightSliderDraft.rounded()))
                        }
                )
            }
            .frame(height: sliderHeight)
            .opacity(isReachable ? (adapter.isLightOn ? 1.0 : 0.6) : 0.4)
        }
    }
    
    private func lightTextColor(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        sliderTextColor(fillWidth: fillWidth, totalWidth: totalWidth)
    }
    
    private func sliderTextColor(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        fillWidth >= totalWidth / 2 ? .white : .primary
    }
    
    private func snappedHumidity(_ value: Double) -> Double {
        let step = adapter.targetHumidityStep
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
    
    private func triggerWriteError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.25)) { writeError = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) { writeError = false }
        }
    }
    
    private func handleToggleTap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await adapter.setActive(!isActive)
            } catch {
                triggerWriteError()
            }
        }
    }
    
    private func selectMode(_ mode: HumidifierMode) {
        guard mode != currentMode else { return }
        optimisticMode = mode
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await adapter.setMode(mode)
            } catch {
                optimisticMode = nil
                triggerWriteError()
            }
        }
    }
    
    private func setTargetHumidity(_ value: Double) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await adapter.setTargetHumidity(value)
            } catch {
                optimisticTarget = nil
                triggerWriteError()
            }
        }
    }
    
    private func toggleLight() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await adapter.setLightOn(!adapter.isLightOn)
            } catch {
                triggerWriteError()
            }
        }
    }
    
    private func setLightBrightness(_ value: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await adapter.setLightBrightness(value)
            } catch {
                triggerWriteError()
            }
        }
    }
}
