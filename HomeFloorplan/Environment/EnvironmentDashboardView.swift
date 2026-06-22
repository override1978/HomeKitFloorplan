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
    @Environment(ActionExecutionService.self) private var executionService

    @State private var vm = EnvironmentViewModel()

    @Environment(WeatherKitService.self) private var weatherKit

    @State private var selectedSensor: SensorData?
    @State private var showThresholdSettings = false
    @State private var isRefreshing = false
    @State private var isReordering = false
    @AppStorage("ai.isEnabled") private var isAIEnabled: Bool = false

    /// Servizio AI per gli insight ambientali (app-scoped, iniettato dall'ambiente).
    @Environment(AmbientalAIService.self) private var aiService
    /// Sheet per revisionare una proposta di automazione generata dagli insight ambientali.
    @State private var pendingAutomationProposal: AutomationProposal?

    /// Timestamp dell'ultimo campionamento automatico (onAppear).
    /// Usato per evitare campionamenti ravvicinati che comprimerebbero la stdDev baseline.
    @State private var lastSampledAt: Date?

    /// Intervallo minimo tra campionamenti automatici (5 minuti).
    private let samplingThrottle: TimeInterval = 5 * 60

    // iPad: 2 colonne adattive da 300pt min
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14)]

    // Tutti gli insight visibili da tutte le stanze (per il Digest globale)
    private var allVisibleInsights: [AmbientalAIInsight] {
        vm.rooms.flatMap { room in
            normalizedInsights(for: room)
        }
    }

    // Numero di stanze con almeno un sensore in warning o danger
    private var attentionRoomCount: Int {
        vm.rooms.filter { $0.worstUrgency != .normal }.count
    }

    private func normalizedInsights(for room: RoomEnvironmentData) -> [AmbientalAIInsight] {
        aiService.visibleInsights(for: room.roomName).map { insight in
            let effectiveSeverity = max(insight.severity, severityFloor(for: room.worstUrgency))
            guard effectiveSeverity != insight.severity else { return insight }
            return AmbientalAIInsight(
                id: insight.id,
                roomName: insight.roomName,
                message: insight.message,
                severity: effectiveSeverity,
                intelligenceLevel: insight.intelligenceLevel,
                patternKey: insight.patternKey,
                whyExplanation: insight.whyExplanation,
                confidence: insight.confidence,
                generatedAt: insight.generatedAt,
                isDismissed: insight.isDismissed,
                nextActions: insight.nextActions,
                resolvedIntents: insight.resolvedIntents,
                sourceAccessoryID: insight.sourceAccessoryID,
                sourceAccessoryName: insight.sourceAccessoryName,
                sourceServiceType: insight.sourceServiceType,
                promptVersion: insight.promptVersion,
                isLanguageSuspect: insight.isLanguageSuspect
            )
        }
    }

    private func severityFloor(for urgency: SensorUrgency) -> InsightSeverity {
        switch urgency {
        case .danger:  return .anomaly
        case .warning: return .warning
        case .normal:  return .info
        }
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
            .navigationTitle(String(localized: "environment.title", defaultValue: "Environment"))
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar { toolbarContent }
            .sheet(item: $selectedSensor) { sensor in
                SensorDetailSheet(sensor: sensor, modelContainer: modelContext.container)
            }
            .sheet(isPresented: $showThresholdSettings) {
                AlertThresholdSettingsView()
            }
            .sheet(isPresented: $isReordering) {
                EnvironmentRoomReorderSheet(vm: vm)
            }
            .onAppear {
                vm.configure(modelContainer: modelContext.container)
                vm.loadFromCoreData()
                AlertNotificationService.shared.clearBadge()
                sampleIfNeeded()
            }
        }
        // Sheet automazione — sul NavigationStack per evitare conflitti con gli altri sheet.
        .sheet(item: $pendingAutomationProposal) { proposal in
            AutomationWizardSheet(proposal: proposal) { _ in
                pendingAutomationProposal = nil
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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

                // ── 2. Banner esterno (WeatherKit) ─────────────────────
                if weatherKit.currentWeather != nil {
                    OutdoorBannerView()
                }

                if isAIEnabled && aiService.isAnalyzing {
                    aiAnalysisStatus
                }

                // ── 3. AI Digest: insight aggregati (visibile solo se AI abilitata e ci sono insight) ──
                if isAIEnabled {
                    let insights = allVisibleInsights
                    if !insights.isEmpty {
                        EnvironmentAIDigestCard(
                            insights: insights,
                            onDismissInsight: { insight, reason in
                                aiService.dismiss(insight, reason: reason)
                            },
                            onExecuteAction: { action, insight in
                                guard let home = homeKit.currentHome else { return false }
                                return await executionService.execute(action, insight: insight, in: home)
                            },
                            onReviewAutomation: { proposal, _ in
                                openAutomationBuilder(proposal)
                            }
                        )
                    }
                }

                // ── 4. Header sezione stanze ───────────────────────────
                HStack {
                    Text(String(localized: "environment.rooms", defaultValue: "Rooms"))
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
                            aiInsights: isAIEnabled ? normalizedInsights(for: room) : [],
                            onDismissInsight: { insight, reason in aiService.dismiss(insight, reason: reason) },
                            onExecuteAction: { action, insight in
                                guard let home = homeKit.currentHome else { return false }
                                return await executionService.execute(action, insight: insight, in: home)
                            },
                            onReviewAutomation: { proposal, _ in
                                openAutomationBuilder(proposal)
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

    private var aiAnalysisStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "environment.ai.analyzing", defaultValue: "Analisi AI in corso"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    // MARK: - Automation proposal helper

    /// Apre il builder con un piccolo delay per evitare conflitti con il gesture recognizer della LazyVGrid.
    private func openAutomationBuilder(_ proposal: AutomationProposal) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pendingAutomationProposal = proposal
        }
    }

    // MARK: - Empty / Loading

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.2)
            Text(String(localized: "environment.dashboard.loading", defaultValue: "Reading HomeKit sensors..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "environment.dashboard.empty.title", defaultValue: "No sensors found"), systemImage: "sensor.tag.radiowaves.forward.slash")
        } description: {
            Text(String(localized: "environment.dashboard.empty.description", defaultValue: "Connect environmental sensors in HomeKit. Temperature, humidity, air quality, and more will appear here."))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 4) {
                Button { isReordering = true } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .disabled(vm.rooms.isEmpty)
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
        // Throttle: non campionare se il campionamento precedente è avvenuto
        // meno di 5 minuti fa. Evita che aperture ravvicinate della Dashboard
        // producano cluster di letture temporalmente compresse, che abbassano
        // artificialmente la stdDev della baseline e generano falsi positivi AI.
        if let last = lastSampledAt,
           Date().timeIntervalSince(last) < samplingThrottle {
            // Sampling skipped — still run AI analysis on existing data.
            Task { await aiService.analyzeRooms(vm.rooms) }
            return
        }
        lastSampledAt = Date()
        Task {
            await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: modelContext.container)
            let rooms = await vm.reloadFromCoreData()
            await aiService.analyzeRooms(rooms)
        }
    }

    private func refreshManual() {
        guard !isRefreshing, let home = homeKit.currentHome else { return }
        isRefreshing = true
        // Clear the per-room 15-min gate so the upcoming analyzeRooms call
        // analyses every room with the freshly sampled data.
        aiService.clearAnalysisGates()
        Task {
            await SensorLogger.shared.sampleAllSensors(home: home, modelContainer: modelContext.container)
            let rooms = await vm.reloadFromCoreData()
            await aiService.analyzeRooms(rooms)
            isRefreshing = false
        }
    }
}

