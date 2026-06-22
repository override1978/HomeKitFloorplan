import SwiftUI
import HomeKit

/// Controllo Apple-Home style per luci dimmerabili.
/// Bottone tondo on/off in alto, slider luminosità orizzontale sotto.
/// Lo slider è interattivo solo quando la luce è accesa.
struct DimmableLightControl: View {
    let adapter: DimmableLightAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    
    @State private var sliderDraft: Double = 0
    @State private var hueDraft: Double = 45
    @State private var saturationDraft: Double = 0
    @State private var temperatureDraft: Double = 250
    @State private var isDragging: Bool = false
    @State private var isColorDragging: Bool = false
    @State private var isTemperatureDragging: Bool = false
    @State private var writeError = false

    private let buttonDiameter: CGFloat = 80
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }
    
    private var currentBrightness: Int { adapter.currentBrightness }
    private var isOn: Bool { adapter.isOn }
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var sliderEnabled: Bool { isReachable }
    
    var body: some View {
        VStack(spacing: 20) {
            toggleButton
            slider
            colorControls
            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            sliderDraft = Double(currentBrightness)
            syncColorDrafts()
        }
        .onChange(of: currentBrightness) { _, newValue in
            if !isDragging {
                sliderDraft = Double(newValue)
            }
        }
        .onChange(of: adapter.currentHue) { _, _ in
            if !isColorDragging { syncColorDrafts() }
        }
        .onChange(of: adapter.currentSaturation) { _, _ in
            if !isColorDragging { syncColorDrafts() }
        }
        .onChange(of: adapter.currentColorTemperature) { _, newValue in
            if !isTemperatureDragging {
                temperatureDraft = Double(newValue)
            }
        }
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
                .shadow(color: .black.opacity(isOn ? 0.22 : 0.12),
                        radius: isOn ? 6 : 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)
            
            Text(stateLabel)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
    }
    
    private var toggleFill: AnyShapeStyle {
        if !isReachable { return AnyShapeStyle(.thinMaterial) }
        return isOn
            ? AnyShapeStyle(Color.yellow.opacity(0.9))
            : AnyShapeStyle(.thinMaterial)
    }
    
    private var toggleIconColor: Color {
        if !isReachable { return .secondary }
        return isOn ? .white : .primary
    }
    
    private var stateLabel: String {
        if !isReachable { return String(localized: "accessory.unreachable", defaultValue: "Non raggiungibile") }
        if !isOn { return String(localized: "light.state.off", defaultValue: "Spenta") }
        return "\(String(localized: "light.state.on", defaultValue: "Accesa al")) \(currentBrightness)%"
    }
    
    // MARK: - Slider Apple-Home-style
    
    private var slider: some View {
        LightBrightnessSlider(
            brightness: $sliderDraft,
            isEnabled: sliderEnabled,
            isDimmed: !isOn,
            titleFont: .subheadline,
            height: 60,
            onDragChanged: { isDragging = $0 },
            onEditingEnded: { writeBrightness(Int($0.rounded())) }
        )
    }

    // MARK: - Color controls

    @ViewBuilder
    private var colorControls: some View {
        if adapter.supportsColor || adapter.supportsColorTemperature {
            LightColorControlPanel(
                supportsColor: adapter.supportsColor,
                supportsColorTemperature: adapter.supportsColorTemperature,
                isReachable: isReachable,
                temperatureRange: adapter.colorTemperatureRange,
                hueDraft: $hueDraft,
                saturationDraft: $saturationDraft,
                temperatureDraft: $temperatureDraft,
                onColorDragChanged: { isColorDragging = $0 },
                onTemperatureDragChanged: { isTemperatureDragging = $0 },
                onColorChanged: writeColor,
                onTemperatureChanged: writeColorTemperature
            )
        }
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
                try await adapter.performQuickToggle(via: homeKit)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func writeBrightness(_ value: Int) {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                // Accendi automaticamente se è spenta e l'utente sta impostando > 0
                if !isOn && value > 0 {
                    try await adapter.performQuickToggle(via: homeKit)
                }
                try await adapter.setBrightness(value)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func writeColor(hue: Double, saturation: Double) {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                if !isOn {
                    try await adapter.performQuickToggle(via: homeKit)
                }
                try await adapter.setColor(hue: hue, saturation: saturation)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func writeColorTemperature(_ value: Int) {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                if !isOn {
                    try await adapter.performQuickToggle(via: homeKit)
                }
                try await adapter.setColorTemperature(value)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func syncColorDrafts() {
        hueDraft = adapter.currentHue
        saturationDraft = adapter.currentSaturation
        temperatureDraft = Double(adapter.currentColorTemperature)
    }
}

struct LightBrightnessSlider: View {
    @Binding var brightness: Double
    let isEnabled: Bool
    let isDimmed: Bool
    var titleFont: Font = .subheadline
    var height: CGFloat = 60
    var cornerRadius: CGFloat = 16
    let onDragChanged: (Bool) -> Void
    let onEditingEnded: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "light.label.brightness", defaultValue: "Brightness"))
                .font(titleFont)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let fillWidth = geo.size.width * CGFloat(brightness / 100)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.yellow.opacity(0.85))
                        .frame(width: max(0, fillWidth))
                        .animation(.spring(response: 0.4), value: fillWidth)

                    HStack {
                        Spacer()
                        Text("\(Int(brightness.rounded()))%")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(textColor(fillWidth: fillWidth, totalWidth: geo.size.width))
                            .contentTransition(.numericText())
                        Spacer()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isEnabled else { return }
                            onDragChanged(true)
                            let pct = (value.location.x / geo.size.width) * 100
                            brightness = min(100, max(0, pct))
                        }
                        .onEnded { _ in
                            guard isEnabled else { return }
                            onDragChanged(false)
                            onEditingEnded(brightness)
                        }
                )
            }
            .frame(height: height)
            .opacity(isEnabled ? (isDimmed ? 0.6 : 1.0) : 0.4)
        }
    }

    private func textColor(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        let textCenter = totalWidth / 2
        return fillWidth >= textCenter ? .white : .primary
    }
}

