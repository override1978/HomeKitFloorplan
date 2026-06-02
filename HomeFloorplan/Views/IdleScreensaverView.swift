import SwiftUI

/// Overlay screensaver mostrato dopo inattività prolungata.
/// Si sovrappone all'intera app senza alterare la navigazione sottostante.
/// Toccare qualsiasi punto (o avvicinare il dispositivo al viso) lo dismette.
struct IdleScreensaverView: View {

    let onDismiss: () -> Void

    @State private var iconScale: CGFloat = 0.88
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0
    private let glowOpacity: Double = 0.18
    /// Token restituito da addObserver — necessario per rimuovere correttamente l'observer.
    @State private var proximityObserverToken: (any NSObjectProtocol)?

    var body: some View {
        ZStack {
            // Sfondo gradiente identico allo SplashView
            BrandColor.heroGradient
                .ignoresSafeArea()

            VStack(spacing: 32) {
                // Casa con glow pulsante
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(glowOpacity))
                        .frame(width: 200, height: 200)
                        .blur(radius: 28)

                    Image("HomeFloorplanIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                }
                .scaleEffect(iconScale)
                .opacity(iconOpacity)

                VStack(spacing: 10) {
                    Text("Home Floorplan")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(String(localized: "screensaver.tapToReturn", defaultValue: "Tocca per tornare"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .opacity(textOpacity)
            }
        }
        // Qualsiasi tap dismette lo screensaver
        .onTapGesture {
            dismiss()
        }
        .task {
            // Animazione entrata
            withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 0.45)) {
                textOpacity = 1.0
            }
            // Attiva il sensore di prossimità
            startProximityMonitoring()
        }
        .onDisappear {
            stopProximityMonitoring()
        }
    }

    // MARK: - Proximity sensor

    /// Attiva il sensore di prossimità di UIKit: quando l'utente avvicina
    /// il dispositivo al viso la notifica `UIDevice.proximityStateDidChangeNotification`
    /// viene inviata e lo screensaver viene dismesso.
    private func startProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = true
        proximityObserverToken = NotificationCenter.default.addObserver(
            forName: UIDevice.proximityStateDidChangeNotification,
            object: UIDevice.current,
            queue: .main
        ) { _ in
            if UIDevice.current.proximityState {
                dismiss()
            }
        }
    }

    private func stopProximityMonitoring() {
        UIDevice.current.isProximityMonitoringEnabled = false
        if let token = proximityObserverToken {
            NotificationCenter.default.removeObserver(token)
            proximityObserverToken = nil
        }
    }

    private func dismiss() {
        onDismiss()
    }
}

#Preview {
    IdleScreensaverView(onDismiss: {})
}
