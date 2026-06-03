import SwiftUI
import SwiftData

// MARK: - ScenesView
//
// Redesigned experience: Intentions × Moments × Routines
//
// Layout verticale (scrollabile):
//   1. ScenesHeroView        — hero editoriale: totale, più usata, ultima eseguita
//   2. SceneSuggestionsRow   — suggerimenti contestuali (ora, routine, stagione)
//   3. SceneIntentCategoryBar — filtro per intento, non per stanza
//   4. SceneFeaturedCards    — griglia featured (top 4 per frequenza)
//   5. SceneAllList          — lista compatta delle scene rimanenti
//
// La ricerca filtra tutto il contenuto. Il pannello ScenesSidePanel
// (floorplan editor) è invariato e non viene toccato da questo redesign.

struct ScenesView: View {

    @Environment(HomeKitScenesService.self) private var scenesService
    @Environment(\.modelContext)            private var modelContext
    @Environment(\.dismiss)                 private var dismiss
    @Environment(IconOverrideStore.self)    private var iconOverrides

    /// Mostra il bottone "Fine" solo quando la vista è presentata come sheet.
    var presentedAsSheet: Bool = false

    // MARK: - State

    @State private var usageStore: SceneUsageStore?
    @State private var searchText: String = ""
    @State private var selectedCategory: SceneIntentCategory = .all
    @State private var sceneDetailTarget: SceneItem?
    @State private var executingSceneID: UUID?
    @State private var recentlySucceededID: UUID?

    // MARK: - Computed

    /// Scene filtrate per categoria di intento e per ricerca testo.
    private var filteredScenes: [SceneItem] {
        let base: [SceneItem]
        if let store = usageStore {
            base = store.scenes(scenesService.scenes, inCategory: selectedCategory)
        } else {
            base = scenesService.scenes
        }
        guard !searchText.isEmpty else { return base }
        let needle = searchText.lowercased()
        return base.filter { $0.name.lowercased().contains(needle) }
    }

    /// Top 4 scene per frequenza di utilizzo — mostrate come featured cards.
    private var featuredScenes: [SceneItem] {
        guard let store = usageStore else { return [] }
        return store.topScenes(from: filteredScenes, limit: 4)
    }

    /// Scene non in featured — mostrate come lista compatta.
    private var remainingScenes: [SceneItem] {
        let featuredIDs = Set(featuredScenes.map(\.id))
        return filteredScenes.filter { !featuredIDs.contains($0.id) }
    }

