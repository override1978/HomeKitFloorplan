import SwiftUI
import SwiftData

@main
struct HomeFloorplanApp: App {
    
    /// Service HomeKit condiviso, vive per tutta la durata dell'app.
    /// @State su un @Observable lo mantiene stabile e propagato via environment.
    @State private var homeKit = HomeKitService()
    
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
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(homeKit)
        }
        .modelContainer(sharedModelContainer)
    }
}
