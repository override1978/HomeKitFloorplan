import SwiftUI
import SwiftData
import HomeKit

// MARK: - EnvironmentDashboardView
//
// Orchestra principale della schermata Ambiente.
// Struttura verticale (scroll), ottimizzata per iPad landscape:
//
//   1. EnvironmentHeroView       — score globale, trend, stanze da controllare
//   2. OutdoorBannerView         — temperatura/umidità esterna (se configurata)
//   3. EnvironmentAIDigestCard   — insight AI di tutte le stanze (visibile se ci sono insight)
//   4. LazyVGrid (2 colonne)     — RoomSectionView per ogni stanza
//
// La logica di business (campionamento, AI, regole) rimane invariata.

struct EnvironmentDashboardView: View {

    @Environment(HomeKitService.self) private var homeKit
    @Environment(\.modelContext) private var modelContext

    @StateObject private var vm = EnvironmentViewModel()
    @Environment(RuleEngineService.self) private var ruleEngine

    @State private var selectedSensor: SensorData?
    @State private var showThresholdSettings = false
    @State private var isRefreshing = false
    @AppStorage("outdoorRoomName") private var outdoorRoomName: String = ""
    @State private var outdoorRefreshID = UUID()

    /// Servizio AI per gli insight ambientali (lazy init in onAppear).
    @State private var aiService: AmbientalAIService?
    /// Sheet per la creazione di una nuova regola da un RuleDraft AI.
    @State private var pendingRuleDraft: RuleDraft?
    /// Esecutore Next Action (stateless, condiviso).
    private let nextActionExecutor = NextActionExecutor()

    // iPad: 2 colonne adattive da 300pt min
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    // Tutti gli insight visibili da tutte le stanze (per il Digest globale)
    private var allVisibleInsights: [AmbientalAIInsight] {
        vm.rooms.flatMap { aiService?.visibleInsights(for: $0.roomName) ?? [] }
    }

