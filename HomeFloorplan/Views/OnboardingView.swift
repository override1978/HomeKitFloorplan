import SwiftUI
import HomeKit

/// Onboarding multi-step mostrato al primo lancio.
/// Le slide si adattano al contesto (es. step casa solo se HomeKit attivato).
/// Lo step corrente è persistito in UserDefaults così l'utente non riparte da capo.
struct OnboardingView: View {
    @Environment(HomeKitService.self) private var homeKit
    @Environment(OnboardingService.self) private var onboarding
    
    @AppStorage("onboardingCurrentStep") private var currentStepRaw: Int = 0
    
    private var currentStep: OnboardingStep {
        get { OnboardingStep(rawValue: currentStepRaw) ?? .welcome }
        nonmutating set { currentStepRaw = newValue.rawValue }
    }
    
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case permissions = 1
        case homeStatus = 2
        case firstFloorplan = 3
        case intelligence = 4
        case ready = 5
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
                    case .welcome:        welcomeStep
                    case .permissions:    permissionsStep
                    case .homeStatus:     homeStatusStep
                    case .firstFloorplan: firstFloorplanStep
                    case .intelligence:   intelligenceStep
                    case .ready:          readyStep
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
    
    private var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases
    }
    
    // MARK: - Welcome
    
    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "house.fill")
                .font(.system(size: 96, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 12) {
                Text(String(localized: "onboarding.welcome.title", defaultValue: "Welcome to\nHome Floorplan"))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                
                Text(String(localized: "onboarding.welcome.body", defaultValue: "Turn your floorplans into visual HomeKit control panels."))
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
                
                if !isAuthorized {
                    VStack(alignment: .leading, spacing: 12) {
                        permissionBullet(String(localized: "onboarding.permissions.bullet.local", defaultValue: "Your HomeKit data stays under your control"))
                        permissionBullet(String(localized: "onboarding.permissions.bullet.accessories", defaultValue: "The app reads and controls your own accessories"))
                        permissionBullet(String(localized: "onboarding.permissions.bullet.optional", defaultValue: "Smart features remain optional and can be configured later"))
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
            return String(localized: "onboarding.permissions.granted.title", defaultValue: "HomeKit access granted")
        }
        if homeKit.isAuthorizationDenied {
            return String(localized: "onboarding.permissions.denied.title", defaultValue: "HomeKit access denied")
        }
        return String(localized: "onboarding.permissions.title", defaultValue: "Connect HomeKit")
    }
    
    private var permissionsBody: String {
        if isAuthorized {
            return String(localized: "onboarding.permissions.granted.body", defaultValue: "You're ready to use your HomeKit homes, rooms, and accessories inside Home Floorplan.")
        }
        if homeKit.isAuthorizationDenied {
            return String(localized: "onboarding.permissions.denied.body", defaultValue: "To use Home Floorplan, allow HomeKit access from iOS Settings.")
        }
        return String(localized: "onboarding.permissions.body", defaultValue: "Home Floorplan needs HomeKit access to show your rooms and control your accessories.")
    }
    
    private var shouldShowPermissionButton: Bool {
        !isAuthorized
    }
    
    private var isAuthorized: Bool {
        homeKit.authorizationStatus?.contains(.authorized) == true
    }
    
    @ViewBuilder
    private var permissionsActionButton: some View {
        Button {
            if homeKit.isAuthorizationDenied {
                openAppSettings()
            } else {
                homeKit.requestHomeKitAccess()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: homeKit.isAuthorizationDenied ? "gearshape.fill" : "lock.open.fill")
                Text(homeKit.isAuthorizationDenied
                     ? String(localized: "onboarding.permissions.openSettings", defaultValue: "Open Settings")
                     : String(localized: "onboarding.permissions.grantAccess", defaultValue: "Grant HomeKit Access"))
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
    
    // MARK: - Home status
    
    private var homeStatusStep: some View {
        VStack(spacing: 24) {
            Image(systemName: homeStatusIconName)
                .font(.system(size: 80, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 8) {
                Text(homeStatusTitle)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text(homeStatusBody)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            
            if homeKit.availableHomes.count > 1 {
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
            } else if let home = homeKit.availableHomes.first {
                activeHomeCard(homeName: home.name)
                    .frame(maxWidth: 430)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)
            } else if homeKit.availableHomes.isEmpty {
                Button {
                    openAppSettings()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "gearshape.fill")
                        Text(String(localized: "onboarding.home.openSettings", defaultValue: "Open Settings"))
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
        }
    }

    private func activeHomeCard(homeName: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "onboarding.home.active.label", defaultValue: "Active home"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Text(homeName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }

    private var homeStatusIconName: String {
        homeKit.availableHomes.isEmpty ? "house.slash.fill" : "house.lodge.fill"
    }

    private var homeStatusTitle: String {
        if homeKit.availableHomes.isEmpty {
            return String(localized: "onboarding.home.none.title", defaultValue: "No HomeKit home found")
        }
        if homeKit.availableHomes.count > 1 {
            return String(localized: "onboarding.home.choose.title", defaultValue: "Choose your home")
        }
        return String(localized: "onboarding.home.active.title", defaultValue: "Home ready")
    }

    private var homeStatusBody: String {
        if homeKit.availableHomes.isEmpty {
            return String(localized: "onboarding.home.none.body", defaultValue: "Create or configure a home in Apple Home, then return here. You can still continue and set it up later.")
        }
        if homeKit.availableHomes.count > 1 {
            return String(localized: "onboarding.home.choose.body", defaultValue: "You have multiple HomeKit homes. Pick the one you want to manage with Home Floorplan.")
        }
        return String(localized: "onboarding.home.active.body", defaultValue: "This home will be used for your accessories, rooms, and floorplans.")
    }

    // MARK: - First floorplan

    private var firstFloorplanStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "square.dashed.inset.filled")
                .font(.system(size: 88, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.floorplan.title", defaultValue: "Create your first floorplan"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(String(localized: "onboarding.floorplan.body", defaultValue: "Draw your rooms, link them to HomeKit rooms, then place accessories exactly where they are in your home."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 10) {
                    onboardingFeatureRow(
                        icon: "pencil.and.ruler.fill",
                        text: String(localized: "onboarding.floorplan.bullet.draw", defaultValue: "Visualize your home on an interactive floorplan")
                    )
                    onboardingFeatureRow(
                        icon: "rectangle.3.group.fill",
                        text: String(localized: "onboarding.floorplan.bullet.rooms", defaultValue: "Get smarter environment and security insights, room by room")
                    )
                    onboardingFeatureRow(
                        icon: "dot.circle.and.hand.point.up.left.fill",
                        text: String(localized: "onboarding.floorplan.bullet.markers", defaultValue: "Control every accessory with a tap, right on the map")
                    )
                    onboardingFeatureRow(
                        icon: "theatermask.and.paintbrush.fill",
                        text: String(localized: "onboarding.floorplan.bullet.scenes", defaultValue: "Design and activate scenes in seconds")
                    )
                    onboardingFeatureRow(
                        icon: "bolt.horizontal.fill",
                        text: String(localized: "onboarding.floorplan.bullet.automations", defaultValue: "Build powerful automations with a guided wizard")
                    )
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 32)
                .padding(.top, 14)
            }
        }
    }

    // MARK: - Intelligence

    private var intelligenceStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 84, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

            VStack(spacing: 12) {
                Text(String(localized: "onboarding.intelligence.title", defaultValue: "Optional: unlock Home Intelligence"))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(String(localized: "onboarding.intelligence.body", defaultValue: "Home Floorplan works without AI. If you enable Home Intelligence later, it adds a smarter layer on top of your home."))
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                VStack(spacing: 10) {
                    onboardingFeatureRow(
                        icon: "chart.line.uptrend.xyaxis",
                        text: String(localized: "onboarding.intelligence.benefit.patterns", defaultValue: "Spot patterns in habits and accessory use")
                    )
                    onboardingFeatureRow(
                        icon: "leaf.arrow.triangle.circlepath",
                        text: String(localized: "onboarding.intelligence.benefit.environment", defaultValue: "Summarize environmental changes by room")
                    )
                    onboardingFeatureRow(
                        icon: "wand.and.sparkles",
                        text: String(localized: "onboarding.intelligence.benefit.actions", defaultValue: "Suggest automations and explain what needs attention")
                    )
                }
                .frame(maxWidth: 430)
                .padding(.horizontal, 32)
                .padding(.top, 8)

                Text(String(localized: "onboarding.intelligence.footer", defaultValue: "You can configure this later in Settings."))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
            }
        }
    }

    private func onboardingFeatureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white))

            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }
    
    // MARK: - Ready
    
    private var readyStep: some View {
        VStack(spacing: 28) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 96, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            
            VStack(spacing: 12) {
                Text(String(localized: "onboarding.ready.title", defaultValue: "You're ready"))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                
                Text(String(localized: "onboarding.ready.body", defaultValue: "Start with your first floorplan. The app will open the floorplan gallery so you can create one right away."))
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
                    Text(isLastStep
                         ? String(localized: "onboarding.action.start", defaultValue: "Start")
                         : String(localized: "onboarding.action.continue", defaultValue: "Continue"))
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
        if currentStep == .homeStatus, homeKit.availableHomes.count > 1 {
            return homeKit.currentHome != nil
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
