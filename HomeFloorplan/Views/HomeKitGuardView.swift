import SwiftUI
import HomeKit

/// Wrapper che intercetta lo stato di HomeKit:
/// - Mostra spinner mentre carica
/// - Mostra "permessi negati" se l'utente ha rifiutato l'accesso
/// - Altrimenti mostra il content figlio
struct HomeKitGuardView<Content: View>: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.scenePhase) private var scenePhase
    @State private var minimumSplashElapsed: Bool = false
    
    @ViewBuilder let content: () -> Content
    
    @State private var loadingTooLong: Bool = false
    @State private var lastLoggedHomeKitState: String?

    var body: some View {
        Group {
            if homeKit.isAuthorizationDenied {
                        deniedView
                    } else if homeKit.isAuthorizationUnknown || !homeKit.isReady || !minimumSplashElapsed {
                        loadingView
                    } else {
                        content()
                    }
        }
        .animation(.easeInOut(duration: 0.3), value: homeKit.isReady)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                homeKit.reloadAuthorizationStatus()
            }
        }
        .task(id: homeKitStateSignature) {
            logHomeKitStateIfNeeded()
        }
        .task {
            // Se dopo 4 secondi siamo ancora in loading, mostra messaggio di pazienza
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                loadingTooLong = true
            }
        }
        .task {
                // Durata minima splash: 1.5 sec
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Task.isCancelled {
                    minimumSplashElapsed = true
                }
            }
            .task {
                // Messaggio "richiede più del solito" dopo 4 sec
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled {
                    loadingTooLong = true
                }
            }
    }

    private var homeKitStateSignature: String {
        [
            "status=\(String(describing: homeKit.authorizationStatus))",
            "denied=\(homeKit.isAuthorizationDenied)",
            "unknown=\(homeKit.isAuthorizationUnknown)",
            "ready=\(homeKit.isReady)"
        ].joined(separator: "|")
    }

    private func logHomeKitStateIfNeeded() {
        guard lastLoggedHomeKitState != homeKitStateSignature else { return }
        lastLoggedHomeKitState = homeKitStateSignature
        dprint("🔐 \(homeKitStateSignature)")
    }

    private var loadingView: some View {
        ZStack {
            SplashView()
            
            // Spinner + messaggio sovrapposto in basso (visibile solo dopo durata minima)
            VStack {
                Spacer()
                
                VStack(spacing: 12) {
                    if !homeKit.isReady || homeKit.isAuthorizationUnknown {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.white)
                    }
                    
                    if loadingTooLong {
                        Text(String(localized: "homekit.loading.slow", defaultValue: "Taking longer than usual. Make sure HomeKit is enabled in iOS Settings."))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                            .transition(.opacity)

                        Button {
                            openSettings()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "gearshape.fill")
                                Text(String(localized: "homekit.action.openSettings", defaultValue: "Open Settings"))
                            }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color(red: 0.95, green: 0.30, blue: 0.25))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(.white))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .animation(.easeInOut, value: loadingTooLong)
                .padding(.bottom, 70)
            }
        }
    }
    
    // MARK: - Denied
    
    private var deniedView: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(BrandColor.primary)
            
            VStack(spacing: 12) {
                Text(String(localized: "homekit.denied.title", defaultValue: "HomeKit access not granted"))
                    .font(.title2.weight(.semibold))

                Text(String(localized: "homekit.denied.message", defaultValue: "To view and control your accessories, HomeFloorplan needs access to HomeKit. You can grant it from iOS Settings at any time."))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Button {
                openSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                    Text(String(localized: "homekit.action.openSettings", defaultValue: "Open Settings"))
                }
                .font(.body.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(
                    Capsule()
                        .fill(Color.accentColor)
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(.systemBackground))
    }
    
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
