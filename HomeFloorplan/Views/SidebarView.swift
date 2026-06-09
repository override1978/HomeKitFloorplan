import SwiftUI
import SwiftData
import HomeKit

/// Sidebar principale dell'app.
/// Sezioni: Header branding, Panoramica, Planimetrie (gestione + accesso rapido), Impostazioni.
/// Le sezioni sono collassabili e lo stato viene persisto in UserDefaults.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(HomeKitService.self) private var homeKit
    @Environment(IdleTimerService.self) private var idleTimer
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var allFloorplans: [Floorplan]

    /// Selezione corrente, gestita dal parent (ContentView) tramite NavigationSplitView
    @Binding var selection: SidebarSelection?

    /// Called when a new floorplan is successfully created; receives the new floorplan UUID.
    var onFloorplanCreated: ((UUID) -> Void)?

    @AppStorage("primaryFloorplanID")   private var primaryFloorplanID:    String = ""
    /// JSON array di UUID strings delle planimetrie pinnate (include anche la principale).
    @AppStorage("pinnedFloorplanIDs")  private var pinnedFloorplanIDsRaw: String = "[]"

    // Stato espansione sezioni (persiste tra sessioni)
    @AppStorage("sidebar.section.floorplans.expanded") private var floorplansExpanded: Bool = true
    @AppStorage("sidebar.section.analysis.expanded")   private var analysisExpanded:   Bool = true
    @AppStorage("sidebar.section.scenes.expanded")     private var scenesExpanded:     Bool = true
    @AppStorage("sidebar.section.settings.expanded")   private var settingsExpanded:   Bool = true
    @AppStorage("ai.isEnabled")                        private var isAIEnabled:        Bool = false

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

    private func decodePinnedIDs() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(pinnedFloorplanIDsRaw.utf8))) ?? []
    }

    private func encodePinnedIDs(_ ids: [String]) {
        pinnedFloorplanIDsRaw = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
    }

    /// Planimetrie pinnate: prima la principale (se esiste), poi le altre in ordine.
    private var pinnedFloorplans: [Floorplan] {
        let ids = decodePinnedIDs()
        guard !ids.isEmpty else { return [] }
        let matched = ids.compactMap { idStr -> Floorplan? in
            guard let uuid = UUID(uuidString: idStr) else { return nil }
            return floorplans.first(where: { $0.id == uuid })
        }
        // Principale sempre prima
        let primary = matched.first(where: { $0.id.uuidString == primaryFloorplanID })
        let rest    = matched.filter    { $0.id.uuidString != primaryFloorplanID }
        return (primary.map { [$0] } ?? []) + rest
    }

    private func isPinned(_ floorplan: Floorplan) -> Bool {
        decodePinnedIDs().contains(floorplan.id.uuidString)
    }

    private func pinFloorplan(_ floorplan: Floorplan) {
        var ids = decodePinnedIDs()
        let key = floorplan.id.uuidString
        guard !ids.contains(key) else { return }
        ids.append(key)
        encodePinnedIDs(ids)
    }

    private func unpinFloorplan(_ floorplan: Floorplan) {
        let key = floorplan.id.uuidString
        encodePinnedIDs(decodePinnedIDs().filter { $0 != key })
        if primaryFloorplanID == key { primaryFloorplanID = "" }
    }

    private func setPrimary(_ floorplan: Floorplan) {
        // La principale è sempre anche pinnata
        pinFloorplan(floorplan)
        primaryFloorplanID = floorplan.id.uuidString
    }

    var body: some View {
        List(selection: $selection) {
            // MARK: Header branding
            Section {
                appHeader
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            // MARK: Planimetrie — Nuova + pinnate
            Section {
                DisclosureGroup(isExpanded: $floorplansExpanded) {
                    Button {
                        showingNewFloorplan = true
                    } label: {
                        Label(String(localized: "sidebar.newFloorplan", defaultValue: "Nuova planimetria"), systemImage: "plus.rectangle.on.rectangle")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    NavigationLink(value: SidebarSelection.allFloorplans) {
                        Label(String(localized: "sidebar.allFloorplans", defaultValue: "Tutte le planimetrie"), systemImage: "rectangle.stack")
                    }
                    ForEach(pinnedFloorplans) { floorplan in
                        pinnedRow(floorplan)
                    }
                } label: {
                    Text(String(localized: "sidebar.section.floorplans", defaultValue: "Planimetrie"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if pinnedFloorplans.isEmpty && floorplansExpanded {
                    Text(String(localized: "sidebar.pinned.empty.hint", defaultValue: "Vai in \"Tutte le planimetrie\", tieni premuto su una e scegli \"Aggiungi ad Accesso rapido\"."))
                }
            }

            // MARK: Analisi — Ambiente, Sicurezza, Abitudini, Intelligenza
            Section {
                DisclosureGroup(isExpanded: $analysisExpanded) {
                    NavigationLink(value: SidebarSelection.environment) {
                        Label(String(localized: "sidebar.environment", defaultValue: "Ambiente"), systemImage: "leaf.fill")
                    }
                    NavigationLink(value: SidebarSelection.security) {
                        Label(String(localized: "sidebar.security", defaultValue: "Sicurezza"), systemImage: "shield.lefthalf.filled")
                    }
                    if isAIEnabled {
                        NavigationLink(value: SidebarSelection.homeIntelligence) {
                            Label(String(localized: "sidebar.intelligence", defaultValue: "Intelligenza"), systemImage: "sparkles.rectangle.stack")
                        }
                    }
                } label: {
                    Text(String(localized: "sidebar.section.analysis", defaultValue: "Analisi"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Scene & Automazioni — con Accessori e Log
            Section {
                DisclosureGroup(isExpanded: $scenesExpanded) {
                    NavigationLink(value: SidebarSelection.allAccessories) {
                        Label(String(localized: "sidebar.accessories", defaultValue: "Accessori"), systemImage: "square.grid.2x2")
                    }
                    NavigationLink(value: SidebarSelection.scenes) {
                        Label(String(localized: "sidebar.scenes", defaultValue: "Scene"), systemImage: "wand.and.sparkles")
                    }
                    NavigationLink(value: SidebarSelection.automations) {
                        Label(String(localized: "sidebar.automations", defaultValue: "Automazioni"), systemImage: "gearshape.2")
                    }
                    NavigationLink(value: SidebarSelection.activityLog) {
                        Label(String(localized: "sidebar.activityLog", defaultValue: "Log Attività"), systemImage: "clock.arrow.circlepath")
                    }
                } label: {
                    Text(String(localized: "sidebar.section.scenesAndAutomations", defaultValue: "Scene & Automazioni"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Impostazioni
            Section {
                DisclosureGroup(isExpanded: $settingsExpanded) {
                    NavigationLink(value: SidebarSelection.settings) {
                        Label(String(localized: "sidebar.settings", defaultValue: "Impostazioni"), systemImage: "gearshape")
                    }
                    NavigationLink(value: SidebarSelection.debugHomeKit) {
                        Label("Debug HomeKit", systemImage: "stethoscope")
                    }
                } label: {
                    Text(String(localized: "sidebar.section.settings", defaultValue: "Impostazioni"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(BrandColor.subtleGradient)
        .tint(BrandColor.primary)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                EmptyView()
            }
        }
        .safeAreaInset(edge: .bottom) {
            homeHint
        }
        .sheet(isPresented: $showingNewFloorplan) {
            NewFloorplanSheet(onSaved: { newID in
                idleTimer.resetTimer()
                onFloorplanCreated?(newID)
                withAnimation(.spring(response: 0.4)) {
                    selection = .floorplan(newID)
                }
            })
        }
        .alert(String(localized: "sidebar.alert.deleteFloorplan.title", defaultValue: "Eliminare la planimetria?"),
               isPresented: Binding(
                get: { pendingDeleteFloorplan != nil },
                set: { if !$0 { pendingDeleteFloorplan = nil } }
               ),
               presenting: pendingDeleteFloorplan) { floorplan in
            Button(String(localized: "sidebar.alert.deleteFloorplan.confirm", defaultValue: "Elimina"), role: .destructive) {
                deleteFloorplan(floorplan)
            }
            Button(String(localized: "sidebar.alert.cancel", defaultValue: "Annulla"), role: .cancel) {}
        } message: { _ in
            Text(String(localized: "sidebar.alert.deleteFloorplan.message", defaultValue: "L'immagine e tutti i marker piazzati saranno persi. Gli accessori restano in HomeKit."))
        }
    }

    // MARK: - App header

    private var appHeader: some View {
        HStack(spacing: 12) {
            Image("HomeFloorplanIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("Home Floorplan")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(String(localized: "splash.tagline", defaultValue: "La tua casa, a colpo d'occhio"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Bottom hint (casa attiva)

    @ViewBuilder
    private var homeHint: some View {
        if let home = homeKit.currentHome {
            VStack(spacing: 0) {
                Divider().opacity(0.4)
                Button {
                    selection = .settings
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "house.fill")
                            .foregroundStyle(BrandColor.primary)
                            .font(.subheadline)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(localized: "settings.homekit.activeHome", defaultValue: "Casa attiva"))
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
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(BrandColor.primary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
            .background(.regularMaterial)
        }
    }

    // MARK: - Pinned floorplan row

    @ViewBuilder
    private func pinnedRow(_ floorplan: Floorplan) -> some View {
        let isPrimary = floorplan.id.uuidString == primaryFloorplanID
        NavigationLink(value: SidebarSelection.floorplan(floorplan.id)) {
            HStack(spacing: 10) {
                if isPrimary {
                    Image(systemName: "star.square.fill")
                        .foregroundStyle(AnyShapeStyle(Color.yellow))
                        .frame(width: 22)
                } else {
                    Image(systemName: "pin.circle.fill")
                        .foregroundStyle(AnyShapeStyle(BrandColor.primary))
                        .frame(width: 22)
                }
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
            if !isPrimary {
                Button {
                    setPrimary(floorplan)
                } label: {
                    Label(String(localized: "sidebar.pinned.setMain", defaultValue: "Imposta come principale"), systemImage: "star.fill")
                }
            } else {
                Button {
                    primaryFloorplanID = ""
                } label: {
                    Label(String(localized: "sidebar.pinned.removeMain", defaultValue: "Rimuovi da principale"), systemImage: "star.slash")
                }
            }
            Button {
                unpinFloorplan(floorplan)
            } label: {
                Label(String(localized: "sidebar.pinned.remove", defaultValue: "Rimuovi da Accesso rapido"), systemImage: "pin.slash")
            }
            Divider()
            Button(role: .destructive) {
                pendingDeleteFloorplan = floorplan
            } label: {
                Label(String(localized: "sidebar.action.delete", defaultValue: "Elimina"), systemImage: "trash")
            }
        }
    }

    // MARK: - Delete

    private func deleteFloorplan(_ floorplan: Floorplan) {
        if case .floorplan(let id) = selection, id == floorplan.id {
            selection = nil
        }
        unpinFloorplan(floorplan)
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
    case automations
    case activityLog
    case security
    case environment
    case habits
    case homeIntelligence
    case debugHomeKit
    case settings
}
