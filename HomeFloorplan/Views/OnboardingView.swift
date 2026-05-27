import SwiftUI
import HomeKit

/// Onboarding multi-step mostrato al primo lancio.
/// Le slide si adattano al contesto (es. step casa solo se HomeKit attivato).
/// Lo step corrente è persistito in UserDefaults così l'utente non riparte da capo.
struct OnboardingView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(OnboardingService.self) private var onboarding
    
    @State private var permissionsRequested: Bool = false
    @AppStorage("onboardingCurrentStep") private var currentStepRaw: Int = 0
    
    private var currentStep: OnboardingStep {
        get { OnboardingStep(rawValue: currentStepRaw) ?? .welcome }
        nonmutating set { currentStepRaw = newValue.rawValue }
    }
    
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case homeSelection = 2
        case ready = 3
    }
    
    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()
            
            VStack {
                progressDots
                    .padding(.top, 20)
                
                Spacer()
                
                Group {
                    switch currentStep {
                    case .welcome:       welcomeStep
                    case .permissions:   permissionsStep
                                            .onAppear {
                                                if !permissionsRequested && !isAuthorized {
                                                    permissionsRequested = true
                                                    homeKit.requestHomeKitAccess()
                                                }
                                            }
                    case .homeSelection: homeSelectionStep
                    case .ready:         readyStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .id(currentStep)
                
                Spacer()
                
                navigationButtons
                    .padding(.horizontal, 32)
                    .padding(.bottom, 40)
            }
        }
    }
    
    // MARK: - Background
    
    private var backgroundGradient: some View {
        BrandColor.heroGradient
    }
    
    // MARK: - Progress dots
    
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(visibleSteps, id: \.rawValue) { step in
                Circle()
                    .fill(step == currentStep
                          ? Color.white
                          : Color.white.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .scaleEffect(step == currentStep ? 1.2 : 1.0)
                    .animation(.spring(response: 0.3), value: currentStep)
            }
        }
    }
    
    /// Step da mostrare (filtra homeSelection se non serve).
    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            if step == .homeSelection {
                return homeKit.isHomeKitActivated && !homeKit.availableHomes.isEmpty
            }
            return true
        }
    }
    
    // MARK: - Welcome
    
    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "house.fill")
                .font(.system(size: 96, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 12) {
                Text("Benvenuto in\nHome Floorplan")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                
                Text("Trasforma le tue planimetrie in pannelli di controllo HomeKit visivi.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
    
    // MARK: - Permissions
    
    private var permissionsStep: some View {
        VStack(spacing: 28) {
            Image(systemName: permissionsIconName)
                .font(.system(size: 80, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 12) {
                Text(permissionsTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                
                Text(permissionsBody)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                
                if !permissionsRequested {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionBullet("Tutto resta sul tuo dispositivo")
                        permissionBullet("Nessun dato condiviso con terze parti")
                        permissionBullet("Solo lettura/scrittura sui tuoi accessori")
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 40)
                }
            }
            
            if shouldShowPermissionButton {
                permissionsActionButton
            }
        }
    }
    
    private var permissionsIconName: String {
        if isAuthorized {
            return "checkmark.shield.fill"
        }
        if homeKit.isAuthorizationDenied {
            return "exclamationmark.shield.fill"
        }
        return "lock.shield.fill"
    }
    
    private var permissionsTitle: String {
        if isAuthorized {
            return "Permessi concessi"
        }
        if homeKit.isAuthorizationDenied {
            return "Permessi negati"
        }
        return "Accesso a HomeKit"
    }
    
    private var permissionsBody: String {
        if isAuthorized {
            return "Tutto pronto. Ora possiamo accedere alla tua configurazione HomeKit."
        }
        if homeKit.isAuthorizationDenied {
            return "Per usare HomeFloorplan devi concedere l'accesso a HomeKit dalle Impostazioni iOS."
        }
        return "Per controllare i tuoi accessori, l'app ha bisogno di accedere ai dati HomeKit. Conferma nel dialogo che appare."
    }
    
    private var shouldShowPermissionButton: Bool {
        homeKit.isAuthorizationDenied
    }
    
    private var isAuthorized: Bool {
        homeKit.authorizationStatus?.contains(.authorized) == true
    }
    
    @ViewBuilder
    private var permissionsActionButton: some View {
        Button {
            openAppSettings()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                Text("Apri Impostazioni")
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(BrandColor.primary)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Capsule().fill(.white))
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
    
    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    
    private func permissionBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white)
                .font(.subheadline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.95))
            Spacer()
        }
    }
    
    // MARK: - Home selection
    
    private var homeSelectionStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "house.lodge.fill")
                .font(.system(size: 80, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 8) {
                Text(homeKit.availableHomes.count > 1
                     ? "Scegli la tua casa"
                     : "Casa attiva")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text(homeKit.availableHomes.count > 1
                     ? "Hai più case configurate in HomeKit. Scegli quella che vuoi gestire con HomeFloorplan."
                     : "Useremo questa casa per gestire i tuoi accessori e le tue planimetrie.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            VStack(spacing: 10) {
                ForEach(homeKit.availableHomes, id: \.uniqueIdentifier) { home in
                    Button {
                        homeKit.setActiveHome(home)
                    } label: {
                        HStack {
                            Image(systemName: "house.fill")
                                .foregroundStyle(homeKit.currentHome?.uniqueIdentifier == home.uniqueIdentifier
                                                 ? BrandColor.primary
                                                 : .white)
                            Text(home.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(homeKit.currentHome?.uniqueIdentifier == home.uniqueIdentifier
                                                 ? BrandColor.primary
                                                 : .white)
                            Spacer()
                            if homeKit.currentHome?.uniqueIdentifier == home.uniqueIdentifier {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(BrandColor.primary)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(homeKit.currentHome?.uniqueIdentifier == home.uniqueIdentifier
                                      ? Color.white
                                      : Color.white.opacity(0.18))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
    }
    
    // MARK: - Ready
    
    private var readyStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 12) {
                Text("Pronto!")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text("Inizia caricando una planimetria della tua casa. Poi posiziona i marker degli accessori HomeKit per controllarli con un tocco.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
    
    // MARK: - Navigation buttons
    
    private var navigationButtons: some View {
        HStack(spacing: 12) {
            if currentStep != visibleSteps.first {
                Button {
                    goPrevious()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
            }
            
            Button {
                goNext()
            } label: {
                HStack {
                    Spacer()
                    Text(isLastStep ? "Inizia" : "Avanti")
                        .font(.body.weight(.semibold))
                    if !isLastStep {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                    }
                    Spacer()
                }
                .foregroundStyle(canProceed
                                 ? BrandColor.primary
                                 : BrandColor.primary.opacity(0.4))
                .frame(height: 56)
                .background(Capsule().fill(canProceed ? .white : Color.white.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .disabled(!canProceed)
        }
    }
    
    private var canProceed: Bool {
        if currentStep == .permissions {
            return isAuthorized
        }
        return true
    }
    
    // MARK: - Navigation logic
    
    private var isLastStep: Bool {
        currentStep == visibleSteps.last
    }
    
    private func goNext() {
        if currentStep == .permissions {
            guard isAuthorized else { return }
        }
        
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if let currentIndex = visibleSteps.firstIndex(of: currentStep),
               currentIndex + 1 < visibleSteps.count {
                currentStep = visibleSteps[currentIndex + 1]
            } else {
                onboarding.markCompleted()
                currentStepRaw = 0  // Reset per future re-visualizzazioni
            }
        }
    }
    
    private func goPrevious() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            if let currentIndex = visibleSteps.firstIndex(of: currentStep),
               currentIndex > 0 {
                currentStep = visibleSteps[currentIndex - 1]
            }
        }
    }
}
