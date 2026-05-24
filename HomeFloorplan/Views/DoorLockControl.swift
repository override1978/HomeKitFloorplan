import SwiftUI
import HomeKit

/// Controllo per serratura HomeKit.
/// Bottone "Apri" / "Chiudi" che riflette lo stato corrente e cambia.
/// Stato Jammed = avviso rosso visibile.
struct DoorLockControl: View {
    let adapter: DoorLockAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var pendingTarget: DoorLockTargetState?
    
    private var isReachable: Bool { adapter.accessory.isReachable }
    
    var body: some View {
        VStack(spacing: 16) {
            statusHeader
            if adapter.currentState == .jammed {
                jammedBanner
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
            return adapter.targetState == .secured ? "Chiusura in corso…" : "Apertura in corso…"
        }
        switch adapter.currentState {
        case .jammed:    return "Bloccata"
        case .unsecured: return "Aperta"
        case .secured:   return "Chiusa"
        case .unknown:   return "Stato sconosciuto"
        }
    }
    
    // MARK: - Jammed banner
    
    private var jammedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            Text("Serratura bloccata. Controlla il meccanismo manualmente.")
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
    
    private var actionButton: some View {
        let wantsToLock = adapter.currentState == .unsecured
        let label = wantsToLock ? "Chiudi" : "Apri"
        let symbol = wantsToLock ? "lock.fill" : "lock.open.fill"
        let tint: Color = wantsToLock ? .green : .orange
        
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
        .disabled(!isReachable || adapter.isTransitioning || adapter.currentState == .jammed)
        .opacity((!isReachable || adapter.isTransitioning) ? 0.5 : 1.0)
        .animation(.spring(response: 0.3), value: adapter.currentState)
    }
    
    // MARK: - Battery warning
    
    private var batteryWarning: some View {
        HStack(spacing: 6) {
            Image(systemName: "battery.25percent")
            Text("Batteria scarica")
        }
        .font(.subheadline)
        .foregroundStyle(.red)
    }
    
    // MARK: - Action
    
    private func performAction() {
        let wantsToLock = adapter.currentState == .unsecured
        pendingTarget = wantsToLock ? .secured : .unsecured
        
        // Haptic forte per "apri" (azione di sicurezza), medio per "chiudi"
        let haptic = UIImpactFeedbackGenerator(style: wantsToLock ? .medium : .heavy)
        haptic.impactOccurred()
        
        Task {
            do {
                try await adapter.setLocked(wantsToLock)
            } catch {
                pendingTarget = nil
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
