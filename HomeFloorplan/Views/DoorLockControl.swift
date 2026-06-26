import SwiftUI
import HomeKit

/// Controllo per serratura HomeKit.
/// Bottone "Apri" / "Chiudi" che riflette lo stato corrente e cambia.
/// Stato Jammed = avviso rosso visibile.
struct DoorLockControl: View {
    let adapter: DoorLockAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var pendingTarget: DoorLockTargetState?
    @State private var writeError = false

    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    
    var body: some View {
        VStack(spacing: 16) {
            statusHeader
            if adapter.autoSecureTimeoutSeconds != nil {
                autoSecureRow
            }
            if adapter.currentState == .jammed {
                jammedBanner
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
        if adapter.isTransitioning { return "hourglass" }
        switch adapter.currentState {
        case .jammed:    return "exclamationmark.triangle.fill"
        case .unsecured: return "lock.open.fill"
        case .secured:   return "lock.fill"
        case .unknown:   return "questionmark.circle"
        }
    }
    
    private var statusColor: Color {
        switch adapter.currentState {
        case .jammed:    return .red
        case .unsecured: return .orange
        case .secured:   return .green
        case .unknown:   return .secondary
        }
    }
    
    private var statusText: String {
        if adapter.isTransitioning {
            return adapter.targetState == .secured
                ? String(localized: "doorlock.state.locking",   defaultValue: "Locking…")
                : String(localized: "doorlock.state.unlocking", defaultValue: "Unlocking…")
        }
        switch adapter.currentState {
        case .jammed:    return String(localized: "doorlock.state.jammed",   defaultValue: "Jammed")
        case .unsecured: return String(localized: "doorlock.state.unlocked", defaultValue: "Unlocked")
        case .secured:   return String(localized: "doorlock.state.locked",   defaultValue: "Locked")
        case .unknown:   return String(localized: "doorlock.state.unknown",  defaultValue: "Unknown State")
        }
    }
    
    // MARK: - Jammed banner

    private var autoSecureRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "timer")
                .foregroundStyle(.secondary)
            Text(String(localized: "doorlock.autoSecure.label", defaultValue: "Auto secure"))
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(autoSecureText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private var autoSecureText: String {
        guard let seconds = adapter.autoSecureTimeoutSeconds, seconds > 0 else {
            return String(localized: "doorlock.autoSecure.off", defaultValue: "Off")
        }
        if seconds < 60 {
            return String(format: String(localized: "doorlock.autoSecure.seconds", defaultValue: "%d sec"), seconds)
        }
        let minutes = seconds / 60
        return String(format: String(localized: "doorlock.autoSecure.minutes", defaultValue: "%d min"), minutes)
    }
    
    private var jammedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text(String(localized: "doorlock.jammed.message", defaultValue: "Lock jammed. Check the mechanism manually."))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.red)
        )
    }
    
    // MARK: - Action button
    
    private var actionButtons: some View {
        HStack(spacing: 10) {
            actionButton(
                title: String(localized: "doorlock.action.unlock", defaultValue: "Unlock"),
                symbol: "lock.open.fill",
                tint: .orange,
                target: .unsecured,
                isCurrentState: adapter.currentState == .unsecured
            )
            actionButton(
                title: String(localized: "doorlock.action.lock", defaultValue: "Lock"),
                symbol: "lock.fill",
                tint: .green,
                target: .secured,
                isCurrentState: adapter.currentState == .secured
            )
        }
        .animation(.spring(response: 0.3), value: adapter.currentState)
    }

    private func actionButton(
        title: String,
        symbol: String,
        tint: Color,
        target: DoorLockTargetState,
        isCurrentState: Bool
    ) -> some View {
        let disabled = !isReachable || adapter.isTransitioning || adapter.currentState == .jammed || isCurrentState

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

    private func performAction(target: DoorLockTargetState) {
        pendingTarget = target
        
        // Haptic forte per "apri" (azione di sicurezza), medio per "chiudi"
        let wantsToLock = target == .secured
        let haptic = UIImpactFeedbackGenerator(style: wantsToLock ? .medium : .heavy)
        haptic.impactOccurred()
        
        Task {
            do {
                try await adapter.setLocked(wantsToLock)
            } catch {
                pendingTarget = nil
                triggerWriteError()
            }
        }
    }
}
