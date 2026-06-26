import SwiftUI
import HomeKit

/// Controllo per garage door HomeKit.
/// Bottone "Apri" / "Chiudi" che riflette lo stato corrente.
/// Banner allarme quando ObstructionDetected o stato Stopped.
struct GarageDoorControl: View {
    let adapter: GarageDoorAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var pendingTarget: GarageDoorTargetState?
    @State private var writeError = false

    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    
    var body: some View {
        VStack(spacing: 16) {
            statusHeader
            obstructionStatusRow
            if adapter.obstructionDetected {
                obstructionBanner
            } else if adapter.currentState == .stopped {
                stoppedBanner
            }
            actionButtons
            if adapter.hasLowBattery {
                batteryWarning
            }
            if writeError { WriteErrorBanner() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onChange(of: adapter.currentState) { _, _ in
            pendingTarget = nil
        }
    }
    
    // MARK: - Status header
    
    private var statusHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title3)
            Text(statusText)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
    
    private var statusIcon: String {
        if adapter.obstructionDetected { return "exclamationmark.triangle.fill" }
        if adapter.isTransitioning { return "hourglass" }
        switch adapter.currentState {
        case .open:    return "door.garage.open"
        case .closed:  return "door.garage.closed"
        case .opening: return "arrow.up.circle"
        case .closing: return "arrow.down.circle"
        case .stopped: return "exclamationmark.octagon.fill"
        }
    }
    
    private var statusColor: Color {
        if adapter.obstructionDetected { return .red }
        switch adapter.currentState {
        case .open:    return .orange
        case .closed:  return .green
        case .opening, .closing: return .yellow
        case .stopped: return .red
        }
    }
    
    private var statusText: String {
        if adapter.obstructionDetected { return String(localized: "garage.state.obstruction", defaultValue: "Obstruction Detected") }
        switch adapter.currentState {
        case .open:    return String(localized: "garage.state.open",    defaultValue: "Open")
        case .closed:  return String(localized: "garage.state.closed",  defaultValue: "Closed")
        case .opening: return String(localized: "garage.state.opening", defaultValue: "Opening…")
        case .closing: return String(localized: "garage.state.closing", defaultValue: "Closing…")
        case .stopped: return String(localized: "garage.state.stopped", defaultValue: "Stopped")
        }
    }
    
    // MARK: - Banners

    private var obstructionStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: adapter.obstructionDetected ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(adapter.obstructionDetected ? Color.red : Color.green)
            Text(String(localized: "garage.obstruction.label", defaultValue: "Obstruction"))
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(adapter.obstructionDetected
                 ? String(localized: "garage.obstruction.detected", defaultValue: "Detected")
                 : String(localized: "garage.obstruction.clear", defaultValue: "Clear"))
                .font(.subheadline)
                .foregroundStyle(adapter.obstructionDetected ? Color.red : Color.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }
    
    private var obstructionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "garage.state.obstruction",   defaultValue: "Obstruction Detected"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "garage.obstruction.message", defaultValue: "Check that nothing is blocking the garage door."))
                    .font(.caption)
            }
            .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red)
        )
    }
    
    private var stoppedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.white)
            Text(String(localized: "garage.stopped.message", defaultValue: "Garage stopped mid-way. Check manually."))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red.opacity(0.9))
        )
    }
    
    // MARK: - Action button
    
    private var actionButtons: some View {
        HStack(spacing: 10) {
            actionButton(
                title: String(localized: "garage.action.open", defaultValue: "Open"),
                symbol: "arrow.up.to.line",
                tint: .orange,
                target: .open,
                isCurrentState: adapter.currentState == .open || adapter.currentState == .opening
            )
            actionButton(
                title: String(localized: "garage.action.close", defaultValue: "Close"),
                symbol: "arrow.down.to.line",
                tint: .green,
                target: .closed,
                isCurrentState: adapter.currentState == .closed || adapter.currentState == .closing
            )
        }
        .animation(.spring(response: 0.3), value: adapter.currentState)
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color,
        target: GarageDoorTargetState,
        isCurrentState: Bool
    ) -> some View {
        let disabled = !isReachable || adapter.isTransitioning || adapter.obstructionDetected || isCurrentState

        return Button {
            performAction(target: target)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(disabled ? Color.secondary.opacity(0.35) : tint)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity((!isReachable || adapter.isTransitioning) ? 0.5 : 1.0)
    }
    
    // MARK: - Battery warning
    
    private var batteryWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.25percent")
            Text(String(localized: "accessory.battery.low", defaultValue: "Low Battery"))
        }
        .font(.subheadline)
        .foregroundStyle(.red)
    }

    // MARK: - Action

    private func triggerWriteError() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        withAnimation(.easeInOut(duration: 0.25)) { writeError = true }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeInOut(duration: 0.25)) { writeError = false }
        }
    }

    private func performAction(target: GarageDoorTargetState) {
        pendingTarget = target
        
        let wantsToClose = target == .closed
        let haptic = UIImpactFeedbackGenerator(style: wantsToClose ? .medium : .heavy)
        haptic.impactOccurred()
        
        Task {
            do {
                try await adapter.setOpen(target == .open)
            } catch {
                pendingTarget = nil
                triggerWriteError()
            }
        }
    }
}
