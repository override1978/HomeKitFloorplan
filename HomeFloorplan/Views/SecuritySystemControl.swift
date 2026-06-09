import SwiftUI
import HomeKit

/// Controllo per sistemi di sicurezza HomeKit.
/// 4 pillole modalità in orizzontale (Casa / Fuori / Notte / Disinserito).
/// In stato "triggered": tutto il pannello diventa rosso pulsante con
/// bottone gigante "Disarma" che sovrasta le pillole.
struct SecuritySystemControl: View {
    let adapter: SecuritySystemAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    
    @State private var pendingMode: SecurityMode?
    @State private var pulseAlarm: Bool = false
    
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    private var currentMode: SecurityMode { adapter.currentMode }
    
    var body: some View {
        VStack(spacing: 16) {
            if adapter.isTriggered {
                triggeredView
            } else {
                normalView
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            if adapter.isTriggered { startPulse() }
        }
        .onChange(of: adapter.isTriggered) { _, newValue in
            if newValue { startPulse() } else { stopPulse() }
        }
        .onChange(of: currentMode) { _, _ in
            // Se è arrivato il valore vero da HomeKit, sgancia il pending
            pendingMode = nil
        }
    }
    
    // MARK: - Vista normale
    
    private var normalView: some View {
        VStack(spacing: 16) {
            statusHeader
            modePillsRow
            transitionHint
        }
    }
    
    private var statusHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(currentMode.tintColor)
                .font(.title3)
            Text(adapter.isTransitioning
                 ? String(localized: "security.state.arming", defaultValue: "Inserimento in corso…")
                 : currentMode.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
    
    private var statusIcon: String {
        if adapter.isTransitioning { return "hourglass" }
        switch currentMode {
        case .stay:   return "house.fill"
        case .away:   return "figure.walk.departure"
        case .night:  return "moon.fill"
        case .disarm: return "lock.open.fill"
        }
    }
    
    private var modePillsRow: some View {
        HStack(spacing: 8) {
            ForEach(adapter.supportedModes) { m in
                modePill(m)
            }
        }
        .padding(.horizontal, 4)
    }
    
    private func modePill(_ m: SecurityMode) -> some View {
        let isSelected = m == (pendingMode ?? currentMode)
        return Button {
            selectMode(m)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: m.symbolName)
                    .font(.title3)
                Text(m.displayName)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isSelected ? .white : m.tintColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected
                          ? AnyShapeStyle(m.tintColor)
                          : AnyShapeStyle(.thinMaterial))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
        .animation(.spring(response: 0.3), value: isSelected)
    }
    
    @ViewBuilder
    private var transitionHint: some View {
        if adapter.isTransitioning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "security.state.arming.hint", defaultValue: "The system is changing state. This may take a few seconds."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
        }
    }
    
    // MARK: - Vista TRIGGERED
    
    private var triggeredView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.red.opacity(pulseAlarm ? 0.95 : 0.65))
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                           value: pulseAlarm)
            
            VStack(spacing: 18) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title)
                    Text(String(localized: "security.alarm.active", defaultValue: "ALARM ACTIVE"))
                        .font(.title3.weight(.bold))
                }
                .foregroundStyle(.white)
                
                Button {
                    selectMode(.disarm)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 32))
                        Text(String(localized: "security.action.disarm", defaultValue: "DISARM"))
                            .font(.headline.weight(.bold))
                    }
                    .foregroundStyle(.red)
                    .frame(width: 160, height: 90)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(!isReachable)
            }
            .padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Animation
    
    private func startPulse() {
        pulseAlarm = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pulseAlarm = true
        }
    }
    
    private func stopPulse() {
        pulseAlarm = false
    }
    
    // MARK: - Action
    
    private func selectMode(_ m: SecurityMode) {
        guard m != currentMode else { return }
        pendingMode = m
        let haptic = UIImpactFeedbackGenerator(style: .heavy)
        haptic.impactOccurred()
        Task {
            do {
                try await adapter.setMode(m)
            } catch {
                pendingMode = nil
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
