import SwiftUI
import SwiftData
import UIKit
import HomeKit

// MARK: - Touch passthrough observer

/// UIView che osserva i tocchi tramite hitTest senza mai catturarli (ritorna sempre nil).
/// Usata come background per resettare il timer screensaver a livello UIKit,
/// senza interferire con il sistema di gesture recognizer di SwiftUI.
private final class TouchObserverView: UIView {
    var onTouch: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.type == .touches {
            onTouch?()
        }
        // Passa sempre il tocco alle view sottostanti
        return nil
    }
}

/// SwiftUI wrapper per TouchObserverView.
private struct TouchObserver: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> TouchObserverView {
        let view = TouchObserverView()
        view.onTouch = onTouch
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }

    func updateUIView(_ uiView: TouchObserverView, context: Context) {
        uiView.onTouch = onTouch
    }
}

// MARK: - ContentView

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(OnboardingService.self) private var onboarding
    @Environment(IdleTimerService.self) private var idleTimer
    @Environment(HomeKitService.self) private var homeKit

    @AppStorage("primaryFloorplanID") private var primaryFloorplanID: String = ""

    @Query private var floorplans: [Floorplan]

    @State private var selection: SidebarSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// ID of the most recently created floorplan — triggers auto-edit-mode on first display.
    @State private var newlyCreatedFloorplanID: UUID?
    @AppStorage("floorplan_active_overlay_mode") private var floorplanActiveModeRaw: String = FloorplanOverlayMode.controls.rawValue

    @State private var showAlarmOverlay    = false
    @State private var showChatPanel      = false
    @State private var chatKeyboardHeight: CGFloat = 0

    /// FAB is allowed only when NOT inside a non-controls floorplan overlay.
    /// (Environment and Security overlays already have their own panel buttons.)
    private var floorplanFabAllowed: Bool {
        guard case .floorplan = selection else { return true }
        return (FloorplanOverlayMode(rawValue: floorplanActiveModeRaw) ?? .controls) == .controls
    }

    var body: some View {
        Group {
            if onboarding.shouldShowOnboarding {
                OnboardingView()
            } else {
                HomeKitGuardView {
                    mainContent
                }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: onboarding.shouldShowOnboarding)
        // Overlay passthrough UIKit: osserva i tocchi senza catturarli,
        // resetta il timer screensaver su ogni interazione.
        .overlay {
            TouchObserver { idleTimer.resetTimer() }
                .allowsHitTesting(true)
        }
        // Avvia il timer al primo apparire dell'app.
        .onAppear { idleTimer.resetTimer() }
        // Overlay screensaver quando idle e nessuna UI protetta è aperta.
        .overlay {
            if idleTimer.shouldShowScreensaver && !onboarding.shouldShowOnboarding {
                IdleScreensaverView {
                    withAnimation(.easeOut(duration: 0.35)) {
                        idleTimer.dismissScreensaver()
                    }
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: idleTimer.isIdle)
    }
    
    /// Panel height — collapses to fit above the docked keyboard; roomy when keyboard hidden.
    private var chatPanelHeight: CGFloat {
        guard chatKeyboardHeight > 0 else { return 640 }
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
        let screenH = window?.screen.bounds.height ?? 800
        let safeTop = window?.safeAreaInsets.top ?? 20
        // screenH - keyboardH - safeTop - 20(padding top) - 20(bottom gap)
        return max(300, screenH - chatKeyboardHeight - safeTop - 40)
    }

    private var chatPanelWidth: CGFloat {
        let window = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
        let screenW = window?.screen.bounds.width ?? 430
        let horizontalPadding: CGFloat = 40
        return min(max(430, screenW * 0.42), min(640, screenW - horizontalPadding))
    }

    private var mainContent: some View {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(selection: $selection, onFloorplanCreated: { id in
                    newlyCreatedFloorplanID = id
                })
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
            } detail: {
                detailView
            }
            .navigationSplitViewStyle(.balanced)
            // Chat panel — fixed top-trailing, completely isolated from keyboard repositioning
            .overlay(alignment: .topTrailing) {
                if showChatPanel {
                    ChatBotView()
                        .frame(width: chatPanelWidth, height: chatPanelHeight)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 28, x: -4, y: 10)
                        .padding(.top, 20)
                        .padding(.trailing, 20)
                        .ignoresSafeArea(.keyboard)
                        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: chatPanelHeight)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: showChatPanel)
            .overlay(alignment: .bottomTrailing) {
                if floorplanFabAllowed && chatKeyboardHeight == 0 {
                    ChatFABButtonView(showChat: $showChatPanel)
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .bottomTrailing)))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: floorplanFabAllowed)
            .animation(.easeInOut(duration: 0.18), value: chatKeyboardHeight > 0)
            .task {
                // Controlla lo stato iniziale: se l'allarme era già triggered prima
                // che mainContent comparisse, .onChange non scatterebbe.
                if homeKit.isAlarmSystemTriggered { showAlarmOverlay = true }
            }
            .onChange(of: homeKit.isAlarmSystemTriggered) { _, triggered in
                if triggered { showAlarmOverlay = true }
            }
            .fullScreenCover(isPresented: $showAlarmOverlay) {
                AlarmTriggeredView()
            }
            .onAppear {
                resolveInitialSelectionIfNeeded()
            }
            .onChange(of: floorplans.map(\.id)) { _, _ in
                resolveInitialSelectionIfNeeded()
            }
            .onChange(of: showChatPanel) { _, visible in
                if !visible { chatKeyboardHeight = 0 }
            }
            .suppressesIdleScreensaver(.chatPanel, when: showChatPanel)
            .suppressesIdleScreensaver(.alarmOverlay, when: showAlarmOverlay)
            // Track docked keyboard height so the chat panel shrinks above it.
            .task {
                for await notif in NotificationCenter.default.notifications(named: UIResponder.keyboardWillShowNotification) {
                    guard showChatPanel else { continue }
                    guard let frame = notif.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { continue }
                    // Ignore floating keyboard (not anchored at screen bottom)
                    let screenH = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
                        .windows.first?.screen.bounds.height ?? 800
                    guard frame.maxY >= screenH - 10 else { continue }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        chatKeyboardHeight = frame.height
                    }
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: UIResponder.keyboardWillHideNotification) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        chatKeyboardHeight = 0
                    }
                }
            }
        }
    
    private func resolveInitialSelectionIfNeeded() {
        guard selection == nil else { return }

        let homeUUID = homeKit.currentHome?.uniqueIdentifier
        let homeFiltered = floorplans.filter { $0.homeUUID == nil || $0.homeUUID == homeUUID }
        guard !homeFiltered.isEmpty else {
            selection = .allFloorplans
            return
        }

        let primaryID = UUID(uuidString: primaryFloorplanID)
        let target = homeFiltered.first(where: { $0.id == primaryID }) ?? homeFiltered.first
        if let target {
            if primaryFloorplanID.isEmpty {
                primaryFloorplanID = target.id.uuidString
            }
            selection = .floorplan(target.id)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .floorplan(let id):
            if let floorplan = floorplans.first(where: { $0.id == id }) {
                let isNew = newlyCreatedFloorplanID == id
                FloorplanEditorView(
                    floorplan: floorplan,
                    columnVisibility: $columnVisibility,
                    onSelectFloorplan: { selectedID in
                        selection = .floorplan(selectedID)
                    },
                    presentationStyle: .splitView,
                    startInEditMode: isNew
                )
                .toolbar(.hidden, for: .navigationBar)
                .onAppear {
                    // Clear the flag after first display so returning to this
                    // floorplan later doesn't re-enter edit mode.
                    if isNew { newlyCreatedFloorplanID = nil }
                }
            } else {
                emptyState(
                    title: String(localized: "content.floorplan.notFound.title", defaultValue: "Floorplan not found"),
                    message: String(localized: "content.floorplan.notFound.message", defaultValue: "Choose another item from the sidebar to continue.")
                )
            }
        case .allFloorplans:
            FloorplanListView(columnVisibility: $columnVisibility)
                .toolbar(removing: .sidebarToggle)
        case .allAccessories:
            AccessoriesTabView()
        case .scenes:
            ScenesView()
        case .automations:
            NavigationStack {
                AutomationsView()
            }
        case .activityLog:
            NavigationStack {
                ActivityLogView()
            }
        case .security:
            SecurityView()
        case .environment:
            EnvironmentDashboardView()
        case .habits:
            HabitsView()
        case .homeIntelligence:
            HomeIntelligenceDashboardView()
        case .debugHomeKit:
            NavigationStack {
                HomeKitDebugView()
            }
        case .settings:
            NavigationStack {
                SettingsView()
            }
        case .none:
            emptyState(
                title: String(localized: "content.empty.title", defaultValue: "Select a section"),
                message: String(localized: "content.empty.message", defaultValue: "Choose an item from the sidebar to get started.")
            )
        }
    }
    
    @ViewBuilder
    private func emptyState(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "square.dashed")
        } description: {
            Text(message)
        }
    }
}

