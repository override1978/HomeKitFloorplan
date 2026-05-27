import SwiftUI
import SwiftData

@main
struct HomeFloorplanApp: App {
    
    @State private var homeKit = HomeKitService()
    @State private var iconOverrides = IconOverrideStore()
    @State private var scenesService: HomeKitScenesService
    @State private var onboarding = OnboardingService()
    
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Floorplan.self,
            PlacedAccessory.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()
    
    init() {
        let kit = HomeKitService()
        self._homeKit = State(initialValue: kit)
        self._scenesService = State(initialValue: HomeKitScenesService(homeKit: kit))
        
        print("🏠 RoomPlan supported: \(RoomPlanSupport.isSupported)")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(homeKit)
                .environment(iconOverrides)
                .environment(scenesService)
                .environment(onboarding)                            // 👈 NUOVO
        }
        .modelContainer(sharedModelContainer)
    }
}