    /// Suggerimenti contestuali (max 3).
    private var suggestions: [(scene: SceneItem, reason: SceneSuggestionReason)] {
        guard let store = usageStore, searchText.isEmpty else { return [] }
        return store.suggestedScenes(from: scenesService.scenes)
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if scenesService.scenes.isEmpty {
                    emptyState
                } else {
                    scrollContent
                }
            }
            .navigationTitle(String(localized: "scenes.navigationTitle",
                                    defaultValue: "Scene"))
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar { toolbarContent }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "scenes.search.prompt",
                                       defaultValue: "Cerca scena"))
            .sheet(item: $sceneDetailTarget) { scene in
                SceneDetailSheet(scene: scene)
                    .presentationDetents([.large])
            }
            .task {
                scenesService.refresh()
                if usageStore == nil {
                    usageStore = SceneUsageStore(modelContainer: modelContext.container)
                }
                usageStore?.loadUsageData()
            }
        }
    }

    // MARK: - Main scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── 1. Hero ───────────────────────────────────────────────
                if searchText.isEmpty {
                    ScenesHeroView(
                        totalCount: scenesService.scenes.count,
                        mostUsedName: usageStore?.mostUsedSceneName,
                        lastExecutedScene: usageStore?.lastExecutedScene
                    )
                }

                // ── 2. Suggerimenti contestuali ────────────────────────
                if !suggestions.isEmpty {
                    SceneSuggestionsSection(
                        suggestions: suggestions,
                        iconOverrides: iconOverrides,
                        executingSceneID: executingSceneID,
                        recentlySucceededID: recentlySucceededID,
                        onRun: runScene,
                        onDetail: { sceneDetailTarget = $0 }
                    )
                }

                // ── 3. Filtro per intento ──────────────────────────────
                SceneIntentCategoryBar(
                    selected: $selectedCategory,
                    scenes: scenesService.scenes,
                    usageStore: usageStore
                )

                // ── Nessun risultato dalla ricerca ─────────────────────
                if filteredScenes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 24)
                } else {
                    // ── 4. Scene Featured ──────────────────────────────
                    if !featuredScenes.isEmpty && searchText.isEmpty {
                        SceneFeaturedSection(
                            scenes: featuredScenes,
                            usageStore: usageStore,
                            iconOverrides: iconOverrides,
                            executingSceneID: executingSceneID,
                            recentlySucceededID: recentlySucceededID,
                            onRun: runScene,
                            onDetail: { sceneDetailTarget = $0 }
                        )
                    }

                    // ── 5. Tutte le scene (lista compatta) ─────────────
                    let listScenes = searchText.isEmpty ? remainingScenes : filteredScenes
                    if !listScenes.isEmpty {
                        SceneAllSection(
                            scenes: listScenes,
                            usageStore: usageStore,
                            iconOverrides: iconOverrides,
                            executingSceneID: executingSceneID,
                            recentlySucceededID: recentlySucceededID,
                            onRun: runScene,
                            onDetail: { sceneDetailTarget = $0 }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "scenes.empty.title",
                         defaultValue: "Nessuna scena"),
                  systemImage: "wand.and.sparkles")
        } description: {
            VStack(spacing: 8) {
                Text(String(localized: "scenes.empty.description1",
                            defaultValue: "Non hai ancora scene configurate."))
                Text(String(localized: "scenes.empty.description2",
                            defaultValue: "Le scene combinano più accessori in un comando: una scena \"Buonanotte\" può spegnere tutte le luci e abbassare il termostato."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        } actions: {
            if let url = URL(string: "x-apple-homekit://"),
               UIApplication.shared.canOpenURL(url) {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label(String(localized: "scenes.empty.openHome",
                                 defaultValue: "Crea da Apple Casa"),
                          systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 60)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if presentedAsSheet {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "scenes.toolbar.done",
                              defaultValue: "Fine")) { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }

    // MARK: - Run scene

    private func runScene(_ scene: SceneItem) {
        guard executingSceneID == nil else { return }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        executingSceneID = scene.id

        Task {
            do {
                try await scenesService.run(scene)
                UINotificationFeedbackGenerator().notificationOccurred(.success)

                await MainActor.run {
                    executingSceneID = nil
                    recentlySucceededID = scene.id
                    usageStore?.loadUsageData()  // aggiorna statistiche
                }

                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run {
                    if recentlySucceededID == scene.id { recentlySucceededID = nil }
                }

                if presentedAsSheet {
                    await MainActor.run { dismiss() }
                }
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                await MainActor.run { executingSceneID = nil }
            }
        }
    }
}

// MARK: - ScenesHeroView
//
// Hero editoriale — risponde alle domande:
// "Quante scene ho?", "Cosa uso di più?", "Cosa ho usato di recente?"

private struct ScenesHeroView: View {

    let totalCount: Int
    let mostUsedName: String?
    let lastExecutedScene: SceneUsageSummary?

    var body: some View {
        VStack(spacing: 0) {

            // ── Top: etichetta + contatore + icona decorativa ──────────
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.orange)
                        Text(String(localized: "scenes.hero.label",
                                    defaultValue: "LE TUE SCENE"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(totalCount)")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .contentTransition(.numericText())

                        Text(totalCount == 1
                             ? String(localized: "scenes.hero.sceneSingular",
                                      defaultValue: "scena")
                             : String(localized: "scenes.hero.scenePlural",
                                      defaultValue: "scene"))
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.orange.opacity(0.15), Color.yellow.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 76, height: 76)
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.orange, Color.yellow],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()

            // ── Statistiche: più usata + ultima ────────────────────────
            HStack(spacing: 0) {
                heroStatCell(
                    icon: "star.fill",
                    iconColor: .orange,
                    title: String(localized: "scenes.hero.mostUsed",
                                  defaultValue: "Più usata"),
                    value: mostUsedName ?? "—"
                )

                Divider().frame(height: 36)

                heroStatCell(
                    icon: "clock.arrow.circlepath",
                    iconColor: Color.orange.opacity(0.65),
                    title: String(localized: "scenes.hero.lastExecuted",
                                  defaultValue: "Ultima"),
                    value: {
                        guard let s = lastExecutedScene,
                              let d = s.lastExecutedAt else { return "—" }
                        let fmt = RelativeDateTimeFormatter()
                        fmt.unitsStyle = .abbreviated
                        return "\(s.sceneName) · \(fmt.localizedString(for: d, relativeTo: Date()))"
                    }()
                )
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: Color.orange.opacity(0.08), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }

    private func heroStatCell(icon: String,
                               iconColor: Color,
                               title: String,
                               value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.4)

                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - SceneSuggestionsSection
//
// Sezione suggerimenti contestuali — la sezione più importante.
// Max 3 card orizzontali, basate su ora del giorno, routine settimanale,
// stagione e orario medio storico.

private struct SceneSuggestionsSection: View {

    let suggestions: [(scene: SceneItem, reason: SceneSuggestionReason)]
    let iconOverrides: IconOverrideStore
    let executingSceneID: UUID?
    let recentlySucceededID: UUID?
    let onRun: (SceneItem) -> Void
    let onDetail: (SceneItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sceneSectionHeader(
                icon: "sparkles",
                titleDefault: "SUGGERITE ORA"
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(suggestions, id: \.scene.id) { item in
                        SceneSuggestionCard(
                            scene: item.scene,
                            reason: item.reason,
                            iconName: iconOverrides.effectiveIcon(for: item.scene),
                            isExecuting: executingSceneID == item.scene.id,
                            justSucceeded: recentlySucceededID == item.scene.id,
                            onRun: { onRun(item.scene) },
                            onDetail: { onDetail(item.scene) }
                        )
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

private struct SceneSuggestionCard: View {

    let scene: SceneItem
    let reason: SceneSuggestionReason
    let iconName: String
    let isExecuting: Bool
    let justSucceeded: Bool
    let onRun: () -> Void
    let onDetail: () -> Void

    private var reasonIcon: String {
        switch reason {
        case .timeOfDay:     return "clock.fill"
        case .weeklyRoutine: return "calendar"
        case .season:        return "leaf.fill"
        case .usualTime:     return "chart.bar.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Icona scena
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            justSucceeded
                                ? AnyShapeStyle(Color.green.gradient)
                                : AnyShapeStyle(LinearGradient(
                                    colors: [Color.orange, Color(red: 1, green: 0.75, blue: 0)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                  ))
                        )
                        .frame(width: 44, height: 44)

                    Group {
                        if isExecuting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.8)
                        } else if justSucceeded {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: iconName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                Spacer()

                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .padding(9)
                        .background(Circle().fill(Color.orange.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(isExecuting)
            }

            Text(scene.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 4) {
                Image(systemName: reasonIcon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.orange.opacity(0.7))
                Text(reason.defaultLabel(sceneName: scene.name))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
                )
        )
        .shadow(color: Color.orange.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(isExecuting ? 0.6 : 1.0)
        .animation(.spring(response: 0.3), value: justSucceeded)
        .onLongPressGesture(minimumDuration: 0.45) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onDetail()
        }
    }
}

// MARK: - SceneIntentCategoryBar
//
// Filtro per intento — sostituisce il vecchio filtro per stanza.

private struct SceneIntentCategoryBar: View {

    @Binding var selected: SceneIntentCategory
    let scenes: [SceneItem]
    let usageStore: SceneUsageStore?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleCategories) { cat in
                    intentPill(cat)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var visibleCategories: [SceneIntentCategory] {
        SceneIntentCategory.allCases.filter { cat in
            guard cat == .favorites else { return true }
            return usageStore?.topScenes(from: scenes, limit: 1).isEmpty == false
        }
    }

    private func intentPill(_ cat: SceneIntentCategory) -> some View {
        let isSelected = selected == cat
        return Button {
            withAnimation(.spring(response: 0.3)) { selected = cat }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: cat.sfSymbol)
                    .font(.system(size: 11, weight: .medium))
                Text(cat.defaultLabel)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected
                          ? AnyShapeStyle(LinearGradient(
                              colors: [Color.orange, Color(red: 1, green: 0.75, blue: 0)],
                              startPoint: .leading,
                              endPoint: .trailing
                            ))
                          : AnyShapeStyle(Color(.tertiarySystemGroupedBackground)))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SceneFeaturedSection
//
// Griglia 2×2 delle scene più usate — card premium.

private struct SceneFeaturedSection: View {

    let scenes: [SceneItem]
    let usageStore: SceneUsageStore?
    let iconOverrides: IconOverrideStore
    let executingSceneID: UUID?
    let recentlySucceededID: UUID?
    let onRun: (SceneItem) -> Void
    let onDetail: (SceneItem) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sceneSectionHeader(
                icon: "star.fill",
                titleDefault: "PIÙ USATE"
            )

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(scenes) { scene in
                    SceneFeaturedCard(
                        scene: scene,
                        usage: usageStore?.summary(for: scene.name),
                        iconName: iconOverrides.effectiveIcon(for: scene),
                        isExecuting: executingSceneID == scene.id,
                        justSucceeded: recentlySucceededID == scene.id,
                        onRun: { onRun(scene) },
                        onDetail: { onDetail(scene) }
                    )
                }
            }
        }
    }
}

private struct SceneFeaturedCard: View {

    let scene: SceneItem
    let usage: SceneUsageSummary?
    let iconName: String
    let isExecuting: Bool
    let justSucceeded: Bool
    let onRun: () -> Void
    let onDetail: () -> Void

    private var lastExecutedText: String {
        guard let d = usage?.lastExecutedAt else {
            return String(localized: "scenes.card.neverExecuted",
                          defaultValue: "Mai eseguita")
        }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Icona + play button
            HStack(alignment: .top) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            justSucceeded
                                ? AnyShapeStyle(Color.green.gradient)
                                : AnyShapeStyle(BrandColor.heroGradient)
                        )
                        .frame(width: 52, height: 52)

                    Group {
                        if isExecuting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.85)
                        } else if justSucceeded {
                            Image(systemName: "checkmark")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: iconName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                Spacer()

                Button(action: onRun) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.10))
                            .frame(width: 36, height: 36)
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isExecuting || justSucceeded)
            }

            // Nome + azioni
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text("\(scene.actionCount) \(scene.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "azione") : String(localized: "count.action.plural", defaultValue: "azioni"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Footer: ultima esecuzione + contatore
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(lastExecutedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)

                if let count = usage?.totalExecutions, count > 0 {
                    Spacer()
                    Text("\(count)×")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.orange.opacity(0.75))
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            justSucceeded
                                ? Color.green.opacity(0.4)
                                : Color(.separator).opacity(0.45),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(isExecuting ? 0.65 : 1.0)
        .scaleEffect(isExecuting ? 0.97 : 1.0)
        .animation(.spring(response: 0.3), value: isExecuting)
        .animation(.spring(response: 0.3), value: justSucceeded)
        .onLongPressGesture(minimumDuration: 0.45) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onDetail()
        }
    }
}

// MARK: - SceneAllSection
//
// Lista compatta di tutte le scene non in featured.

private struct SceneAllSection: View {

    let scenes: [SceneItem]
    let usageStore: SceneUsageStore?
    let iconOverrides: IconOverrideStore
    let executingSceneID: UUID?
    let recentlySucceededID: UUID?
    let onRun: (SceneItem) -> Void
    let onDetail: (SceneItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sceneSectionHeader(
                icon: "list.bullet",
                titleDefault: "TUTTE LE SCENE"
            )

            VStack(spacing: 0) {
                ForEach(Array(scenes.enumerated()), id: \.element.id) { idx, scene in
                    SceneListRow(
                        scene: scene,
                        usage: usageStore?.summary(for: scene.name),
                        iconName: iconOverrides.effectiveIcon(for: scene),
                        isExecuting: executingSceneID == scene.id,
                        justSucceeded: recentlySucceededID == scene.id,
                        isLast: idx == scenes.count - 1,
                        onRun: { onRun(scene) },
                        onDetail: { onDetail(scene) }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private struct SceneListRow: View {

    let scene: SceneItem
    let usage: SceneUsageSummary?
    let iconName: String
    let isExecuting: Bool
    let justSucceeded: Bool
    let isLast: Bool
    let onRun: () -> Void
    let onDetail: () -> Void

    private var lastExecutedText: String? {
        guard let d = usage?.lastExecutedAt else { return nil }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                // Icona
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            justSucceeded
                                ? AnyShapeStyle(Color.green.gradient)
                                : AnyShapeStyle(BrandColor.heroGradient)
                        )
                        .frame(width: 40, height: 40)

                    Group {
                        if isExecuting {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)
                                .scaleEffect(0.75)
                        } else if justSucceeded {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: iconName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .animation(.spring(response: 0.3), value: justSucceeded)

                // Nome + meta
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(scene.actionCount) \(scene.actionCount == 1 ? String(localized: "count.action.singular", defaultValue: "azione") : String(localized: "count.action.plural", defaultValue: "azioni"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let last = lastExecutedText {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(last)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                Button(action: onRun) {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(
                            isExecuting
                                ? AnyShapeStyle(Color.secondary)
                                : AnyShapeStyle(Color.orange)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isExecuting || justSucceeded)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDetail()
            }

            if !isLast {
                Divider().padding(.leading, 68)
            }
        }
    }
}

// MARK: - Section header helper

private func sceneSectionHeader(icon: String,
                                 titleDefault: String) -> some View {
    HStack(spacing: 6) {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.orange)
        Text(titleDefault)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
    }
    .padding(.horizontal, 2)
}
