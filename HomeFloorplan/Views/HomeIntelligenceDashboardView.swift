import SwiftUI
import SwiftData

// MARK: - LearningPhase view extension

private extension LearningPhase {
    var accentColor: Color {
        switch self {
        case .observing:      return .gray
        case .building:       return .orange
        case .recognizing:    return Color(red: 0.7, green: 0.6, blue: 0.0)
        case .understanding:  return BrandColor.primary
        case .mature:         return .green
        }
    }
}

// MARK: - HomeIntelligenceDashboardView

/// Home Intelligence Dashboard — Sprint 12.
///
/// Layout (scrollable):
///   1. Home Briefing        — current priority and cross-domain summary
///   2. Needs Attention      — actionable signals without duplicating dashboards
///   3. Journal              — recent proactive notifications
///   4. Opportunities        — automation suggestions ready for action
///   5. Learning Summary     — compact learning state with link to Habits
///   6. AI Effectiveness     — trust score + per-intent breakdown
struct HomeIntelligenceDashboardView: View {

    @Environment(HabitAnalysisService.self)          private var habitService
    @Environment(BehavioralAnalysisService.self)     private var behavioralService
    @Environment(HomeKitService.self)                private var homeKit
    @Environment(HomeKitScenesService.self)          private var scenesService
    @Environment(HomeKitAutomationsService.self)     private var automationsService
    @Environment(ActionExecutionService.self)        private var executionService
    @Environment(ProactiveIntelligenceService.self)  private var proactiveService
    @Environment(OccupancyPredictionService.self)    private var occupancyService
    @Environment(LocationPresenceService.self)       private var locationService
    @Environment(MaintenancePredictionService.self)  private var maintenanceService
    @Environment(FamilyPresenceService.self)         private var familyPresenceService
    @Environment(\.modelContext)                     private var modelContext

