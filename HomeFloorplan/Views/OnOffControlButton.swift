import SwiftUI
import HomeKit

/// Bottone tondo stile Apple Home per toggle on/off di un accessorio.
/// Usa l'icona effettiva (override utente o adapter) e cambia stato + colore
/// con animazione spring. Tap = quickToggle dell'adapter.
struct OnOffControlButton: View {
    let adapter: OnOffAdapter
    
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IconOverrideStore.self) private var iconOverrides
    
    private let diameter: CGFloat = 80
    
    private var iconName: String {
        iconOverrides.effectiveIcon(for: adapter.accessory, adapter: adapter)
    }
    
    private var isOn: Bool { adapter.isOn }
    private var isReachable: Bool { !homeKit.isLikelyOffline(adapter.accessory) }
    
    var body: some View {
        VStack(spacing: 10) {
            Button(action: handleTap) {
                ZStack {
                    Circle()
                        .fill(fillStyle)
                        .frame(width: diameter, height: diameter)
                    
                    AccessoryIconView(iconName: iconName)
                        .foregroundStyle(iconColor)
                        .frame(width: diameter * 0.45, height: diameter * 0.45)
                }
                .shadow(color: .black.opacity(isOn ? 0.22 : 0.12),
                        radius: isOn ? 6 : 3,
                        y: 1)
            }
            .buttonStyle(.plain)
            .disabled(!isReachable)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isOn)
            .scaleEffect(isReachable ? 1.0 : 0.95)
            .opacity(isReachable ? 1.0 : 0.5)
            
            Text(stateLabel)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
    
    // MARK: - Style
    
    private var fillStyle: AnyShapeStyle {
        if !isReachable {
            return AnyShapeStyle(.thinMaterial)
        }
        return isOn
            ? AnyShapeStyle(Color.yellow.opacity(0.9))
            : AnyShapeStyle(.thinMaterial)
    }
    
    private var iconColor: Color {
        if !isReachable { return .secondary }
        return isOn ? .white : .primary
    }
    
    private var stateLabel: String {
        if !isReachable { return String(localized: "accessory.unreachable", defaultValue: "Non raggiungibile") }
        return isOn
            ? String(localized: "accessory.state.on", defaultValue: "Acceso")
            : String(localized: "accessory.state.off", defaultValue: "Spento")
    }
    
    // MARK: - Action
    
    private func handleTap() {
        let haptic = UIImpactFeedbackGenerator(style: .medium)
        haptic.impactOccurred()
        
        Task {
            do {
                try await adapter.performQuickToggle(via: homeKit)
            } catch {
                // Feedback aptico di errore
                let notif = UINotificationFeedbackGenerator()
                notif.notificationOccurred(.error)
            }
        }
    }
}