// MARK: - ChatFABButtonView

/// Floating action button that opens ChatBotView as a popover,
/// styled to match the OverlayPanelMarkerButton in the floorplan overlay.
/// The outer ring uses the same rotating rainbow gradient as the chat input field.
private struct ChatFABButtonView: View {
    @Binding var showChat: Bool
    @State private var startDate = Date()

    private static let gradientColors: [Color] = [
        Color(hue: 0.76, saturation: 0.80, brightness: 0.90),
        Color(hue: 0.62, saturation: 0.85, brightness: 0.95),
        Color(hue: 0.52, saturation: 0.78, brightness: 0.92),
        Color(hue: 0.42, saturation: 0.70, brightness: 0.88),
        Color(hue: 0.14, saturation: 0.82, brightness: 0.97),
        Color(hue: 0.06, saturation: 0.85, brightness: 0.92),
        Color(hue: 0.93, saturation: 0.78, brightness: 0.92),
        Color(hue: 0.76, saturation: 0.80, brightness: 0.90),
    ]

    var body: some View {
        Button { showChat.toggle() } label: {
            VStack(spacing: 5) {
                if showChat {
                    // Animated ring at 60 fps while chat panel is open.
                    TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                        let phase = context.date.timeIntervalSince(startDate)
                            .truncatingRemainder(dividingBy: 3.0) / 3.0
                        ringContent(gradient: makeGradient(phase: phase))
                    }
                } else {
                    // Static ring when chat is closed — zero GPU/CPU cost.
                    ringContent(gradient: makeGradient(phase: 0))
                }

                // High-contrast label — readable on both dark and light floorplan backgrounds
                Text(String(localized: "agent.fab.label", defaultValue: "Home AI"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.50), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "agent.fab.accessibility", defaultValue: "Home assistant"))
    }

    private func makeGradient(phase: Double) -> AngularGradient {
        AngularGradient(
            colors: Self.gradientColors,
            center: .center,
            startAngle: .degrees(phase * 360),
            endAngle:   .degrees(phase * 360 + 360)
        )
    }

    private func ringContent(gradient: AngularGradient) -> some View {
        ZStack {
            Circle()
                .stroke(gradient, lineWidth: 2.5)
                .frame(width: 62, height: 62)
                .blur(radius: 0.8)
            Circle()
                .fill(.regularMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .frame(width: 50, height: 50)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(gradient)
        }
    }
}
