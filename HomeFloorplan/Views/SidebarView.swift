import SwiftUI
import SwiftData

/// Sidebar principale dell'app, pattern Casa/Eve.
/// Sezioni: Planimetrie, Viste, Strumenti.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var floorplans: [Floorplan]
    
    /// Selezione corrente, gestita dal parent (ContentView) tramite NavigationSplitView
    @Binding var selection: SidebarSelection?
    
    @State private var showingNewFloorplan = false
    @State private var pendingDeleteFloorplan: Floorplan?
    
    var body: some View {
        List(selection: $selection) {
            // SEZIONE PLANIMETRIE
            Section {
                ForEach(floorplans) { floorplan in
                    NavigationLink(value: SidebarSelection.floorplan(floorplan.id)) {
                        HStack(spacing: 10) {
                            Image(systemName: "square.dashed")
                                .foregroundStyle(.tint)
                                .frame(width: 22)
                            Text(floorplan.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(floorplan.accessories.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            pendingDeleteFloorplan = floorplan
                        } label: {
                            Label("Elimina", systemImage: "trash")
                        }
                    }
                }
                
                Button {
                    showingNewFloorplan = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        Text("Nuova planimetria")
                            .foregroundStyle(.tint)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            } header: {
                Text("Planimetrie")
            }
            
            // SEZIONE VISTE
            Section {
                NavigationLink(value: SidebarSelection.allFloorplans) {
                        Label("Tutte le planimetrie", systemImage: "rectangle.stack")
                    }
                NavigationLink(value: SidebarSelection.allAccessories) {
                    Label("Tutti gli accessori", systemImage: "square.grid.2x2")
                }
            } header: {
                Text("Viste")
            }
            
            // SEZIONE STRUMENTI
            Section {
                NavigationLink(value: SidebarSelection.debugHomeKit) {
                    Label("Debug HomeKit", systemImage: "stethoscope")
                }
                NavigationLink(value: SidebarSelection.settings) {
                        Label("Impostazioni", systemImage: "gearshape")
                    }
            } header: {
                Text("Strumenti")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Home Floorplan")
        .sheet(isPresented: $showingNewFloorplan) {
            NewFloorplanSheet()
        }
        .alert("Eliminare la planimetria?",
               isPresented: Binding(
                get: { pendingDeleteFloorplan != nil },
                set: { if !$0 { pendingDeleteFloorplan = nil } }
               ),
               presenting: pendingDeleteFloorplan) { floorplan in
            Button("Elimina", role: .destructive) {
                deleteFloorplan(floorplan)
            }
            Button("Annulla", role: .cancel) {}
        } message: { _ in
            Text("L'immagine e tutti i marker piazzati saranno persi. Gli accessori restano in HomeKit.")
        }
    }
    
    private func deleteFloorplan(_ floorplan: Floorplan) {
        // Se stiamo eliminando il floorplan correntemente selezionato, deseleziona
        if case .floorplan(let id) = selection, id == floorplan.id {
            selection = nil
        }
        ImageStorageService.delete(filename: floorplan.imageFilename)
        modelContext.delete(floorplan)
        try? modelContext.save()
    }
}

/// Identifica cosa è selezionato in sidebar.
/// Hashable + Codable per integrarsi con NavigationSplitView.
enum SidebarSelection: Hashable {
    case floorplan(UUID)
        case allFloorplans       // <-- nuovo
        case allAccessories
        case debugHomeKit
        case settings
}
