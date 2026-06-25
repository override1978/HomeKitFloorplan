import SwiftUI
import HomeKit

/// Apple Home-style control for fans: circular power button and rotation speed slider.
struct FanControl: View {
    let adapter: FanAdapter

    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides

    @State private var speedDraft: Double = 0
    @State private var isDragging: Bool = false
    @State private var writeError: Bool = false

    private let buttonDiameter: CGFloat = 80

    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }

    private var isOn: Bool { adapter.isOn }
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var currentSpeed: Int { adapter.currentSpeed }

    var body: some View {
        VStack(spacing: 20) {
            toggleButton
            speedSlider
            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            speedDraft = Double(currentSpeed)
        }
        .onChange(of: currentSpeed) { _, newValue in
            if !isDragging {
                speedDraft = Double(newValue)
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
                .shadow(color: .black.opacity(isOn ? 0.22 : 0.12), radius: isOn ? 6 : 3, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isReachable || !adapter.supportsQuickToggle)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)

            Text(stateLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var speedSlider: some View {
        FanSpeedSlider(
            speed: $speedDraft,
            range: adapter.speedRange,
            isEnabled: isReachable,
            isDimmed: !isOn,
            onDragChanged: { isDragging = $0 },
            onEditingEnded: { writeSpeed(Int($0.rounded())) }
        )
    }

    private var toggleFill: AnyShapeStyle {
        if !isReachable { return AnyShapeStyle(.thinMaterial) }
        return isOn ? AnyShapeStyle(Color.cyan.opacity(0.9)) : AnyShapeStyle(.thinMaterial)
    }

    private var toggleIconColor: Color {
        if !isReachable { return .secondary }
        return isOn ? .white : .primary
    }

    private var stateLabel: String {
        if !isReachable { return String(localized: "accessory.unreachable", defaultValue: "Non raggiungibile") }
        if !isOn { return String(localized: "accessory.state.off", defaultValue: "Spento") }
        return "\(String(localized: "fan.state.on", defaultValue: "Accesa al")) \(currentSpeed)%"
    }

    private func handleToggleTap() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        Task {
            do {
                try await adapter.performQuickToggle(via: homeKit)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func writeSpeed(_ value: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task {
            do {
                try await adapter.setSpeed(value)
            } catch {
                triggerWriteError()
            }
        }
    }

    private func triggerWriteError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.25)) { writeError = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) { writeError = false }
        }
    }
}

private struct FanSpeedSlider: View {
    @Binding var speed: Double
    let range: ClosedRange<Int>
    let isEnabled: Bool
    let isDimmed: Bool
    let onDragChanged: (Bool) -> Void
    let onEditingEnded: (Double) -> Void

    private let height: CGFloat = 60
    private let cornerRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(.secondary)
                Text(String(localized: "fan.label.speed", defaultValue: "Velocità ventola"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            GeometryReader { geo in
                let progress = normalizedProgress
                let fillWidth = geo.size.width * progress

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.thinMaterial)

                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.cyan.opacity(0.85))
                        .frame(width: max(0, fillWidth))
                        .animation(.spring(response: 0.4), value: fillWidth)

                    HStack {
                        Spacer()
                        Text("\(Int(speed.rounded()))%")
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
                            speed = valueFor(locationX: value.location.x, width: geo.size.width)
                        }
                        .onEnded { _ in
                            guard isEnabled else { return }
                            onDragChanged(false)
                            onEditingEnded(speed)
                        }
                )
            }
            .frame(height: height)
            .opacity(isEnabled ? (isDimmed ? 0.6 : 1.0) : 0.4)
        }
    }

    private var normalizedProgress: CGFloat {
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        guard upper > lower else { return 0 }
        let clamped = min(upper, max(lower, speed))
        return CGFloat((clamped - lower) / (upper - lower))
    }

    private func valueFor(locationX: CGFloat, width: CGFloat) -> Double {
        let progress = min(1, max(0, locationX / max(width, 1)))
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        return lower + (upper - lower) * Double(progress)
    }

    private func textColor(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        let textCenter = totalWidth / 2
        return fillWidth >= textCenter ? .white : .primary
    }
}
