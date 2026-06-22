import SwiftUI
import HomeKit

/// Controllo Apple-Home style per copertura finestre.
/// Slider orizzontale spesso con riempimento giallo + percentuale al centro,
/// trascinabile da qualsiasi punto. Sotto: bottoni Chiudi / Apri.
/// Lo slider scrive a HomeKit solo al rilascio (debounce).
struct WindowCoveringControl: View {
    let adapter: WindowCoveringAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var sliderDraft: Double = 0
    @State private var isDragging: Bool = false
    @State private var writeError = false
    @State private var isReversed = false

    private var currentValue: Int { adapter.currentPositionValue }
    private var targetValue: Int { adapter.targetPositionValue }
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var isMoving: Bool { currentValue != targetValue }
    
    var body: some View {
        VStack(spacing: 14) {
            stateLabel
            WindowCoveringPositionControl(
                position: $sliderDraft,
                isReachable: isReachable,
                onDragChanged: { isDragging = $0 },
                onEditingEnded: { writePosition(Int($0.rounded())) }
            )
            mappingToggle
            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear {
            sliderDraft = Double(currentValue)
            isReversed = adapter.isPositionMappingReversed
        }
        .onChange(of: currentValue) { _, newValue in
            if !isDragging {
                sliderDraft = Double(newValue)
            }
        }
        .onChange(of: isReversed) { _, newValue in
            adapter.setPositionMappingReversed(newValue)
            sliderDraft = Double(currentValue)
        }
    }
    
    // MARK: - Label di stato
    
    private var stateLabel: some View {
        HStack {
            Text(String(localized: "windowCovering.position", defaultValue: "Position"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(stateText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
    
    private var stateText: String {
        if !isReachable {
            return String(localized: "windowCovering.unreachable", defaultValue: "Unreachable")
        }
        if isMoving {
            return String(localized: "windowCovering.moving", defaultValue: "Moving → \(targetValue)%")
        }
        if currentValue >= 90 {
            return String(localized: "windowCovering.open", defaultValue: "Open")
        }
        if currentValue <= 10 {
            return String(localized: "windowCovering.closed", defaultValue: "Closed")
        }
        return String(localized: "windowCovering.partiallyOpen", defaultValue: "Open \(currentValue)%")
    }

    private var mappingToggle: some View {
        Toggle(isOn: $isReversed) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "windowCovering.reverseMapping", defaultValue: "Reverse open/close"))
                    .font(.subheadline.weight(.medium))
                Text(String(localized: "windowCovering.reverseMappingHint", defaultValue: "Use this if Open and Close are inverted for this accessory."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    // MARK: - Write

    private func triggerWriteError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.25)) { writeError = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) { writeError = false }
        }
    }

    private func writePosition(_ value: Int) {
        let haptic = UIImpactFeedbackGenerator(style: .light)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setPosition(value)
            } catch {
                triggerWriteError()
            }
        }
    }
}

struct WindowCoveringPositionControl: View {
    @Binding var position: Double
    let isReachable: Bool
    var height: CGFloat = 60
    var cornerRadius: CGFloat = 16
    let onDragChanged: (Bool) -> Void
    let onEditingEnded: (Double) -> Void

    var body: some View {
        VStack(spacing: 12) {
            slider
            quickActions
        }
    }

    private var slider: some View {
        GeometryReader { geo in
            let fillWidth = geo.size.width * CGFloat(position / 100)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.thinMaterial)

                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.yellow.opacity(0.85))
                    .frame(width: max(0, fillWidth))
                    .animation(.spring(response: 0.4), value: fillWidth)

                HStack {
                    Spacer()
                    Text("\(Int(position.rounded()))%")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(textColorForPercentage(fillWidth: fillWidth, totalWidth: geo.size.width))
                        .contentTransition(.numericText())
                    Spacer()
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isReachable else { return }
                        onDragChanged(true)
                        let pct = (value.location.x / geo.size.width) * 100
                        position = min(100, max(0, pct))
                    }
                    .onEnded { _ in
                        guard isReachable else { return }
                        onDragChanged(false)
                        onEditingEnded(position)
                    }
            )
        }
        .frame(height: height)
        .disabled(!isReachable)
        .opacity(isReachable ? 1.0 : 0.5)
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            quickButton(label: String(localized: "windowCovering.close", defaultValue: "Close"), systemImage: "arrow.down.to.line", target: 0)
            quickButton(label: String(localized: "windowCovering.openAction", defaultValue: "Open"), systemImage: "arrow.up.to.line", target: 100)
        }
    }

    private func quickButton(label: String, systemImage: String, target: Int) -> some View {
        Button {
            position = Double(target)
            onEditingEnded(Double(target))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(label)
            }
            .font(.subheadline.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
    }

    private func textColorForPercentage(fillWidth: CGFloat, totalWidth: CGFloat) -> Color {
        let textCenter = totalWidth / 2
        return fillWidth >= textCenter ? .white : .primary
    }
}
