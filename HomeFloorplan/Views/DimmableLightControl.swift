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
    @State private var isDragging: Bool = false
    
    private let buttonDiameter: CGFloat = 80
    private let sliderHeight: CGFloat = 60
    
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
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            sliderDraft = Double(currentBrightness)
        }
        .onChange(of: currentBrightness) { _, newValue in
            if !isDragging {
                sliderDraft = Double(newValue)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "light.label.brightness", defaultValue: "Brightness"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            GeometryReader { geo in
                let fillWidth = geo.size.width * CGFloat(sliderDraft / 100)
                
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                    
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.yellow.opacity(0.85))
                        .frame(width: max(0, fillWidth))
                        .animation(isDragging ? nil : .spring(response: 0.4), value: fillWidth)
                    
                    HStack {
                        Spacer()
                        Text("\(Int(sliderDraft))%")
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(textColor(fillWidth: fillWidth, totalWidth: geo.size.width))
                            .contentTransition(.numericText())
                        Spacer()
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard sliderEnabled else { return }
                            isDragging = true
                            let pct = (value.location.x / geo.size.width) * 100
                            sliderDraft = min(100, max(0, pct))
                        }
                        .onEnded { _ in
                            guard sliderEnabled else { return }
                            isDragging = false
                            writeBrightness(Int(sliderDraft.rounded()))
                        }
                )
            }
            .frame(height: sliderHeight)
            .opacity(isReachable ? (isOn ? 1.0 : 0.6) : 0.4)
        }
    }
    
    private func textColor(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        let textCenter = totalWidth / 2
        return fillWidth >= textCenter ? .white : .primary
    }
    
    // MARK: - Actions
    
    private func handleToggleTap() {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        Task {
            try? await adapter.performQuickToggle(via: homeKit)
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
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
