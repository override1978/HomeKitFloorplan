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
    @State private var showNewFloorplan = false

    @Environment(HomeKitService.self) private var homeKit
    @Environment(AISettings.self) private var aiSettings
    @Query(sort: \Floorplan.createdAt, order: .reverse) private var allFloorplans: [Floorplan]

    @AppStorage("primaryFloorplanID")    private var primaryFloorplanID:    String = ""
    @AppStorage("pinnedFloorplanIDs")    private var pinnedFloorplanIDsRaw: String = "[]"
    /// Sezione Abitudini (beta): nascosta di default, come in sidebar.
    @AppStorage("habits.sectionVisible") private var areHabitsEnabled:      Bool   = false

    @State private var showChat = false


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
                if carouselFloorplans.isEmpty {
                    // Nessuna planimetria su iPhone è un vicolo cieco: non c'è
                    // il carosello, non c'è il "+", e senza una spiegazione
                    // sembra che l'app sia rotta invece che a metà del suo giro.
                    Section {
                        noFloorplansHint
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                } else {
                    Section {
                        floorplanCarousel
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }

                Section {
                    // "Nuova planimetria" non sta in elenco: la crea il + nella
                    // barra, e in un elenco di destinazioni una voce che apre un
                    // foglio è l'unica che non porta da nessuna parte.
                    destinationRow(.allFloorplans,
                                   title: String(localized: "sidebar.allFloorplans", defaultValue: "All Floorplans"),
                                   icon: "rectangle.stack")

                    // Le pinnate elencate sotto, come in sidebar su iPad.
                    ForEach(pinnedFloorplans) { floorplan in
                        pinnedRow(floorplan)
                    }
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
                    destinationRow(.energy,
                                   title: String(localized: "sidebar.energy", defaultValue: "Energy"),
                                   icon: "bolt.fill")
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
            // Da quando l'editor 2D ha la chrome compatta, creare da iPhone è
            // un flusso completo: foglio dati, poi disegno e marker sul posto.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showNewFloorplan = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showNewFloorplan) {
                NewFloorplanSheet()
            }
        }
        // L'assistente sta QUI e non sulla planimetria. Su iPad è un riquadro
        // flottante in alto a destra tarato su ~430 punti di larghezza: sopra
        // la planimetria di un iPhone coprirebbe ciò di cui si sta parlando.
        // Sulla schermata iniziale invece non compete con niente, e un foglio
        // si chiude col gesto che tutti conoscono.
        .overlay(alignment: .bottomTrailing) {
            if aiSettings.isAIEnabled {
                ChatFABButtonView(showChat: $showChat)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showChat) {
            // Il gate è ripetuto anche qui, non solo sul bottone: è la vista che
            // parla col modello, e deve rifiutarsi da sé se l'AI è spenta —
            // non fidarsi di chi l'ha presentata.
            if aiSettings.isAIEnabled {
                ChatBotView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        // Se l'AI viene spenta mentre la chat è aperta, la chat si chiude.
        // Stesso guardiano che ContentView tiene sul pannello dell'iPad.
        .onChange(of: aiSettings.isAIEnabled) { _, isEnabled in
            guard !isEnabled else { return }
            showChat = false
        }
    }

    /// Principale sempre per prima, poi le pinnate nell'ordine salvato.
    ///
    /// La principale entra **anche se non risulta pinnata**: `setPrimary` la
    /// pinna, ma `ContentView` ne assegna una da sé al primo avvio quando
    /// `primaryFloorplanID` è vuoto, e quella strada non passa dal pin. Il
    /// risultato era una planimetria con la stella che non compariva
    /// nell'elenco. Se è degna della stella, è degna dell'elenco.
    private var pinnedFloorplans: [Floorplan] {
        let primary = floorplans.first { $0.id.uuidString == primaryFloorplanID }
        let pinned = decodePinnedIDs().compactMap { idString -> Floorplan? in
            guard let uuid = UUID(uuidString: idString) else { return nil }
            return floorplans.first(where: { $0.id == uuid })
        }
        let rest = pinned.filter { $0.id.uuidString != primaryFloorplanID }
        return (primary.map { [$0] } ?? []) + rest
    }

    // MARK: - Righe di navigazione

    private func pinnedRow(_ floorplan: Floorplan) -> some View {
        let isPrimary = floorplan.id.uuidString == primaryFloorplanID
        return NavigationLink {
            destination(.floorplan(floorplan.id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isPrimary ? "star.square.fill" : "pin.circle.fill")
                    .foregroundStyle(isPrimary ? AnyShapeStyle(Color.yellow)
                                               : AnyShapeStyle(BrandColor.primary))
                    .frame(width: 22)
                Text(floorplan.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(floorplan.accessories.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

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

    // MARK: - Nessuna planimetria

    private var noFloorplansHint: some View {
        VStack(spacing: 12) {
            Image(systemName: "ipad.and.iphone")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(BrandColor.primary)

            Text(String(localized: "compact.noFloorplans.title",
                        defaultValue: "No floorplans yet"))
                .font(.headline)

            Text(String(localized: "compact.noFloorplans.message",
                        defaultValue: "Create your first floorplan with the + button, or draw one on iPad — iCloud keeps them in sync."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                showNewFloorplan = true
            } label: {
                Label(String(localized: "floorplan.create", defaultValue: "Create floorplan"),
                      systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
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
        case .energy:
            EnergyMonitorView()
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