    // Numero di stanze con almeno un sensore in warning o danger
    private var attentionRoomCount: Int {
        vm.rooms.filter { $0.worstUrgency != .normal }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.rooms.isEmpty {
                    loadingState
                } else if vm.rooms.isEmpty {
                    emptyState
                } else {
                    scrollContent
                }
            }
            .navigationTitle("Ambiente")
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar { toolbarContent }
            .sheet(item: $selectedSensor) { sensor in
                SensorDetailSheet(sensor: sensor, modelContainer: modelContext.container)
            }
            .sheet(isPresented: $showThresholdSettings) {
                AlertThresholdSettingsView()
            }
            .onAppear {
                vm.configure(modelContainer: modelContext.container)
                vm.loadFromCoreData()
                sampleIfNeeded()
                AlertNotificationService.shared.clearBadge()
                if aiService == nil {
                    aiService = AmbientalAIService(
                        aiSettings: AISettings(),
                        modelContainer: modelContext.container,
                        homeKit: homeKit
                    )
                }
                Task { await aiService?.analyzeRooms(vm.rooms) }
            }
        }
        // Sheet regola — sul NavigationStack per evitare conflitti con gli altri sheet.
        .sheet(item: $pendingRuleDraft) { draft in
            RuleEditorView(draft: draft) { updatedDraft in
                guard let updatedDraft, let home = homeKit.currentHome else { return }
                Task { try? await ruleEngine.createRule(from: updatedDraft, home: home) }
            } onExecuteNow: { executedDraft in
                guard let home = homeKit.currentHome else { return }
                let tempAction = AINextAction(
                    label: executedDraft.name,
                    actionType: "executeNow",
                    accessoryID: executedDraft.actionAccessoryID,
                    accessoryActionType: executedDraft.actionType,
                    accessoryValue: executedDraft.actionValue
                )
                Task { _ = await nextActionExecutor.execute(tempAction, in: home) }
            }
        }
    }

    // MARK: - Contenuto principale

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 16) {

                // ── 1. Hero: score globale ─────────────────────────────
                EnvironmentHeroView(
                    score: vm.globalScore,
                    label: vm.globalLabel,
                    color: vm.globalColor,
                    lastRefresh: vm.lastRefresh,
                    attentionRoomCount: attentionRoomCount,
                    trend: nil   // Trend futuro: confronto con snapshot precedente
                )

                // ── 2. Banner esterno (opzionale) ──────────────────────
                if !outdoorRoomName.isEmpty {
                    OutdoorBannerView(
                        modelContainer: modelContext.container,
                        roomName: outdoorRoomName
                    )
                    .id(outdoorRefreshID)
                }

                // ── 3. AI Digest: insight aggregati (visibile solo se ci sono insight) ──
                let insights = allVisibleInsights
                if !insights.isEmpty {
                    EnvironmentAIDigestCard(
                        insights: insights,
                        onDismissInsight: { insight in
                            aiService?.dismiss(insight)
                        },
                        onExecuteAction: { action, insight in
                            guard let home = homeKit.currentHome else { return }
                            Task { _ = await nextActionExecutor.execute(action, in: home) }
                        },
                        onCreateRule: { draft, _ in
                            openRuleEditor(draft: draft)
                        }
                    )
                }

                // ── 4. Header sezione stanze ───────────────────────────
                HStack {
                    Text("Stanze")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(vm.rooms.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 4)

                // ── 5. Griglia stanze ──────────────────────────────────
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(vm.rooms) { room in
                        RoomSectionView(
                            room: room,
                            onSensorTap: { sensor in selectedSensor = sensor },
                            aiInsights: aiService?.visibleInsights(for: room.roomName) ?? [],
                            onDismissInsight: { insight in aiService?.dismiss(insight) },
                            onExecuteAction: { action, _ in
                                guard let home = homeKit.currentHome else { return }
                                Task { _ = await nextActionExecutor.execute(action, in: home) }
                            },
                            onCreateRule: { draft, _ in
                                openRuleEditor(draft: draft)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Rule editor helper

    /// Risolve il nome accessorio e apre RuleEditorView con un piccolo delay
    /// per evitare conflitti con il gesture recognizer della LazyVGrid.
    private func openRuleEditor(draft: RuleDraft) {
        var resolved = draft
        if resolved.actionAccessoryName.isEmpty,
           let uuid = UUID(uuidString: resolved.actionAccessoryID),
           let name = homeKit.accessory(for: uuid)?.name {
            resolved.actionAccessoryName = name
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pendingRuleDraft = resolved
        }
    }

    // MARK: - Empty / Loading

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text("Lettura sensori HomeKit…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessun sensore trovato", systemImage: "sensor.tag.radiowaves.forward.slash")
        } description: {
            Text("Collega sensori ambientali in HomeKit: temperatura, umidità, qualità aria e altro appariranno qui.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                Button { showThresholdSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                Button { refreshManual() } label: {
                    if isRefreshing {
                        ProgressView().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
            }
        }
    }

    // MARK: - Campionamento

    private func sampleIfNeeded() {
        guard let home = homeKit.currentHome else { return }
        Task {
            await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: modelContext.container)
            vm.loadFromCoreData()
            outdoorRefreshID = UUID()
        }
    }

    private func refreshManual() {
        guard !isRefreshing, let home = homeKit.currentHome else { return }
        isRefreshing = true
        Task {
            await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: modelContext.container)
            vm.loadFromCoreData()
            outdoorRefreshID = UUID()
            await aiService?.analyzeRooms(vm.rooms)
            isRefreshing = false
        }
    }
}

// MARK: - Preview

#Preview {
    let vm = EnvironmentViewModel.mock()
    NavigationStack {
        ScrollView {
            VStack(spacing: 16) {

                EnvironmentHeroView(
                    score: vm.globalScore,
                    label: vm.globalLabel,
                    color: vm.globalColor,
                    lastRefresh: vm.lastRefresh,
                    attentionRoomCount: vm.rooms.filter { $0.worstUrgency != .normal }.count,
                    trend: 0.03
                )

                EnvironmentAIDigestCard(
                    insights: [
                        AmbientalAIInsight(
                            roomName: "Cucina",
                            message: "Umidità al 72%, sopra la baseline storica del 18%. Trend in salita nelle ultime 3 ore.",
                            severity: .warning,
                            nextActions: [
                                AINextAction(label: "Accendi purificatore", actionType: "suggest",
                                            accessoryID: "uuid-1", accessoryActionType: "setMode", accessoryValue: 1)
                            ]
                        )
                    ],
                    onDismissInsight: { _ in },
                    onExecuteAction: { _, _ in },
                    onCreateRule: { _, _ in }
                )

                HStack {
                    Text("Stanze").font(.title3.weight(.bold))
                    Spacer()
                    Text("\(vm.rooms.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(vm.rooms) { room in
                        RoomSectionView(room: room, onSensorTap: { _ in })
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .navigationTitle("Ambiente")
        .background(Color(.systemGroupedBackground))
    }
}
