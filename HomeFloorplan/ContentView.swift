import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var floorplans: [Floorplan]
    
    @State private var selection: SidebarSelection?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 320)
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            // All'avvio, se non c'è selezione e c'è almeno un floorplan, selezionalo
            if selection == nil, let first = floorplans.first {
                selection = .floorplan(first.id)
            }
        }
    }
    
    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .floorplan(let id):
            if let floorplan = floorplans.first(where: { $0.id == id }) {
                FloorplanEditorView(
                    floorplan: floorplan,
                    columnVisibility: $columnVisibility,
                    presentationStyle: .splitView
                )
                .toolbar(.hidden, for: .navigationBar)
            } else {
                emptyState(text: "Planimetria non trovata")
            }
        case .allFloorplans:
            FloorplanListView(columnVisibility: $columnVisibility)
                .toolbar(removing: .sidebarToggle)
        case .allAccessories:
            NavigationStack {
                AllAccessoriesView()
            }
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