struct LightColorControlPanel: View {
    let supportsColor: Bool
    let supportsColorTemperature: Bool
    let isReachable: Bool
    let temperatureRange: ClosedRange<Int>
    @Binding var hueDraft: Double
    @Binding var saturationDraft: Double
    @Binding var temperatureDraft: Double
    let onColorDragChanged: (Bool) -> Void
    let onTemperatureDragChanged: (Bool) -> Void
    let onColorChanged: (Double, Double) -> Void
    let onTemperatureChanged: (Int) -> Void

    private let colorSwatches: [(hue: Double, saturation: Double)] = [
        (0, 95), (28, 90), (55, 85), (115, 70),
        (185, 75), (220, 80), (275, 80), (320, 75)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(String(localized: "light.label.color", defaultValue: "Color"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if supportsColor {
                    Circle()
                        .fill(currentUIColor)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1))
                }
            }

            if supportsColor {
                colorPalette
                hueSlider
            }

            if supportsColorTemperature {
                temperatureSlider
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(isReachable ? 1.0 : 0.45)
    }

    private var currentUIColor: Color {
        Color(
            hue: hueDraft / 360,
            saturation: max(0, min(1, saturationDraft / 100)),
            brightness: 1
        )
    }

    private var colorPalette: some View {
        HStack(spacing: 10) {
            ForEach(Array(colorSwatches.enumerated()), id: \.offset) { _, swatch in
                Button {
                    guard isReachable else { return }
                    hueDraft = swatch.hue
                    saturationDraft = swatch.saturation
                    onColorChanged(swatch.hue, swatch.saturation)
                } label: {
                    Circle()
                        .fill(Color(hue: swatch.hue / 360, saturation: swatch.saturation / 100, brightness: 1))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    isSelectedSwatch(swatch) ? Color.primary.opacity(0.65) : Color.secondary.opacity(0.18),
                                    lineWidth: isSelectedSwatch(swatch) ? 2 : 1
                                )
                        }
                }
                .buttonStyle(.plain)
                .disabled(!isReachable)
            }
        }
    }

    private var hueSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "light.label.hue", defaultValue: "Hue"))
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                        .offset(x: max(0, min(geo.size.width - 24, geo.size.width * CGFloat(hueDraft / 360) - 12)))
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isReachable else { return }
                            onColorDragChanged(true)
                            hueDraft = max(0, min(360, (value.location.x / geo.size.width) * 360))
                            saturationDraft = max(saturationDraft, 60)
                        }
                        .onEnded { _ in
                            guard isReachable else { return }
                            onColorDragChanged(false)
                            onColorChanged(hueDraft, saturationDraft)
                        }
                )
            }
            .frame(height: 34)
        }
    }

    private var temperatureSlider: some View {
        let range = temperatureRange
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "light.label.temperature", defaultValue: "Temperature"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(temperatureLabel)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let span = max(1, range.upperBound - range.lowerBound)
                let fraction = (temperatureDraft - Double(range.lowerBound)) / Double(span)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.58, green: 0.74, blue: 1.0),
                                    Color.white,
                                    Color(red: 1.0, green: 0.74, blue: 0.36)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Circle()
                        .fill(.white)
                        .frame(width: 24, height: 24)
                        .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                        .offset(x: max(0, min(geo.size.width - 24, geo.size.width * CGFloat(fraction) - 12)))
                }
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isReachable else { return }
                            onTemperatureDragChanged(true)
                            let pct = max(0, min(1, value.location.x / geo.size.width))
                            temperatureDraft = Double(range.lowerBound) + Double(span) * pct
                        }
                        .onEnded { _ in
                            guard isReachable else { return }
                            onTemperatureDragChanged(false)
                            onTemperatureChanged(Int(temperatureDraft.rounded()))
                        }
                )
            }
            .frame(height: 34)
        }
    }

    private var temperatureLabel: String {
        let kelvin = Int((1_000_000 / max(1, temperatureDraft)).rounded())
        return "\(kelvin)K"
    }

    private func isSelectedSwatch(_ swatch: (hue: Double, saturation: Double)) -> Bool {
        abs(hueDraft - swatch.hue) < 8 && abs(saturationDraft - swatch.saturation) < 16
    }
}