// MARK: - EnvironmentRoomReorderSheet

private struct EnvironmentRoomReorderSheet: View {
    var vm: EnvironmentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var localRooms: [RoomEnvironmentData] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(localRooms) { room in
                    HStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        Text(room.roomName)
                            .font(.body)
                        Spacer()
                        Circle()
                            .fill(room.qualityColor)
                            .frame(width: 8, height: 8)
                    }
                    .padding(.vertical, 4)
                }
                .onMove { indices, destination in
                    localRooms.move(fromOffsets: indices, toOffset: destination)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(String(localized: "environment.rooms.order.title", defaultValue: "Room Order"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "common.reset", defaultValue: "Reset")) {
                        vm.saveOrder([])
                        vm.loadFromCoreData()
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "common.done", defaultValue: "Done")) {
                        vm.saveOrder(localRooms)
                        vm.loadFromCoreData()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            localRooms = vm.rooms
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
                    onDismissInsight: { _, _ in },
                    onExecuteAction: { _, _ in true },
                    onReviewAutomation: { _, _ in }
                )

                HStack {
                    Text(String(localized: "environment.rooms", defaultValue: "Rooms")).font(.title3.weight(.bold))
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
        .navigationTitle(String(localized: "environment.title", defaultValue: "Environment"))
        .background(Color(.systemGroupedBackground))
    }
}