    @Query(
        filter: #Predicate<PersistedHomeInsight> {
            $0.statusRaw == "active" && $0.kindRaw == "prediction"
        },
        sort: \PersistedHomeInsight.updatedAt,
        order: .reverse
    )
    private var activePredictionInsights: [PersistedHomeInsight]

    @Query(
        filter: #Predicate<PersistedHomeInsight> {
            $0.statusRaw == "active"
        },
        sort: \PersistedHomeInsight.updatedAt,
        order: .reverse
    )
    private var activeHomeInsights: [PersistedHomeInsight]

    @Query(
        sort: \PersistedHomeInsight.updatedAt,
        order: .reverse
    )
    private var recentHomeInsights: [PersistedHomeInsight]

    @State private var service: HomeKnowledgeService?
    @State private var isRefreshing: Bool = false
    @State private var reviewingProposal: AutomationProposal?
    @State private var reviewingOpportunity: AutomationOpportunity?
    @State private var reviewingHabitPattern: HabitPattern?
    @State private var isDiaryExpanded: Bool = false
    @AppStorage("ai.isEnabled") private var isAIEnabled: Bool = false

    // Static formatters — created once, reused on every render.
    private static let feedTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private var predictiveInsights: [PersistedHomeInsight] {
        activePredictionInsights.filter {
            $0.sourceRecordType == String(describing: PredictiveSignal.self)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let svc = service {
                    scrollContent(svc: svc)
                } else {
                    loadingState
                }
            }
            .navigationTitle(
                String(localized: "intelligence.nav.title", defaultValue: "Intelligence")
            )
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar { toolbarContent }
            .sheet(item: $reviewingProposal, onDismiss: {
                reviewingOpportunity = nil
                reviewingHabitPattern = nil
            }) { proposal in
                AutomationWizardSheet(proposal: proposal) { _ in
                    if let reviewingOpportunity {
                        behavioralService.markApproved(reviewingOpportunity)
                    }
                    if let reviewingHabitPattern {
                        habitService.approve(reviewingHabitPattern)
                    }
                    automationsService.refresh()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            // Create service synchronously on first appear so the view never
            // shows a blank loading screen — behavioral + feed sections render immediately.
            if service == nil {
                service = HomeKnowledgeService(modelContainer: modelContext.container)
            }
        }
        .task { await performRefresh() }
    }

    private func reviewOpportunity(_ opportunity: AutomationOpportunity) {
        reviewingHabitPattern = nil
        reviewingOpportunity = opportunity
        reviewingProposal = proposal(from: opportunity)
    }

    private func reviewHabitPattern(_ pattern: HabitPattern) {
        reviewingOpportunity = nil
        reviewingHabitPattern = pattern
        reviewingProposal = proposal(from: pattern)
    }

    private func proposal(from opportunity: AutomationOpportunity) -> AutomationProposal {
        scenesService.refresh()
        let capabilities = homeKit.currentHome.map {
            AutomationCapabilityCatalog.capabilities(in: $0)
        } ?? []

        return AutomationProposalMapper.proposal(
            from: opportunity,
            capabilities: capabilities,
            scenes: scenesService.scenes
        )
    }

    private func proposal(from pattern: HabitPattern) -> AutomationProposal {
        scenesService.refresh()
        let capabilities = homeKit.currentHome.map {
            AutomationCapabilityCatalog.capabilities(in: $0)
        } ?? []

        return AutomationProposalMapper.proposal(
            from: pattern,
            capabilities: capabilities,
            scenes: scenesService.scenes
        )
    }

    // MARK: - Scroll content

    @ViewBuilder
    private func scrollContent(svc: HomeKnowledgeService) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    profileRow
                    intelligenceStatusHero {
                        withAnimation(.snappy) {
                            isDiaryExpanded = true
                            proxy.scrollTo("intelligenceDiarySection", anchor: .top)
                        }
                    }
                    domainAnomalyGrid
                    incoherenceSection
                    evidenceSection
                    trendOverviewSection
                    diaryDisclosureSection
                        .id("intelligenceDiarySection")

                    if !svc.hasAnyData && recentHomeInsights.isEmpty {
                        if svc.isLoading { loadingCard } else { emptyStateCard }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .refreshable { await performRefresh() }
        }
    }

    // MARK: - Redesigned Intelligence Dashboard

    private var activeInsights: [HomeInsight] {
        activeHomeInsights.map { $0.toHomeInsight() }
    }

    private var actionRequiredInsights: [HomeInsight] {
        activeInsights
            .filter { insight in
                insight.kind == .incoherence ||
                (insight.kind == .anomaly && insight.severity >= .medium)
            }
            .sorted(by: insightSort)
    }

    private var activeIncoherences: [HomeInsight] {
        activeInsights
            .filter { $0.kind == .incoherence }
            .sorted(by: insightSort)
    }

    private var activeAnomalyEvidences: [HomeInsight] {
        activeInsights
            .filter { $0.kind == .anomaly && $0.severity >= .medium }
            .sorted(by: insightSort)
    }

    private func intelligenceStatusHero(onOpenDiary: @escaping () -> Void) -> some View {
        let count = actionRequiredInsights.count
        let primary = actionRequiredInsights.first
        let color = globalStatusColor(for: actionRequiredInsights)
        let title = heroTitle(actionCount: count)
        let message = heroMessage(primary: primary, count: count)

        return IntelligenceStatusHeroCard(
            color: color,
            title: title,
            message: message,
            actionCount: count,
            trendLabel: globalTrendLabel(),
            ctaTitle: primary.map { heroActionTitle(for: $0) }
        ) { onOpenDiary() }
    }

    @ViewBuilder
    private var incoherenceSection: some View {
        let incoherences = Array(activeIncoherences.prefix(3))
        if !incoherences.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    icon: "arrow.triangle.2.circlepath",
                    title: String(
                        format: String(localized: "intelligence.incoherence.section",
                                       defaultValue: "Incoherences · %d active"),
                        activeIncoherences.count
                    )
                )
                VStack(spacing: 10) {
                    ForEach(incoherences, id: \.id) { insight in
                        IncoherenceConflictCard(insight: insight)
                    }
                    if activeIncoherences.count > incoherences.count {
                        Text(
                            String(
                                format: String(localized: "intelligence.incoherence.more",
                                               defaultValue: "%d more incoherences in the diary"),
                                activeIncoherences.count - incoherences.count
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var evidenceSection: some View {
        let evidences = Array(activeAnomalyEvidences.prefix(3))
        if !evidences.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(
                    icon: "waveform.path.ecg",
                    title: String(
                        format: String(localized: "intelligence.evidence.section",
                                       defaultValue: "Today's anomalies · %d active"),
                        activeAnomalyEvidences.count
                    )
                )
                VStack(spacing: 10) {
                    ForEach(evidences, id: \.id) { insight in
                        IntelligenceEvidenceCard(
                            insight: insight,
                            domain: visualDomain(for: insight)
                        )
                    }
                    if activeAnomalyEvidences.count > evidences.count {
                        Text(
                            String(
                                format: String(localized: "intelligence.evidence.more",
                                               defaultValue: "%d more evidence items in the diary"),
                                activeAnomalyEvidences.count - evidences.count
                            )
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    private var domainAnomalyGrid: some View {
        let summaries = intelligenceDomainSummaries()
        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                icon: "square.grid.2x2.fill",
                title: String(localized: "intelligence.domains.section", defaultValue: "Anomalies by domain")
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: 10)],
                spacing: 10
            ) {
                ForEach(summaries) { summary in
                    IntelligenceDomainTile(summary: summary)
                }
            }
        }
    }

    private var trendOverviewSection: some View {
        let trends = intelligenceTrendRows()
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(
                    icon: "chart.line.uptrend.xyaxis",
                    title: String(localized: "intelligence.trend.section", defaultValue: "Andamento")
                )
                Spacer()
                Text(String(localized: "intelligence.trend.window.7d", defaultValue: "7g"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
            VStack(spacing: 0) {
                ForEach(Array(trends.enumerated()), id: \.element.id) { index, row in
                    IntelligenceTrendRow(row: row)
                    if index < trends.count - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            )
        }
    }

    private var diaryDisclosureSection: some View {
        let eventCount = recentHomeInsights.filter {
            $0.updatedAt >= Date().addingTimeInterval(-7 * 24 * 3600)
        }.count

        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isDiaryExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.badge")
                        .font(.system(size: 16, weight: .semibold))
                    Text(
                        String(
                            format: String(localized: "intelligence.diary.collapsed",
                                           defaultValue: "Diary · last 7 days · %d events"),
                            eventCount
                        )
                    )
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(isDiaryExpanded ? 180 : 0))
                }
                .foregroundStyle(.primary)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                )
            }
            .buttonStyle(.plain)

            if isDiaryExpanded {
                feedSection()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func globalStatusColor(for insights: [HomeInsight]) -> Color {
        guard !insights.contains(where: { $0.severity >= .high }) else { return .red }
        guard !insights.isEmpty else { return .green }
        return .orange
    }

    private func heroTitle(actionCount: Int) -> String {
        if actionCount == 0 {
            return String(localized: "intelligence.hero.ok.title", defaultValue: "Tutto sotto controllo")
        }
        return String(
            format: String(localized: "intelligence.hero.attention.title",
                           defaultValue: "Attention — %d situations need action"),
            actionCount
        )
    }

    private func heroMessage(primary: HomeInsight?, count: Int) -> String {
        guard let primary else {
            return String(localized: "intelligence.hero.ok.message",
                          defaultValue: "No significant active incoherence or anomaly.")
        }

        let domain = visualDomain(for: primary).localizedTitle
        if count == 1 {
            return "\(domain): \(primary.title)."
        }
        return "\(domain): \(primary.title). \(count - 1) altre evidenze da verificare."
    }

    private func heroActionTitle(for insight: HomeInsight) -> String {
        if insight.kind == .incoherence {
            return String(localized: "intelligence.hero.cta.resolve", defaultValue: "View incoherence")
        }
        return String(localized: "intelligence.hero.cta.openDiary", defaultValue: "Open diary")
    }

    private func globalTrendLabel() -> String {
        let today = countInsights(daysAgo: 0)
        let yesterday = countInsights(daysAgo: 1)
        if today > yesterday {
            return String(localized: "intelligence.trend.worsening", defaultValue: "worsening")
        }
        if today < yesterday {
            return String(localized: "intelligence.trend.improving", defaultValue: "improving")
        }
        return String(localized: "intelligence.trend.stable", defaultValue: "stable")
    }

    private func intelligenceDomainSummaries() -> [IntelligenceDomainSummary] {
        IntelligenceVisualDomain.allCases.map { domain in
            let matching = activeInsights.filter { visualDomain(for: $0) == domain }
            let worst = matching.map(\.severity).max()
            return IntelligenceDomainSummary(
                domain: domain,
                count: matching.count,
                severity: worst ?? .info
            )
        }
    }

    private func intelligenceTrendRows() -> [IntelligenceTrendData] {
        let candidateDomains: [IntelligenceVisualDomain] = [.air, .climate, .routine]
        return candidateDomains.map { domain in
            let points = (0..<7).reversed().map { dayOffset in
                Double(countInsights(domain: domain, daysAgo: dayOffset))
            }
            let trend = trendDirection(points: points)
            return IntelligenceTrendData(domain: domain, points: points, direction: trend)
        }
    }

    private func trendDirection(points: [Double]) -> IntelligenceTrendDirection {
        guard let first = points.first, let last = points.last else { return .stable }
        if last > first { return .worsening }
        if last < first { return .improving }
        return .stable
    }

    private func countInsights(domain: IntelligenceVisualDomain? = nil, daysAgo: Int) -> Int {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return recentHomeInsights.filter { record in
            calendar.isDate(record.updatedAt, inSameDayAs: target) &&
            record.statusRaw != HomeInsightStatus.expired.rawValue &&
            record.statusRaw != HomeInsightStatus.resolved.rawValue &&
            (domain == nil || visualDomain(for: record.toHomeInsight()) == domain)
        }.count
    }

    private func visualDomain(for insight: HomeInsight) -> IntelligenceVisualDomain {
        if insight.kind == .habit || insight.kind == .prediction || insight.category == .habits {
            return .routine
        }
        if insight.category == .security || insight.category == .presence {
            return .security
        }
        if insight.category == .lighting {
            return .lights
        }
        if insight.category == .deviceHealth || insight.category == .maintenance {
            return .loads
        }

        let text = [
            insight.title,
            insight.message,
            insight.sourceEntityName ?? "",
            insight.relatedEntityName ?? "",
            insight.dedupeKey
        ].joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        if text.contains("co2") || text.contains("co₂") || text.contains("aria") || text.contains("air") || text.contains("pm") || text.contains("voc") {
            return .air
        }
        if text.contains("clima") || text.contains("climate") || text.contains("cool") || text.contains("heat") || text.contains("raffresc") || text.contains("temperatura") {
            return .climate
        }
        if text.contains("luce") || text.contains("light") {
            return .lights
        }
        if text.contains("presa") || text.contains("power") || text.contains("load") || text.contains("carico") {
            return .loads
        }
        return .routine
    }

    private func insightSort(_ lhs: HomeInsight, _ rhs: HomeInsight) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        let lhsScore = lhs.score?.composite ?? lhs.confidence
        let rhsScore = rhs.score?.composite ?? rhs.confidence
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.updatedAt > rhs.updatedAt
    }

    // MARK: - Section: Assistant Summary

    private func assistantSummaryCard(svc: HomeKnowledgeService) -> some View {
        let priorities = assistantPriorities(svc: svc)
        let pendingCount = habitService.pendingPatterns.count + behavioralService.pendingOpportunities.count
        let activeInsightCount = svc.recentInsights.filter { $0.statusRaw == HomeInsightStatus.active.rawValue }.count

        let title: String
        let message: String
        let color: Color
        let icon: String

        if pendingCount > 0 {
            title = String(localized: "intelligence.assistant.ready.title", defaultValue: "Something is ready")
            message = String(
                format: String(localized: "intelligence.assistant.ready.message",
                               defaultValue: "%d suggestion(s) can become automations after your confirmation."),
                pendingCount
            )
            color = BrandColor.primary
            icon = "sparkles"
        } else if activeInsightCount > 0 || !predictiveInsights.isEmpty {
            title = String(localized: "intelligence.assistant.watch.title", defaultValue: "The home needs attention")
            message = String(localized: "intelligence.assistant.watch.message",
                             defaultValue: "I found some environmental or predictive signals to review.")
            color = .orange
            icon = "exclamationmark.triangle.fill"
        } else if behavioralService.visiblePatternCount > 0 {
            title = String(localized: "intelligence.assistant.learning.title", defaultValue: "Learning routines")
            message = String(
                format: String(localized: "intelligence.assistant.learning.message",
                               defaultValue: "%d behavior(s) are being observed before becoming suggestions."),
                behavioralService.visiblePatternCount
            )
            color = .indigo
            icon = "brain.head.profile"
        } else {
            title = String(localized: "intelligence.assistant.ok.title", defaultValue: "The home is stable")
            message = String(localized: "intelligence.assistant.ok.message",
                             defaultValue: "I don't see urgent actions. I will keep observing environment, security, and habits.")
            color = .green
            icon = "checkmark.circle.fill"
        }

        return IntelligenceAssistantSummaryCard(
            title: title,
            message: message,
            icon: icon,
            color: color,
            priorities: priorities
        )
    }

    private func assistantPriorities(svc: HomeKnowledgeService) -> [IntelligenceAssistantPriority] {
        var items: [IntelligenceAssistantPriority] = []

        if let opp = behavioralService.pendingOpportunities.first {
            items.append(IntelligenceAssistantPriority(
                icon: "wand.and.sparkles",
                title: String(localized: "intelligence.assistant.priority.automation", defaultValue: "Automazione pronta"),
                detail: opp.naturalLanguage,
                color: BrandColor.primary
            ))
        }

        if let insight = svc.recentInsights.first(where: { $0.statusRaw == HomeInsightStatus.active.rawValue }) {
            items.append(IntelligenceAssistantPriority(
                icon: insight.severity == .anomaly ? "exclamationmark.octagon.fill" : "waveform.path.ecg",
                title: insight.roomName.isEmpty
                    ? String(localized: "intelligence.assistant.priority.environment", defaultValue: "Ambiente")
                    : insight.roomName,
                detail: insight.message,
                color: insight.severity == .anomaly ? .red : .orange
            ))
        }

        if let insight = predictiveInsights.first {
            items.append(IntelligenceAssistantPriority(
                icon: "clock.arrow.2.circlepath",
                title: String(localized: "intelligence.assistant.priority.prediction", defaultValue: "Previsto a breve"),
                detail: insight.message,
                color: .blue
            ))
        }

        if items.count < 3, let pattern = behavioralService.patterns
            .filter({ $0.status == .active && $0.confidence >= 0.15 })
            .sorted(by: { $0.confidence > $1.confidence })
            .first {
            items.append(IntelligenceAssistantPriority(
                icon: pattern.sfSymbol,
                title: String(localized: "intelligence.assistant.priority.learning", defaultValue: "Abitudine emergente"),
                detail: habitService.name(for: pattern) ?? pattern.localizedTitle,
                color: .indigo
            ))
        }

        return Array(items.prefix(3))
    }

    // MARK: - Section: Home Briefing

    private func homeBriefingCard(svc: HomeKnowledgeService) -> some View {
        let attentionCount = needsAttentionItems(svc: svc).count
        let opportunityCount = habitService.pendingPatterns.count + behavioralService.pendingOpportunities.count
        let learningCount = behavioralService.visiblePatternCount + svc.stableHabitsCount

        let title: String
        let message: String
        let color: Color
        let icon: String

        if attentionCount > 0 {
            title = String(localized: "intelligence.briefing.attention.title", defaultValue: "Review the home")
            message = String(
                format: String(localized: "intelligence.briefing.attention.message",
                               defaultValue: "%d signal(s) may need a decision or a closer look."),
                attentionCount
            )
            color = .orange
            icon = "exclamationmark.triangle.fill"
        } else if opportunityCount > 0 {
            title = String(localized: "intelligence.briefing.opportunity.title", defaultValue: "Automations are ready")
            message = String(
                format: String(localized: "intelligence.briefing.opportunity.message",
                               defaultValue: "%d suggestion(s) can be turned into automations."),
                opportunityCount
            )
            color = BrandColor.primary
            icon = "wand.and.stars"
        } else if learningCount > 0 {
            title = String(localized: "intelligence.briefing.learning.title", defaultValue: "The home is learning")
            message = String(localized: "intelligence.briefing.learning.message",
                             defaultValue: "Patterns are being observed. New suggestions will appear when confidence is high enough.")
            color = .indigo
            icon = "brain.head.profile"
        } else {
            title = String(localized: "intelligence.briefing.stable.title", defaultValue: "No urgent action")
            message = String(localized: "intelligence.briefing.stable.message",
                             defaultValue: "No priority signals are active right now. Recent activity remains available in the journal.")
            color = .green
            icon = "checkmark.circle.fill"
        }

        return HomeBriefingCard(
            title: title,
            message: message,
            icon: icon,
            color: color,
            metrics: [
                .init(value: "\(attentionCount)",
                      label: String(localized: "intelligence.briefing.metric.attention", defaultValue: "Needs review")),
                .init(value: "\(opportunityCount)",
                      label: String(localized: "intelligence.briefing.metric.opportunities", defaultValue: "Ready")),
                .init(value: svc.aiTrustScore > 0 ? "\(svc.aiTrustScore)" : "–",
                      label: String(localized: "intelligence.briefing.metric.trust", defaultValue: "AI trust"))
            ]
        )
    }

    // MARK: - Section: Needs Attention

    @ViewBuilder
    private func needsAttentionSection(svc: HomeKnowledgeService) -> some View {
        let items = needsAttentionItems(svc: svc)
        if items.isEmpty {
            emptyCard(
                icon: "checkmark.circle",
                text: String(localized: "intelligence.attention.empty",
                             defaultValue: "No active signals need review right now.")
            )
        } else {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                    DashboardAttentionRow(item: item)
                    if idx < items.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            )
        }
    }

    private func needsAttentionItems(svc: HomeKnowledgeService) -> [DashboardAttentionItem] {
        var items: [DashboardAttentionItem] = []

        for insight in svc.recentInsights
            .filter({ $0.statusRaw == HomeInsightStatus.active.rawValue })
            .prefix(2) {
            let color: Color = insight.severity == .anomaly ? .red : .orange
            items.append(DashboardAttentionItem(
                icon: insight.severity == .anomaly ? "exclamationmark.octagon.fill" : "waveform.path.ecg",
                title: insight.roomName.isEmpty
                    ? String(localized: "intelligence.attention.environment", defaultValue: "Environment signal")
                    : insight.roomName,
                detail: insight.message,
                color: color
            ))
        }

        for insight in predictiveInsights.prefix(max(0, 3 - items.count)) {
            items.append(DashboardAttentionItem(
                icon: "clock.arrow.2.circlepath",
                title: String(localized: "intelligence.attention.predictive", defaultValue: "Predicted soon"),
                detail: insight.message,
                color: .blue
            ))
        }

        for notification in proactiveService.liveNotifications
            .filter({ $0.priority >= .high })
            .prefix(max(0, 3 - items.count)) {
            items.append(DashboardAttentionItem(
                icon: notification.category.sfSymbol,
                title: notification.category.localizedTitle,
                detail: notification.displayHeadline,
                color: notificationColor(for: notification.category)
            ))
        }

        return Array(items.prefix(3))
    }

    // MARK: - Section: Opportunities

    @ViewBuilder
    private func opportunitiesSection() -> some View {
        let pendingHabits = Array(habitService.pendingPatterns.prefix(2))
        let pendingBehavioral = Array(behavioralService.pendingOpportunities.prefix(2))

        if pendingHabits.isEmpty && pendingBehavioral.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars.inverse")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(localized: "intelligence.opportunities.empty.title",
                                defaultValue: "No automation is ready yet"))
                        .font(.subheadline.weight(.medium))
                    Text(String(localized: "intelligence.opportunities.empty.detail",
                                defaultValue: "Habit candidates stay in Habits until they become actionable."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                NavigationLink(destination: HabitsView()) {
                    Text(String(localized: "intelligence.learning.openHabits", defaultValue: "Habits"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
            )
        } else {
            VStack(spacing: 12) {
                ForEach(pendingBehavioral) { opp in
                    BehavioralOpportunityCard(
                        opportunity: opp,
                        onApprove: {
                            reviewOpportunity(opp)
                        },
                        onSnooze:  { behavioralService.snooze(opp) },
                        onDismiss: { behavioralService.dismiss(opp) }
                    )
                }

                ForEach(pendingHabits) { pattern in
                    AISuggestionCard(
                        pattern: pattern,
                        onApprove: {
                            reviewHabitPattern(pattern)
                        },
                        onDismiss: { habitService.dismiss(pattern) }
                    )
                }
            }
        }
    }

    // MARK: - Section: Learning Summary

    private func learningSummarySection(svc: HomeKnowledgeService) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: svc.learningPhase.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(svc.learningPhase.accentColor)
                    .frame(width: 32, height: 32)
                    .background(svc.learningPhase.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 4) {
                    Text(svc.learningPhase.localizedTitle)
                        .font(.headline.weight(.semibold))
                    Text(svc.learningNarrative)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                NavigationLink(destination: HabitsView()) {
                    Text(String(localized: "intelligence.learning.openHabits", defaultValue: "Habits"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(BrandColor.primary.opacity(0.10), in: Capsule())
                }
            }

            HStack(spacing: 10) {
                LearningMetricTile(
                    value: "\(behavioralService.visiblePatternCount)",
                    label: String(localized: "intelligence.learning.metric.beingLearned", defaultValue: "Being learned"),
                    color: .indigo
                )
                LearningMetricTile(
                    value: "\(habitService.pendingPatterns.count + behavioralService.pendingOpportunities.count)",
                    label: String(localized: "intelligence.learning.metric.ready", defaultValue: "Ready"),
                    color: BrandColor.primary
                )
                LearningMetricTile(
                    value: "\(svc.stableHabitsCount)",
                    label: String(localized: "intelligence.learning.metric.stable", defaultValue: "Stable"),
                    color: .green
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(svc.learningPhase.accentColor.opacity(0.16), lineWidth: 1)
                )
        )
    }

    // MARK: - Section: Relevant Trends

    @ViewBuilder
    private func relevantTrendsSection(svc: HomeKnowledgeService) -> some View {
        if !svc.environmentalTrends.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "chart.line.uptrend.xyaxis",
                    title: String(localized: "intelligence.trends.relevant.header",
                                  defaultValue: "Relevant Trends")
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(svc.environmentalTrends.prefix(3)) { trend in
                            RoomTrendCard(trend: trend)
                                .frame(width: 160)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    // MARK: - Section: Abitudini (unified 3-tier)

    @ViewBuilder
    private func abitudiniSection() -> some View {
        let pendingHabits     = Array(habitService.pendingPatterns.prefix(3))
        let pendingBehavioral = Array(behavioralService.pendingOpportunities.prefix(3))
        let visibleCount      = behavioralService.visiblePatternCount
        let isAnalyzing       = habitService.isAnalyzing || behavioralService.isAnalyzing
        let hasContent        = !pendingHabits.isEmpty || !pendingBehavioral.isEmpty
                             || visibleCount > 0

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                sectionHeader(
                    icon: "brain.head.profile",
                    title: String(localized: "abitudini.section.header", defaultValue: "Habits")
                )
                Spacer(minLength: 8)
                if isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.75)
                        .padding(.trailing, 4)
                }
                Button {
                    Task { await habitService.analyzeHabits(knownPatterns: behavioralService.stablePatterns) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                }
                .disabled(isAnalyzing)
            }

            if !hasContent && !isAnalyzing {
                // Nothing yet — early observation phase
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.secondary.opacity(0.10))
                            .frame(width: 40, height: 40)
                        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "abitudini.empty.title",
                                    defaultValue: "Learning your habits"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(String(localized: "abitudini.empty.subtitle",
                                    defaultValue: "After a few days of use, the first suggestion will appear here."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))

            } else {

                // ── Tier 1: Suggerite ─────────────────────────────
                if !pendingHabits.isEmpty || !pendingBehavioral.isEmpty {
                    abitudiniTierLabel(
                        title: String(localized: "abitudini.tier.suggerite", defaultValue: "Suggested"),
                        icon: "sparkles"
                    )
                    ForEach(pendingBehavioral) { opp in
                        BehavioralOpportunityCard(
                            opportunity: opp,
                            onApprove: {
                                reviewOpportunity(opp)
                            },
                            onSnooze:  { behavioralService.snooze(opp) },
                            onDismiss: { behavioralService.dismiss(opp) }
                        )
                    }
                    ForEach(pendingHabits) { pattern in
                        AISuggestionCard(
                            pattern: pattern,
                            onApprove: {
                                reviewHabitPattern(pattern)
                            },
                            onDismiss: { habitService.dismiss(pattern) }
                        )
                    }
                }

                // ── Tier 2: In ascolto ────────────────────────────
                if visibleCount > 0 {
                    abitudiniTierLabel(
                        title: String(localized: "abitudini.tier.inAscolto", defaultValue: "Listening"),
                        icon: "antenna.radiowaves.left.and.right"
                    )
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(BrandColor.primary.opacity(0.10))
                                .frame(width: 40, height: 40)
                            Image(systemName: "brain")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(BrandColor.primary)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(
                                String(
                                    format: String(localized: "abitudini.inAscolto.title",
                                                   defaultValue: "%d behaviors being learned"),
                                    visibleCount
                                )
                            )
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            Text(String(localized: "abitudini.inAscolto.subtitle",
                                        defaultValue: "When confidence is sufficient, a suggestion will appear."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(BrandColor.primary.opacity(0.12), lineWidth: 1)
                            )
                    )
                }

            }
        }
    }

    private func abitudiniTierLabel(title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.3)
            .padding(.horizontal, 2)
            .padding(.top, 4)
    }

    // MARK: - Owner Indicator

    /// Shows a subtle read-only pill with the home owner's name when a profile
    /// has been auto-detected. Hidden in global (no-profile) mode.
    @ViewBuilder
    private var profileRow: some View {
        if let profile = familyPresenceService.activeProfile {
            let accent = profileAccent(profile.colorToken)
            HStack(spacing: 8) {
                Circle()
                    .fill(accent)
                    .frame(width: 8, height: 8)
                Text(profile.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(String(localized: "profile.owner.label", defaultValue: "Owner"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accent.opacity(0.20), lineWidth: 1)
                    )
            )
        }
    }

    private func profileAccent(_ token: String?) -> Color {
        switch token {
        case "green":  return .green
        case "orange": return .orange
        case "purple": return .purple
        case "red":    return .red
        case "teal":   return .teal
        default:       return BrandColor.primary
        }
    }

    // MARK: - Section: Predictive Insights

    @ViewBuilder
    private func predictiveInsightsSection() -> some View {
        if !predictiveInsights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "clock.arrow.2.circlepath",
                    title: String(localized: "intelligence.predictive.header",
                                  defaultValue: "What will likely happen")
                )
                VStack(spacing: 0) {
                    ForEach(Array(predictiveInsights.enumerated()), id: \.element.id) { idx, insight in
                        PredictiveAlertRow(insight: insight)
                        if idx < predictiveInsights.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                )
            }
        }
    }

    // MARK: - Section: Intelligence Feed (recent notifications, always visible)

    @ViewBuilder
    private func feedSection() -> some View {
        let recent = Array(proactiveService.feedNotifications.prefix(3))
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                if proactiveService.unreadCount > 0 {
                    Text("\(proactiveService.unreadCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BrandColor.primary, in: Capsule())
                }
                Spacer()
                NavigationLink(destination: IntelligenceFeedView()) {
                    Text(String(localized: "intelligence.feed.viewAll", defaultValue: "View all"))
                        .font(.subheadline)
                        .foregroundStyle(BrandColor.primary)
                }
            }
            if recent.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "clock.badge.questionmark")
                        .font(.title3)
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(String(localized: "feed.dashboard.empty",
                                defaultValue: "No events yet. The AI will start populating the diary after a few hours of use."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { idx, notif in
                        compactFeedRow(notif)
                        if idx < recent.count - 1 {
                            Divider().padding(.leading, 76)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                )
            }
        }
    }

    private func compactFeedRow(_ notif: ProactiveNotification) -> some View {
        let color   = notificationColor(for: notif.category)
        let timeStr = Self.feedTimeFormatter.string(from: notif.lastUpdatedAt)
        return HStack(alignment: .top, spacing: 10) {
            Text(timeStr)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
                .padding(.top, 4)
            ZStack {
                Circle()
                    .fill(color.opacity(notif.status.isLive ? 0.16 : 0.10))
                    .frame(width: 28, height: 28)
                Image(systemName: notif.category.sfSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
            }
            .overlay {
                if notif.status.isLive {
                    Circle()
                        .strokeBorder(color.opacity(0.5), lineWidth: 1)
                        .frame(width: 28, height: 28)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(notif.displayHeadline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(notif.displayBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Section: AI Insights (active only)

    @ViewBuilder
    private func aiInsightsSection(svc: HomeKnowledgeService) -> some View {
        let active = svc.recentInsights.filter {
            $0.statusRaw == HomeInsightStatus.active.rawValue
        }
        if !active.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "waveform.path.ecg",
                    title: String(localized: "intelligence.insights.header",
                                  defaultValue: "Environmental Insights")
                )
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(active.enumerated()), id: \.element.id) { idx, insight in
                        AIInsightTimelineRow(insight: insight)
                        if idx < active.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                )
            }
        }
    }

    // MARK: - Section: Environmental Trends (horizontal scroll)

    @ViewBuilder
    private func trendsSection(svc: HomeKnowledgeService) -> some View {
        if !svc.environmentalTrends.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(
                    icon: "thermometer.medium",
                    title: String(localized: "intelligence.trends.header",
                                  defaultValue: "Environmental Trends (7d)")
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(svc.environmentalTrends) { trend in
                            RoomTrendCard(trend: trend)
                                .frame(width: 160)
                        }
                    }
                    .padding(.horizontal, 1)
                }
            }
        }
    }

    // MARK: - Section: AI Effectiveness & Trust

    @ViewBuilder
    private func effectivenessSection(svc: HomeKnowledgeService) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                icon: "chart.line.uptrend.xyaxis",
                title: String(localized: "intelligence.effectiveness.header",
                              defaultValue: "AI Effectiveness")
            )
            if svc.totalExecuted == 0 {
                if !isAIEnabled {
                    aiDisabledCard
                } else {
                    emptyCard(
                        icon: "sparkle",
                        text: String(localized: "intelligence.ai.noData",
                                     defaultValue: "Collecting data")
                    )
                }
            } else {
                VStack(spacing: 10) {
                    if svc.aiTrustScore > 0 {
                        TrustScoreCard(score: svc.aiTrustScore)
                    }
                    HStack(spacing: 10) {
                        AIStatTile(
                            value: svc.totalExecuted,
                            label: String(localized: "intelligence.ai.executed.label",
                                          defaultValue: "Executed"),
                            color: BrandColor.primary
                        )
                        AIStatTile(
                            value: svc.totalHelpful,
                            label: String(localized: "intelligence.ai.helpful.label",
                                          defaultValue: "Helpful"),
                            color: .green
                        )
                    }
                    if !svc.effectivenessBreakdown.isEmpty {
                        let capped = Array(svc.effectivenessBreakdown.prefix(5))
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(capped.enumerated()), id: \.element.id) { idx, item in
                                IntentEffectivenessRow(
                                    item: item,
                                    intentLabel: intentLabel(for: item.intentRaw)
                                )
                                if idx < capped.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
                        )
                    }
                }
            }
        }
    }

    // MARK: - Empty / Loading

    private var emptyStateCard: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48))
                .foregroundStyle(BrandColor.primary.opacity(0.6))

            VStack(spacing: 8) {
                Text(
                    String(localized: "intelligence.empty.title",
                           defaultValue: "Your home is starting to reveal its habits.")
                )
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)

                Text(
                    String(localized: "intelligence.empty.subtitle",
                           defaultValue: "Use the app for a few days and this panel will come alive.")
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
        )
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().scaleEffect(1.1)
            Text(
                String(localized: "intelligence.loading", defaultValue: "Loading…")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView().scaleEffect(0.85)
            Text(String(localized: "intelligence.loading", defaultValue: "Analisi in corso…"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await performRefresh() }
            } label: {
                if isRefreshing {
                    ProgressView().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(BrandColor.primary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .padding(.horizontal, 2)
    }

    private func emptyCard(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
        )
    }

    // Shown in effectivenessSection when AI is disabled and there's no data yet.
    private var aiDisabledCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "brain.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "intelligence.ai.disabled.title",
                            defaultValue: "AI not active"))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(String(localized: "intelligence.ai.disabled.detail",
                            defaultValue: "Enable AI in Settings to receive contextual suggestions."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            NavigationLink(destination: AISettingsView()) {
                Text(String(localized: "intelligence.ai.disabled.action",
                            defaultValue: "Settings"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrandColor.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(BrandColor.primary.opacity(0.10), in: Capsule())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func performRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if service == nil {
            service = HomeKnowledgeService(modelContainer: modelContext.container)
        }
        await service?.refresh(
            habitPatterns: habitService.patterns,
            rules: [],
            tracker: executionService.tracker,
            aiIsOperational: AISettings().isOperational
        )
        await behavioralService.analyzeIfNeeded()
        await proactiveService.runCycleIfNeeded(
            behavioralService:  behavioralService,
            habitService:       habitService,
            occupancyService:   occupancyService,
            maintenanceService: maintenanceService,
            presenceOverride:   locationService.presenceState,
            homeKitService:     homeKit
        )
    }

    // MARK: - Intent label mapping

    private func intentLabel(for raw: String) -> String {
        switch raw {
        // Environmental
        case "coolRoom":          return String(localized: "intelligence.intent.coolRoom",          defaultValue: "Cooling")
        case "heatRoom":          return String(localized: "intelligence.intent.heatRoom",          defaultValue: "Heating")
        case "reduceHumidity":    return String(localized: "intelligence.intent.reduceHumidity",    defaultValue: "Humidity Reduction")
        case "increaseHumidity":  return String(localized: "intelligence.intent.increaseHumidity",  defaultValue: "Humidity Increase")
        case "improveAirQuality": return String(localized: "intelligence.intent.improveAirQuality", defaultValue: "Air Quality")
        case "ventilateRoom":     return String(localized: "intelligence.intent.ventilateRoom",     defaultValue: "Ventilation")
        case "reduceCO2":         return String(localized: "intelligence.intent.reduceCO2",         defaultValue: "CO₂ Reduction")
        case "reduceVOC":         return String(localized: "intelligence.intent.reduceVOC",         defaultValue: "VOC Reduction")
        case "respondToSmoke":    return String(localized: "intelligence.intent.respondToSmoke",    defaultValue: "Smoke Alert")
        case "respondToCO":       return String(localized: "intelligence.intent.respondToCO",       defaultValue: "CO Alert")
        // Sprint 28 — Lighting
        case "brightenRoom":      return String(localized: "intelligence.intent.brightenRoom",      defaultValue: "Brightness")
        case "dimRoom":           return String(localized: "intelligence.intent.dimRoom",           defaultValue: "Dim Light")
        case "setCircadianLight": return String(localized: "intelligence.intent.setCircadianLight", defaultValue: "Circadian Light")
        case "setScene":          return String(localized: "intelligence.intent.setScene",          defaultValue: "Scene")
        // Sprint 29 — Presence
        case "prepareForArrival": return String(localized: "intelligence.intent.prepareForArrival", defaultValue: "Prepare Arrival")
        case "secureForDeparture":return String(localized: "intelligence.intent.secureDeparture",   defaultValue: "Secure Departure")
        // Sprint 30 — Energy
        case "reduceConsumption": return String(localized: "intelligence.intent.reduceConsumption", defaultValue: "Reduce Consumption")
        case "enableEcoMode":     return String(localized: "intelligence.intent.enableEcoMode",     defaultValue: "Eco Mode")
        case "schedulePeakHours": return String(localized: "intelligence.intent.schedulePeakHours", defaultValue: "Peak Hours")
        // Sprint 32 — Security
        case "lockAll":           return String(localized: "intelligence.intent.lockAll",           defaultValue: "Lock Doors")
        case "closeGarage":       return String(localized: "intelligence.intent.closeGarage",       defaultValue: "Close Garage")
        case "armNightSecurity":  return String(localized: "intelligence.intent.armNightSecurity",  defaultValue: "Night Security")
        case "armAwaySecurity":   return String(localized: "intelligence.intent.armAwaySecurity",   defaultValue: "Away Security")
        default: return raw
        }
    }
}

// MARK: - Dashboard Cards

private struct BriefingMetric: Identifiable {
    let id = UUID()
    let value: String
    let label: String
}

private struct HomeBriefingCard: View {
    let title: String
    let message: String
    let icon: String
    let color: Color
    let metrics: [BriefingMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "intelligence.briefing.eyebrow", defaultValue: "Home Briefing"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                ForEach(metrics) { metric in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.value)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(metric.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(color.opacity(0.55))
                        .frame(height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .shadow(color: color.opacity(0.10), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

private struct DashboardAttentionItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let color: Color
}

private struct DashboardAttentionRow: View {
    let item: DashboardAttentionItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.color)
                .frame(width: 32, height: 32)
                .background(item.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private enum IntelligenceVisualDomain: String, CaseIterable, Identifiable {
    case air
    case climate
    case lights
    case loads
    case security
    case routine

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .air: return String(localized: "intelligence.domain.air", defaultValue: "Air")
        case .climate: return String(localized: "intelligence.domain.climate", defaultValue: "Climate")
        case .lights: return String(localized: "intelligence.domain.lights", defaultValue: "Lights")
        case .loads: return String(localized: "intelligence.domain.loads", defaultValue: "Loads")
        case .security: return String(localized: "intelligence.domain.security", defaultValue: "Security")
        case .routine: return String(localized: "intelligence.domain.routine", defaultValue: "Routine")
        }
    }

    var symbol: String {
        switch self {
        case .air: return "wind"
        case .climate: return "air.conditioner.horizontal.fill"
        case .lights: return "lightbulb.fill"
        case .loads: return "bolt.fill"
        case .security: return "shield.fill"
        case .routine: return "arrow.triangle.2.circlepath"
        }
    }

    var color: Color {
        switch self {
        case .air: return .teal
        case .climate: return .orange
        case .lights: return .yellow
        case .loads: return .purple
        case .security: return .red
        case .routine: return BrandColor.primary
        }
    }
}

private struct IntelligenceDomainSummary: Identifiable {
    let domain: IntelligenceVisualDomain
    let count: Int
    let severity: HomeInsightSeverity

    var id: String { domain.id }

    var severityColor: Color {
        switch severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low, .info: return count == 0 ? .green : .secondary
        }
    }
}

private enum IntelligenceTrendDirection {
    case improving
    case stable
    case worsening

    var localizedTitle: String {
        switch self {
        case .improving: return String(localized: "intelligence.trend.improves", defaultValue: "improves")
        case .stable: return String(localized: "intelligence.trend.isStable", defaultValue: "stable")
        case .worsening: return String(localized: "intelligence.trend.worsens", defaultValue: "worsens")
        }
    }

    var color: Color {
        switch self {
        case .improving: return .green
        case .stable: return .secondary
        case .worsening: return .red
        }
    }
}

private struct IntelligenceTrendData: Identifiable {
    let domain: IntelligenceVisualDomain
    let points: [Double]
    let direction: IntelligenceTrendDirection

    var id: String { domain.id }
}

private struct IntelligenceStatusHeroCard: View {
    let color: Color
    let title: String
    let message: String
    let actionCount: Int
    let trendLabel: String
    let ctaTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Circle()
                .fill(color)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 0) {
                Text("\(actionCount)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(trendLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .frame(minWidth: 58, alignment: .trailing)

            if let ctaTitle {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(ctaTitle)
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.secondary.opacity(0.28), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(color.opacity(0.28), lineWidth: 1)
                )
        )
    }
}

private struct IncoherenceConflictCard: View {
    let insight: HomeInsight

    private var color: Color {
        switch insight.severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low, .info: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Rectangle()
                .fill(color)
                .frame(width: 4)
                .clipShape(Capsule())

            HStack(spacing: 8) {
                Image(systemName: "air.conditioner.horizontal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                Image(systemName: "arrow.left.and.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
            }
            .frame(width: 82)

            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(insight.message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let recommendation = insight.recommendation {
                    Text(recommendation)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
        )
    }
}

private struct IntelligenceEvidenceCard: View {
    let insight: HomeInsight
    let domain: IntelligenceVisualDomain

    private var severityColor: Color {
        switch insight.severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low, .info: return .secondary
        }
    }

    private var roomLabel: String {
        insight.roomName ?? insight.sourceEntityName ?? domain.localizedTitle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(domain.color.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: domain.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(domain.color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(domain.localizedTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(domain.color)
                    Circle()
                        .fill(severityColor)
                        .frame(width: 6, height: 6)
                    Text(roomLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(insight.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(insight.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let score = insight.score {
                Text("\(Int(score.composite * 100))")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial)
        )
    }
}

private struct IntelligenceDomainTile: View {
    let summary: IntelligenceDomainSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: summary.domain.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(summary.count == 0 ? .secondary : summary.domain.color)
                Spacer()
                Circle()
                    .fill(summary.severityColor)
                    .frame(width: 8, height: 8)
            }

            Text("\(summary.count)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(summary.domain.localizedTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(minHeight: 124, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial.opacity(summary.count == 0 ? 0.62 : 1.0))
        )
    }
}

private struct IntelligenceTrendRow: View {
    let row: IntelligenceTrendData

    var body: some View {
        HStack(spacing: 14) {
            Text(row.domain.localizedTitle)
                .font(.subheadline.weight(.semibold))
                .frame(width: 68, alignment: .leading)

            IntelligenceSparkline(points: row.points)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(height: 34)

            Text(row.direction.localizedTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(row.direction.color)
                .frame(width: 82, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

private struct IntelligenceSparkline: Shape {
    let points: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }

        let maxValue = max(points.max() ?? 0, 1)
        let minValue = points.min() ?? 0
        let range = max(maxValue - minValue, 1)
        let step = rect.width / CGFloat(points.count - 1)

        for index in points.indices {
            let x = CGFloat(index) * step
            let normalized = (points[index] - minValue) / range
            let y = rect.maxY - CGFloat(normalized) * rect.height
            let point = CGPoint(x: x, y: y)
            if index == points.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }
}

private struct LearningMetricTile: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - IntelligenceAssistantSummaryCard

private struct IntelligenceAssistantPriority: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let detail: String
    let color: Color
}

private struct IntelligenceAssistantSummaryCard: View {
    let title: String
    let message: String
    let icon: String
    let color: Color
    let priorities: [IntelligenceAssistantPriority]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(color.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(String(localized: "intelligence.assistant.eyebrow", defaultValue: "Assistant"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !priorities.isEmpty {
                Divider()
                VStack(spacing: 10) {
                    ForEach(priorities) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(item.color)
                                .frame(width: 20)
                                .padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(color.opacity(0.55))
                        .frame(height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .shadow(color: color.opacity(0.10), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
    }
}

// MARK: - PhaseHeroCard

private struct PhaseHeroCard: View {

    let svc: HomeKnowledgeService
    @State private var animatedProgress: Double = 0

    var body: some View {
        VStack(spacing: 0) {

            // Row 1: phase label + pill
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: svc.learningPhase.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(svc.learningPhase.accentColor)

                Text(
                    String(
                        format: String(localized: "intelligence.hero.phase",
                                       defaultValue: "Phase %d of 5"),
                        svc.learningPhase.phaseNumber
                    )
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)

                Spacer()

                Text(svc.learningPhase.localizedTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(svc.learningPhase.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(svc.learningPhase.accentColor.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            // Row 2: phase description
            HStack {
                Text(svc.learningPhase.localizedDescription)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            // Row 3: learning narrative — replaces opaque numeric score (Sprint 25.B)
            HStack {
                Text(svc.learningNarrative)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            // Row 4: progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(svc.learningPhase.accentColor.opacity(0.12))
                        .frame(height: 5)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [svc.learningPhase.accentColor.opacity(0.6),
                                         svc.learningPhase.accentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * animatedProgress), height: 5)
                        .animation(.spring(response: 1.0, dampingFraction: 0.75),
                                   value: animatedProgress)
                }
            }
            .frame(height: 5)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            // Row 5: stats
            HStack(spacing: 0) {
                statChip(
                    icon: "calendar",
                    value: svc.daysSinceLearningStarted == 1
                        ? String(localized: "intelligence.hero.day.one", defaultValue: "1 day")
                        : String(
                            format: String(localized: "intelligence.hero.days",
                                           defaultValue: "%lld days"),
                            Int64(svc.daysSinceLearningStarted)
                          ),
                    label: String(localized: "intelligence.hero.learningSince",
                                  defaultValue: "Learning for")
                )
                Divider()
                    .frame(width: 1, height: 36)
                    .padding(.horizontal, 14)
                    .opacity(0.4)
                statChip(
                    icon: "chart.bar",
                    value: svc.totalEventsCount.formatted(),
                    label: String(localized: "intelligence.hero.eventsAnalyzed",
                                  defaultValue: "Data collected")
                )
                Divider()
                    .frame(width: 1, height: 36)
                    .padding(.horizontal, 14)
                    .opacity(0.4)
                statChip(
                    icon: "star.fill",
                    value: "\(svc.stableHabitsCount)",
                    label: String(localized: "intelligence.hero.stableHabits",
                                  defaultValue: "Stable")
                )
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(svc.learningPhase.accentColor.opacity(0.5))
                        .frame(height: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        )
        .shadow(color: svc.learningPhase.accentColor.opacity(0.10), radius: 12, x: 0, y: 4)
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 1)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.7)) {
                animatedProgress = svc.learningProgress
            }
        }
        .onChange(of: svc.learningProgress) { _, v in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                animatedProgress = v
            }
        }
    }

    private func statChip(icon: String, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - TrustScoreCard

private struct TrustScoreCard: View {

    let score: Int

    private var color: Color {
        switch score {
        case 75...100: return .green
        case 50..<75:  return Color(red: 0.7, green: 0.6, blue: 0.0)
        default:       return .orange
        }
    }

    private var shieldIcon: String {
        score >= 75 ? "checkmark.shield.fill" : score >= 50 ? "shield.fill" : "shield"
    }

    private var qualityLabel: String {
        score >= 75
            ? String(localized: "intelligence.trust.high",   defaultValue: "High")
            : score >= 50
            ? String(localized: "intelligence.trust.medium", defaultValue: "Good")
            : String(localized: "intelligence.trust.low",    defaultValue: "Growing")
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "intelligence.trust.label",
                            defaultValue: "AI Reliability"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    Text("\(score)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("/ 100")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(color.opacity(0.6))
                        .padding(.bottom, 4)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Image(systemName: shieldIcon)
                    .font(.system(size: 30))
                    .foregroundStyle(color)
                Text(qualityLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(color)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(color.opacity(0.20), lineWidth: 1)
                )
        )
    }

}

// MARK: - AISuggestionCard

private struct AISuggestionCard: View {

    let pattern: HabitPattern
    let onApprove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: pattern.sfSymbol)
                    .font(.system(size: 20))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(pattern.patternDescription)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if !pattern.roomName.isEmpty {
                            Text(pattern.roomName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(pattern.confidenceLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(confidenceColor)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onApprove) {
                    Label(
                        String(localized: "intelligence.suggestions.approve",
                               defaultValue: "Review automation"),
                        systemImage: "plus.circle.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.primary)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Text(String(localized: "intelligence.suggestions.dismiss",
                                defaultValue: "Dismiss"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(BrandColor.primary.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var confidenceColor: Color {
        switch pattern.confidence {
        case 0.80...1.0:  return .green
        case 0.60..<0.80: return Color(red: 0.7, green: 0.6, blue: 0.0)
        default:          return .orange
        }
    }
}

// MARK: - BehavioralOpportunityCard

private struct BehavioralOpportunityCard: View {

    let opportunity: AutomationOpportunity
    let onApprove:   () -> Void
    let onSnooze:    () -> Void
    let onDismiss:   () -> Void

    private var confidenceColor: Color {
        switch opportunity.confidence {
        case 0.90...1.0:  return .green
        case 0.75..<0.90: return BrandColor.primary
        default:          return Color(red: 0.7, green: 0.6, blue: 0.0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row: icon + description
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(opportunity.naturalLanguage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        if !opportunity.roomName.isEmpty && opportunity.triggerType != "characteristic" {
                            Text(opportunity.roomName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let schedule = opportunity.scheduleSummary {
                            Image(systemName: opportunity.triggerIcon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(schedule)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if opportunity.origin != .conversational {
                            Text(opportunity.confidenceLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(confidenceColor)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(
                                String(
                                    format: String(localized: "behavioral.card.observations",
                                                   defaultValue: "%d observations"),
                                    opportunity.observations
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "behavioral.opportunity.conversational.badge",
                                        defaultValue: "Requested by you"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BrandColor.secondary)
                        }
                    }
                    kindBadge
                }
                Spacer(minLength: 0)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button(action: onApprove) {
                    Label(
                        String(localized: "behavioral.opportunity.approve",
                               defaultValue: "Review automation"),
                        systemImage: "plus.circle.fill"
                    )
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.primary)
                .controlSize(.small)

                Button(action: onSnooze) {
                    Text(String(localized: "behavioral.opportunity.snooze",
                                defaultValue: "Later"))
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.small)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(BrandColor.primary.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var kindBadge: some View {
        let label: String
        let icon: String
        let color: Color

        if opportunity.origin == .conversational {
            label = String(localized: "habits.opportunity.kind.requested", defaultValue: "Richiesta da te")
            icon = "text.bubble.fill"
            color = BrandColor.secondary
        } else if opportunity.patternType == .scene && opportunity.effectSceneName != nil {
            label = String(localized: "habits.opportunity.kind.existingScene", defaultValue: "Scena esistente")
            icon = "theatermasks.fill"
            color = .indigo
        } else if opportunity.patternType == .scene {
            label = String(localized: "habits.opportunity.kind.routine", defaultValue: "Routine scoperta")
            icon = "sparkles"
            color = .purple
        } else {
            label = String(localized: "habits.opportunity.kind.newHabit", defaultValue: "Nuova abitudine")
            icon = "lightbulb.fill"
            color = .green
        }

        return Label(label, systemImage: icon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.10), in: Capsule())
    }
}

// MARK: - AIInsightTimelineRow

private struct AIInsightTimelineRow: View {

    let insight: HomeInsightSummary

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var severityColor: Color {
        switch insight.severity {
        case .info:    return .blue
        case .warning: return .orange
        case .anomaly: return .red
        }
    }

    private var severityIcon: String {
        switch insight.severity {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .anomaly: return "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severityIcon)
                .font(.system(size: 20))
                .foregroundStyle(severityColor)
                .frame(width: 28)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(insight.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Text(insight.roomName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(Self.relativeFormatter.localizedString(
                        for: insight.generatedAt, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - IntentEffectivenessRow

private struct IntentEffectivenessRow: View {

    let item: IntentEffectiveness
    let intentLabel: String

    @State private var animatedScore: Double = 0

    private var scoreColor: Color {
        switch item.averageScore {
        case 0.75...1.0:  return .green
        case 0.50..<0.75: return Color(red: 0.7, green: 0.6, blue: 0.0)
        default:          return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(intentLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(Int(item.averageScore * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(scoreColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(scoreColor.opacity(0.12))
                        .frame(height: 4)
                    Capsule()
                        .fill(scoreColor)
                        .frame(width: max(4, geo.size.width * animatedScore), height: 4)
                        .animation(.spring(response: 0.8, dampingFraction: 0.75),
                                   value: animatedScore)
                }
            }
            .frame(height: 4)
            Text(
                String(
                    format: String(localized: "intelligence.effectiveness.samples",
                                   defaultValue: "%lld samples"),
                    Int64(item.sampleCount)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.75).delay(0.15)) {
                animatedScore = item.averageScore
            }
        }
    }

}

// MARK: - RoomTrendCard

private struct RoomTrendCard: View {

    let trend: RoomTrend

    private var icon: String {
        switch trend.sensorTypeRaw {
        case "temperature":   return "thermometer.medium"
        case "humidity":      return "humidity.fill"
        case "carbonDioxide": return "aqi.medium"
        default:              return "aqi.low"
        }
    }

    private var trendLabel: String {
        switch trend.sensorTypeRaw {
        case "temperature":
            return String(localized: "intelligence.trends.hottest",     defaultValue: "Hottest room")
        case "humidity":
            return String(localized: "intelligence.trends.mostHumid",   defaultValue: "Most humid")
        case "carbonDioxide":
            return String(localized: "intelligence.trends.highestCO2",  defaultValue: "Highest CO₂")
        default:
            return String(localized: "intelligence.trends.worstAir",    defaultValue: "Air Quality")
        }
    }

    private var accentColor: Color {
        switch trend.sensorTypeRaw {
        case "temperature":   return .red
        case "humidity":      return .blue
        case "carbonDioxide": return .orange
        default:              return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(accentColor)
                Text(trendLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(trend.roomName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(trend.formattedAvg)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(accentColor)
                Text(
                    String(localized: "intelligence.trends.avgLabel", defaultValue: "7d avg")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(accentColor.opacity(0.20), lineWidth: 1)
                )
        )
    }
}

// MARK: - DomainCard

private struct DomainCard: View {

    let domain: DomainMaturity
    @State private var animatedProgress: Double = 0

    private var statusColor: Color {
        switch domain.status {
        case .notEnoughData: return .gray
        case .learning:      return .orange
        case .growing:       return Color(red: 0.7, green: 0.6, blue: 0.0)
        case .stable:        return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: domain.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(BrandColor.primary)
                    .frame(width: 22)
                Text(domain.localizedTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(statusColor.opacity(0.12))
                        .frame(height: 4)
                    Capsule()
                        .fill(statusColor)
                        .frame(width: max(4, geo.size.width * animatedProgress), height: 4)
                        .animation(.spring(response: 0.8, dampingFraction: 0.75),
                                   value: animatedProgress)
                }
            }
            .frame(height: 4)

            Text(domain.status.localizedLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(statusColor.opacity(0.10), in: Capsule())

            // Contextual hint pointing to next tier (Sprint 25.D)
            if let hint = domain.contextualHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(statusColor.opacity(0.20), lineWidth: 1)
                )
        )
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.75).delay(0.1)) {
                animatedProgress = domain.progress
            }
        }
        .onChange(of: domain.progress) { _, v in
            withAnimation(.spring(response: 0.6)) {
                animatedProgress = v
            }
        }
    }
}

// MARK: - IntelligenceSectionGroup (Sprint 25.A)

/// Visual separator / group header for the 3 macro-sections of the Intelligence Dashboard.
private struct IntelligenceSectionGroup: View {

    let title: String
    let icon:  String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(BrandColor.primary)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.top, 8)
        .padding(.bottom, -4)
    }
}

// MARK: - PredictiveAlertRow (Sprint 25.C)

private struct PredictiveAlertRow: View {

    let insight: PersistedHomeInsight

    private var sensorColor: Color {
        let name = (insight.sourceEntityName ?? "").localizedLowercase
        if name.contains("temp") {
            return .red
        } else if name.contains("humid") {
            return .blue
        } else if name.contains("co") || name.contains("carbon") {
            return .orange
        } else if name.contains("air") {
            return .purple
        } else {
            return BrandColor.primary
        }
    }

    private var sensorIcon: String {
        let name = (insight.sourceEntityName ?? "").localizedLowercase
        if name.contains("temp") {
            return "thermometer.medium"
        } else if name.contains("humid") {
            return "humidity.fill"
        } else if name.contains("co") || name.contains("carbon") {
            return "aqi.medium"
        } else if name.contains("air") {
            return "aqi.low"
        } else {
            return "waveform.path.ecg"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(sensorColor.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: sensorIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(sensorColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text(insight.roomName ?? String(localized: "intelligence.attention.environment",
                                                    defaultValue: "Environment signal"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(
                        String(
                            format: String(localized: "predictive.confidence.label",
                                           defaultValue: "%lld%% confidence"),
                            Int64(insight.confidence * 100)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - AIStatTile

private struct AIStatTile: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(color.opacity(0.20), lineWidth: 1)
                )
        )
    }
}
