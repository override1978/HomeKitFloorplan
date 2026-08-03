import SwiftUI
import SwiftData
import HomeKit

// MARK: - CompactHomeView

/// Radice della navigazione a **larghezza compatta** (iPhone).
///
/// Su iPad resta `NavigationSplitView`: la sidebar sta accanto al contenuto e il
/// contenuto è la planimetria, quindi l'app mostra subito ciò che è. Collassata
/// su iPhone quella sidebar diventava la *prima* schermata, e un elenco di
/// destinazioni letto come schermata d'ingresso sembra un menu impostazioni.
///
/// Il primo tentativo fu una tab bar, ma due delle quattro tab erano soltanto
/// elenchi di link: una tab bar montata sopra a delle schermate-indice, cioè due
/// livelli di navigazione dove ne bastava uno. Qui il livello di troppo non c'è:
/// una sola schermata che apre sulle planimetrie e tiene sotto, raggruppate, le
/// stesse destinazioni che su iPad stanno in sidebar.
///
/// Le destinazioni restano descritte da `SidebarSelection`, così iPad e iPhone
/// non divergono su *cosa* è raggiungibile — solo su come ci si arriva.
struct CompactHomeView: View {

    @Environment(HomeKitService.self) private var homeKit
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var allFloorplans: [Floorplan]

    @AppStorage("primaryFloorplanID")    private var primaryFloorplanID:    String = ""
    @AppStorage("pinnedFloorplanIDs")    private var pinnedFloorplanIDsRaw: String = "[]"
    /// Sezione Abitudini (beta): nascosta di default, come in sidebar.
    @AppStorage("habits.sectionVisible") private var areHabitsEnabled:      Bool   = false

    @State private var showingNewFloorplan = false

    // MARK: - Dati

    /// Planimetrie della casa attiva. Le "legacy" (homeUUID nil) valgono per
    /// tutte le case, esattamente come in sidebar.
    private var floorplans: [Floorplan] {
        allFloorplans.filter { homeKit.matchesActiveHome($0.homeUUID) }
    }

