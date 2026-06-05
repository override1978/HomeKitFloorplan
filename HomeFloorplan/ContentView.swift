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
        // Overlay screensaver quando idle
        .overlay {
            if idleTimer.isIdle && !onboarding.shouldShowOnboarding {
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
    
    // 👇 estrai NavigationSplitView in computed
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
            .onAppear {
                if selection == nil {
                    let homeUUID = homeKit.currentHome?.uniqueIdentifier
                    let homeFiltered = floorplans.filter { $0.homeUUID == nil || $0.homeUUID == homeUUID }
                    let primaryID = UUID(uuidString: primaryFloorplanID)
                    let target = homeFiltered.first(where: { $0.id == primaryID }) ?? homeFiltered.first
                    if let target { selection = .floorplan(target.id) }
                }
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
                emptyState(text: "Planimetria non trovata")
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
        case .debugHomeKit:
            NavigationStack {
                HomeKitDebugView()
            }
        case .settings:
            NavigationStack {
                SettingsView()
            }
        case .none:
            emptyState(text: "Seleziona una planimetria")
        }
    }
    
    @ViewBuilder
    private func emptyState(text: String) -> some View {
        ContentUnavailableView {
            Label(text, systemImage: "square.dashed")
        } description: {
            Text("Scegli un elemento dalla sidebar per iniziare.")
        }
    }
}

