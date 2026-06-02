import SwiftUI
import HomeKit

/// Controllo per garage door HomeKit.
/// Bottone "Apri" / "Chiudi" che riflette lo stato corrente.
/// Banner allarme quando ObstructionDetected o stato Stopped.
struct GarageDoorControl: View {
    let adapter: GarageDoorAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var pendingTarget: GarageDoorTargetState?
    
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    
    var body: some View {
        VStack(spacing: 16) {
            statusHeader
            if adapter.obstructionDetected {
                obstructionBanner
            } else if adapter.currentState == .stopped {
                stoppedBanner
            }
            actionButton
            if adapter.hasLowBattery {
                batteryWarning
            }
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
        if adapter.obstructionDetected { return String(localized: "garage.state.obstruction", defaultValue: "Ostacolo rilevato") }
        switch adapter.currentState {
        case .open:    return String(localized: "garage.state.open",    defaultValue: "Aperto")
        case .closed:  return String(localized: "garage.state.closed",  defaultValue: "Chiuso")
        case .opening: return String(localized: "garage.state.opening", defaultValue: "Apertura in corso…")
        case .closing: return String(localized: "garage.state.closing", defaultValue: "Chiusura in corso…")
        case .stopped: return String(localized: "garage.state.stopped", defaultValue: "Bloccato")
        }
    }
    
    // MARK: - Banners
    
    private var obstructionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "garage.state.obstruction",   defaultValue: "Ostacolo rilevato"))
                    .font(.subheadline.weight(.semibold))
                Text(String(localized: "garage.obstruction.message", defaultValue: "Controlla che nulla blocchi la chiusura del garage."))
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
            Text(String(localized: "garage.stopped.message", defaultValue: "Garage bloccato a metà. Verifica manualmente."))
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
    
    private var actionButton: some View {
        let wantsToClose = (adapter.currentState == .open || adapter.currentState == .opening)
        let label = wantsToClose
            ? String(localized: "garage.action.close", defaultValue: "Chiudi")
            : String(localized: "garage.action.open",  defaultValue: "Apri")
        let symbol = wantsToClose ? "arrow.down.to.line" : "arrow.up.to.line"
        let tint: Color = wantsToClose ? .green : .orange
        
        return Button {
            performAction()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                Text(label)
                    .font(.title3.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isReachable || adapter.isTransitioning || adapter.obstructionDetected)
        .opacity((!isReachable || adapter.isTransitioning) ? 0.5 : 1.0)
        .animation(.spring(response: 0.3), value: adapter.currentState)
    }
    
    // MARK: - Battery warning
    
    private var batteryWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.25percent")
            Text(String(localized: "accessory.battery.low", defaultValue: "Batteria scarica"))
        }
        .font(.subheadline)
        .foregroundStyle(.red)
    }

    // MARK: - Action
    
    private func performAction() {
        let wantsToClose = (adapter.currentState == .open || adapter.currentState == .opening)
        pendingTarget = wantsToClose ? .closed : .open
        
        let haptic = UIImpactFeedbackGenerator(style: wantsToClose ? .medium : .heavy)
        haptic.impactOccurred()
        
        Task {
            do {
                try await adapter.setOpen(!wantsToClose)
            } catch {
                pendingTarget = nil
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
