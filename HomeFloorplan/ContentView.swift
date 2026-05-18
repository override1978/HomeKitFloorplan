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
                    columnVisibility: $columnVisibility
                )
                .toolbar(.hidden, for: .navigationBar)
            } else {
                emptyState(text: "Planimetria non trovata")
            }
        case .allAccessories:
            // Placeholder per la futura vista "tutti gli accessori"
            NavigationStack {
                AllAccessoriesPlaceholderView()
            }
        case .debugHomeKit:
            NavigationStack {
                HomeKitDebugView()
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

/// Placeholder per la futura vista "Tutti gli accessori"
struct AllAccessoriesPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Tutti gli accessori", systemImage: "square.grid.2x2")
        } description: {
            Text("Vista in arrivo: elenco completo degli accessori HomeKit con stato live.")
        }
        .navigationTitle("Accessori")
    }
}