    private func decodePinnedIDs() -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(pinnedFloorplanIDsRaw.utf8))) ?? []
    }

    private func isPinned(_ floorplan: Floorplan) -> Bool {
        decodePinnedIDs().contains(floorplan.id.uuidString)
    }

    /// Ordine del carosello: principale, poi le altre pinnate, poi il resto.
    /// È lo stesso criterio dell'"accesso rapido" della sidebar: chi ha già
    /// scelto le sue planimetrie preferite se le ritrova davanti.
    private var carouselFloorplans: [Floorplan] {
        let pinnedIDs = decodePinnedIDs()
        return floorplans.sorted { lhs, rhs in
            func rank(_ floorplan: Floorplan) -> Int {
                if floorplan.id.uuidString == primaryFloorplanID { return 0 }
                if pinnedIDs.contains(floorplan.id.uuidString)   { return 1 }
                return 2
            }
            let (lhsRank, rhsRank) = (rank(lhs), rank(rhs))
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            List {
                if !carouselFloorplans.isEmpty {
                    Section {
                        floorplanCarousel
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                Section {
                    Button {
                        showingNewFloorplan = true
                    } label: {
                        Label(String(localized: "sidebar.newFloorplan", defaultValue: "New Floorplan"),
                              systemImage: "plus.rectangle.on.rectangle")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)

                    destinationRow(.allFloorplans,
                                   title: String(localized: "sidebar.allFloorplans", defaultValue: "All Floorplans"),
                                   icon: "rectangle.stack")
                } header: {
                    Text(String(localized: "sidebar.section.floorplans", defaultValue: "Floorplans"))
                }

                Section {
                    destinationRow(.environment,
                                   title: String(localized: "sidebar.environment", defaultValue: "Environment"),
                                   icon: "leaf.fill")
                    destinationRow(.security,
                                   title: String(localized: "sidebar.security", defaultValue: "Security"),
                                   icon: "shield.lefthalf.filled")
                    destinationRow(.homeIntelligence,
                                   title: String(localized: "sidebar.intelligence", defaultValue: "Intelligence"),
                                   icon: "sparkles.rectangle.stack")
                    if areHabitsEnabled {
                        destinationRow(.habits,
                                       title: String(localized: "sidebar.habits", defaultValue: "Habits"),
                                       icon: "brain.head.profile")
                    }
                } header: {
                    Text(String(localized: "sidebar.section.analysis", defaultValue: "Analysis"))
                }

                Section {
                    destinationRow(.allAccessories,
                                   title: String(localized: "sidebar.accessories", defaultValue: "Accessories"),
                                   icon: "square.grid.2x2")
                    destinationRow(.scenes,
                                   title: String(localized: "sidebar.scenes", defaultValue: "Scenes"),
                                   icon: "wand.and.sparkles")
                    destinationRow(.automations,
                                   title: String(localized: "sidebar.automations", defaultValue: "Automations"),
                                   icon: "gearshape.2")
                } header: {
                    Text(String(localized: "sidebar.section.scenesAndAutomations",
                                defaultValue: "Scenes & Automations"))
                }

                Section {
                    destinationRow(.settings,
                                   title: String(localized: "sidebar.settings", defaultValue: "Settings"),
                                   icon: "gearshape")
#if DEBUG
                    destinationRow(.debugHomeKit,
                                   title: String(localized: "sidebar.debugHomeKit", defaultValue: "HomeKit Debug"),
                                   icon: "stethoscope")
                    destinationRow(.homeIntelligenceDebug,
                                   title: "Intelligence Debug",
                                   icon: "point.3.connected.trianglepath.dotted")
#endif
                } header: {
                    Text(String(localized: "sidebar.section.settings", defaultValue: "Settings"))
                }
            }
            .listStyle(.insetGrouped)
            .tint(BrandColor.primary)
            .navigationTitle(homeKit.currentHome?.name ?? "Home Floorplan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewFloorplan = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(String(localized: "sidebar.newFloorplan",
                                               defaultValue: "New Floorplan"))
                }
            }
            .sheet(isPresented: $showingNewFloorplan) {
                NewFloorplanSheet()
            }
        }
    }

    // MARK: - Righe di navigazione

    /// Riga che porta a una destinazione.
    ///
    /// **Link basato sulla vista, non sul valore.** I `NavigationLink(value:)`
    /// con `navigationDestination` non si attivavano, e pilotare a mano un
    /// percorso tipizzato faceva peggio: le destinazioni portano dentro le
    /// proprie `NavigationStack`, e con un `[SidebarSelection]` come percorso
    /// dello stack esterno si finiva su
    /// `AnyNavigationPath.Error.comparisonTypeMismatch`. Questa è la forma che
    /// funzionava già con la radice a tab bar, quindi è quella che teniamo.
    private func destinationRow(_ selection: SidebarSelection,
                                title: String,
                                icon: String) -> some View {
        NavigationLink {
            destination(selection)
        } label: {
            Label(title, systemImage: icon)
        }
    }

    // MARK: - Carosello planimetrie

    private var floorplanCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(carouselFloorplans) { floorplan in
                    NavigationLink {
                        destination(.floorplan(floorplan.id))
                    } label: {
                        carouselCard(for: floorplan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 20)
            .padding(.vertical, 6)
        }
        // Le schede si allineano al bordo invece di fermarsi a metà: con una
        // sola scheda visibile per volta, lasciarla tagliata a metà è il modo
        // più veloce per non capire che il carosello scorre.
        .scrollTargetBehavior(.viewAligned)
    }

    private func carouselCard(for floorplan: Floorplan) -> some View {
        let image = floorplan.currentImageData.flatMap { UIImage(data: $0) }
        let exportStyle = DrawingVisualExportStyle(rawValue: floorplan.drawingVisualExportStyleRaw) ?? .standard
        // Lo sfondo segue la planimetria, non il tema di iOS: un disegno chiaro
        // su scheda scura (o viceversa) si legge come un buco nella pagina.
        let cardBackground: Color = {
            guard image != nil else { return .secondary.opacity(0.1) }
            if exportStyle == .architecturalDark {
                return DrawingVisualExportStyle.architecturalDarkBackgroundColor
            }
            if let palette = ExteriorFillPalette(rawValue: floorplan.exteriorFillColorIndex) {
                return palette.swiftUIColor
            }
            return Color.white
        }()

        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(cardBackground)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 264, height: 176)
            .overlay(alignment: .topLeading) {
                if let badge = quickAccessBadge(for: floorplan) {
                    Label(badge.title, systemImage: badge.icon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badge.tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: "circle.grid.2x2")
                        .font(.caption2)
                    Text("\(floorplan.accessories.count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(floorplan.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(floorplan.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 264)
    }

    private func quickAccessBadge(for floorplan: Floorplan) -> (title: String, icon: String, tint: Color)? {
        if primaryFloorplanID == floorplan.id.uuidString {
            return (String(localized: "floorplan.badge.primary", defaultValue: "Primary"), "star.fill", .yellow)
        }
        if isPinned(floorplan) {
            return (String(localized: "floorplan.badge.quickAccess", defaultValue: "Quick Access"),
                    "pin.fill", BrandColor.primary)
        }
        return nil
    }

    // MARK: - Destinazioni

    /// Le viste di destinazione portano già la propria navigazione e la propria
    /// chrome — sono nate come pannelli di dettaglio dell'iPad. Qui vengono
    /// spinte così come sono, senza aggiungere un altro `NavigationStack`.
    @ViewBuilder
    private func destination(_ selection: SidebarSelection) -> some View {
        switch selection {
        case .floorplan(let id):
            if let floorplan = floorplans.first(where: { $0.id == id }) {
                // `.pushed` mostra la X al posto del toggle sidebar, che su
                // iPhone non ha niente da aprire.
                FloorplanEditorView(
                    floorplan: floorplan,
                    columnVisibility: .constant(.detailOnly),
                    presentationStyle: .pushed
                )
            } else {
                ContentUnavailableView(
                    String(localized: "content.floorplan.notFound.title", defaultValue: "Floorplan not found"),
                    systemImage: "square.dashed"
                )
            }
        case .allFloorplans:
            FloorplanListView(columnVisibility: .constant(.detailOnly))
        case .allAccessories:
            AccessoriesTabView()
        case .scenes:
            ScenesView()
        case .automations:
            AutomationsView()
        case .activityLog:
            ActivityLogView()
        case .security:
            SecurityView()
        case .environment:
            EnvironmentDashboardView()
        case .habits:
            HabitsView()
        case .homeIntelligence:
            HomeIntelligenceDashboardView()
        case .settings:
            SettingsView()
        case .debugHomeKit:
#if DEBUG
            HomeKitDebugView()
#else
            EmptyView()
#endif
        case .homeIntelligenceDebug:
#if DEBUG
            HomeIntelligenceDebugView()
#else
            EmptyView()
#endif
        }
    }
}
