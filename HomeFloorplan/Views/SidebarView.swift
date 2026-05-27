import SwiftUI
import SwiftData
import HomeKit

/// Sidebar principale dell'app, pattern Casa/Eve.
/// Sezioni: Planimetrie, Viste, Strumenti.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitService.self) private var homeKit                  // 👈 NUOVO
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var allFloorplans: [Floorplan]
    
    /// Selezione corrente, gestita dal parent (ContentView) tramite NavigationSplitView
    @Binding var selection: SidebarSelection?
    
    @State private var showingNewFloorplan = false
    @State private var pendingDeleteFloorplan: Floorplan?
    
    /// Floorplan filtrati per la casa attiva.
    /// I floorplan "legacy" (homeUUID = nil) appaiono in tutte le case per compatibilità.
    private var floorplans: [Floorplan] {
        guard let homeUUID = homeKit.currentHome?.uniqueIdentifier else {
            return allFloorplans
        }
        return allFloorplans.filter { $0.homeUUID == nil || $0.homeUUID == homeUUID }
    }
    
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
                NavigationLink(value: SidebarSelection.scenes) {
                    Label("Scene", systemImage: "wand.and.sparkles")
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
        .scrollContentBackground(.hidden)
        .background(BrandColor.subtleGradient)
        .tint(BrandColor.primary)
        .navigationTitle("Home Floorplan")
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(BrandColor.heroGradient)
                        .font(.headline)
                    Text("Home Floorplan")
                        .font(.headline.weight(.semibold))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            homeHint
        }
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
    
    // MARK: - Home hint
    
    @ViewBuilder
    private var homeHint: some View {
        if let home = homeKit.currentHome {
            Button {
                selection = .settings
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "house.fill")
                        .foregroundStyle(.tint)
                        .font(.subheadline)
                    
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Casa attiva")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(home.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    if homeKit.availableHomes.count > 1 {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.clear)
                /*.overlay(alignment: .top) {
                    Divider().opacity(0.5)
                }*/
            }
            .buttonStyle(.plain)
        }
    }
    
    private func deleteFloorplan(_ floorplan: Floorplan) {
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
    case allFloorplans
    case allAccessories
    case scenes
    case debugHomeKit
    case settings
}
