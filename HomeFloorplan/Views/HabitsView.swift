import SwiftUI
import HomeKit

// MARK: - HabitsView

/// Narrative 5-section habits dashboard.
/// 1. La voce       — serif phrase from top-confidence pattern (always visible)
/// 2. Pronta per te — pending suggestion cards (hidden when empty)
/// 3. Attive        — active rule cards, round status dot, executor badge (hidden when empty)
/// 4. Sto imparando — patterns building toward 0.60 threshold (always visible)
/// 5. Monitoraggio  — real engine metrics + warm footer
struct HabitsView: View {

    @Environment(HabitAnalysisService.self)      private var habitService
    @Environment(BehavioralAnalysisService.self) private var behavioralService
    @Environment(RuleEngineService.self)         private var ruleEngine
    @Environment(HomeKitService.self)            private var homeKit

    @State private var showAISettings       = false
    @State private var showAllOpportunities = false
    @State private var editingRule:   Rule?
    @State private var pendingDelete: Rule?
    @State private var executingRule: Rule?
    @State private var eligibleEvents: Int  = 0

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "habits.title", defaultValue: "Habits"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showAISettings) {
                    NavigationStack { AISettingsView() }
                }
                .sheet(item: $editingRule) { rule in
                    RuleEditorView(rule: rule) { draft in
                        guard let draft else { return }
                        ruleEngine.updateRule(rule, from: draft)
                    }
                }
                .alert(
                    String(localized: "rules.delete.title", defaultValue: "Eliminare la regola?"),
                    isPresented: Binding(
                        get: { pendingDelete != nil },
                        set: { if !$0 { pendingDelete = nil } }
                    ),
                    presenting: pendingDelete
                ) { rule in
                    Button(String(localized: "rules.delete.confirm", defaultValue: "Elimina"),
                           role: .destructive) {
                        Task { try? await ruleEngine.deleteRule(rule, home: homeKit.currentHome) }
                    }
                    Button(String(localized: "rules.delete.cancel", defaultValue: "Annulla"),
                           role: .cancel) {}
                } message: { rule in
                    Text(rule.ruleDescription)
                }
                .task {
                    eligibleEvents = behavioralService.eligibleEventCount(days: 30)
                    habitService.scheduleNaming(
                        reports: behavioralService.lastBurstReport,
                        patterns: behavioralService.patterns
                    )
                }
                .onChange(of: behavioralService.pendingOpportunities.count) { _, _ in
                    showAllOpportunities = false
                }
        }
    }

    // MARK: - Computed helpers

    private var isAIConfigured: Bool {
        let settings = AISettings()
        return settings.isOperational && settings.suggestionsEnabled
    }

    /// Top-confidence active pattern — source for the narrative phrase (≥ 0.20, any status tier).
    private var narrativePattern: BehavioralPattern? {
        behavioralService.patterns
            .filter { $0.status == .active && $0.confidence >= 0.20 }
            .sorted { $0.confidence > $1.confidence }
            .first
    }

    /// Patterns still building confidence — excludes those already surfaced as pending suggestions.
    private var learningPatterns: [BehavioralPattern] {
        let pendingIDs = Set(behavioralService.pendingOpportunities.map(\.patternID))
        return Array(
            behavioralService.patterns
                .filter { p in
                    p.status == .active &&
                    p.confidence >= 0.45 &&
                    !pendingIDs.contains(p.id)
                }
                .sorted { $0.confidence > $1.confidence }
                .prefix(8)
        )
    }

    /// Early weak signals: visible to build trust, not actionable enough to create automations.
    private var noticingPatterns: [BehavioralPattern] {
        let pendingIDs = Set(behavioralService.pendingOpportunities.map(\.patternID))
        return Array(
            behavioralService.patterns
                .filter { p in
                    p.status == .active &&
                    p.confidence >= 0.15 &&
                    p.confidence < 0.45 &&
                    !pendingIDs.contains(p.id)
                }
                .sorted { $0.confidence > $1.confidence }
                .prefix(3)
        )
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        List {
            voiceSection
            noticingSection
            readySection
            activeSection
            learningSection
            monitoringSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Section 1: La voce

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Eyebrow: sparkles + brand label
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.secondary)
                    Text(String(localized: "habits.voice.eyebrow",
                                defaultValue: "your home is telling you"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.secondary)
                        .textCase(.uppercase)
                        .kerning(0.5)
                }

                if let pattern = narrativePattern {
                    Text(narrativeSentence(for: pattern))
                        .font(.system(size: 19, weight: .medium, design: .default))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.primary)

                    Text(contextLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    voiceWaitingState
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var voiceWaitingState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "habits.voice.waiting",
                        defaultValue: "I'm just starting to observe your home. In a few days I'll tell you about the first habits."))
                .font(.system(size: 18, weight: .medium, design: .default))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "habits.voice.placeholder.subtitle",
                        defaultValue: "Use your home a few more days to see the first habits."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Deterministic narrative sentence for the top-confidence pattern.
    /// Uses per-dayType keys so grammar is correct in both EN and IT.
    /// %1$@ = time (HH:MM), %2$@ = name (accessory or routine name).
    private func narrativeSentence(for pattern: BehavioralPattern) -> String {
        let clusterName = habitService.name(for: pattern)
        let displayName = clusterName ?? pattern.accessoryName
        let time        = pattern.avgTimeString
        let daySuffix   = pattern.dayType?.rawValue ?? "daily"

        switch pattern.patternType {
        case .scene:
            let routineName = clusterName ?? pattern.localizedTitle
            let template = localizedNarrativeTemplate(
                "habits.voice.narrative.scene.\(daySuffix)",
                defaultValue: "Around \(time), the \(routineName) routine kicks in."
            )
            return String(format: template, time, routineName)

        case .temporal, .lighting:
            let actionKey: String
            switch pattern.action {
            case .on:      actionKey = "on"
            case .off:     actionKey = "off"
            case .dim:     actionKey = "dim"
            default:       actionKey = "activate"
            }
            let template = localizedNarrativeTemplate(
                "habits.voice.narrative.temporal.\(actionKey).\(daySuffix)",
                defaultValue: "Around \(time), \(displayName) changes."
            )
            return String(format: template, time, displayName)

        case .sequential:
            let cause = pattern.causeName
                ?? localizedNarrativeTemplate("habits.voice.narrative.cause.unknown",
                                              defaultValue: "an event")
            let template = localizedNarrativeTemplate(
                "habits.voice.narrative.sequential",
                defaultValue: "Almost always after \(cause), \(displayName) follows."
            )
            return String(format: template, cause, displayName)

        case .contextual:
            return pattern.localizedTitle
        }
    }

    private func localizedNarrativeTemplate(_ key: String, defaultValue: String) -> String {
        NSLocalizedString(key, tableName: "Localizable", bundle: .main,
                          value: defaultValue, comment: "")
    }

    /// Context summary line: behaviors count + automations count.
    private var contextLine: String {
        String(
            format: String(localized: "habits.voice.context",
                           defaultValue: "Last 30 days · %1$d behaviors · %2$d automations"),
            behavioralService.patterns.count,
            ruleEngine.rules.count
        )
    }

    // MARK: - Section 1b: Noticing

    @ViewBuilder
    private var noticingSection: some View {
        let patterns = noticingPatterns
        if !patterns.isEmpty {
            Section {
                ForEach(patterns) { pattern in
                    noticingPatternRow(pattern)
                }
            } header: {
                Label(String(localized: "habits.noticing.header", defaultValue: "I'm noticing"),
                      systemImage: "eye.fill")
            } footer: {
                Text(String(localized: "habits.noticing.footer",
                            defaultValue: "These signals are still weak: I show them for transparency, but I won't turn them into automations until they are more reliable."))
            }
        }
    }

    private func noticingPatternRow(_ pattern: BehavioralPattern) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(BrandColor.primary.opacity(0.10))
                    .frame(width: 36, height: 36)
                Image(systemName: pattern.sfSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BrandColor.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(habitService.name(for: pattern) ?? pattern.localizedTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(String(localized: "habits.noticing.signal", defaultValue: "Segnale iniziale"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(pattern.confidenceLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Section 2: Pronta per te

    @ViewBuilder
    private var readySection: some View {
        let pendingBehavioral = behavioralService.pendingOpportunities
        let pendingHabits     = isAIConfigured ? habitService.pendingPatterns : []
        let isLoading         = habitService.isAnalyzing || behavioralService.isAnalyzing
        let hasContent        = isLoading || !pendingBehavioral.isEmpty || !pendingHabits.isEmpty

        if hasContent {
            Section {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView().scaleEffect(0.85)
                        Text(String(localized: "habits.analyzing",
                                    defaultValue: "Analyzing habits…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                let visible = showAllOpportunities
                    ? pendingBehavioral
                    : Array(pendingBehavioral.prefix(5))
                ForEach(visible) { opp in
                    behavioralOpportunityRow(opp)
                }

                if pendingBehavioral.count > 5 {
                    Button {
                        showAllOpportunities.toggle()
                    } label: {
                        Text(showAllOpportunities
                            ? String(localized: "habits.opportunities.showLess",
                                     defaultValue: "Show fewer suggestions")
                            : String(format: String(localized: "habits.opportunities.showMore",
                                                    defaultValue: "Show %d more suggestions"),
                                     pendingBehavioral.count - 5)
                        )
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }

                ForEach(pendingHabits) { pattern in
                    habitPatternRow(pattern)
                }
            } header: {
                Label(String(localized: "habits.section.ready", defaultValue: "Ready for You"),
                      systemImage: "sparkles")
            } footer: {
                Text(String(localized: "habits.patterns.footer",
                            defaultValue: "Based on the last 14 days of activity. Approve a pattern to create an automatic rule."))
            }
        }
    }

    // MARK: - Section 3: Attive

    @ViewBuilder
    private var activeSection: some View {
        if !ruleEngine.rules.isEmpty {
            Section {
                ForEach(ruleEngine.rules) { rule in
                    ruleCard(rule)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { runNow(rule) } label: {
                                Label(String(localized: "rules.action.run",
                                             defaultValue: "Esegui ora"),
                                      systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = rule } label: {
                                Label(String(localized: "rules.action.delete",
                                             defaultValue: "Elimina"),
                                      systemImage: "trash")
                            }
                        }
                }

                NavigationLink {
                    ActiveRulesView()
                } label: {
                    Text(String(localized: "habits.active.viewAll",
                                defaultValue: "View all automations"))
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                }
            } header: {
                Label(String(localized: "habits.active.header",
                             defaultValue: "active · your home does these for you"),
                      systemImage: "bolt.fill")
            }
        }
    }

    // MARK: - Rule card

    @ViewBuilder
    private func ruleCard(_ rule: Rule) -> some View {
        Button { editingRule = rule } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .topTrailing) {
                    Circle()
                        .fill(BrandColor.primary.opacity(0.10))
                        .frame(width: 40, height: 40)
                    Image(systemName: actionIcon(for: rule.actionType))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(BrandColor.primary)
                        .frame(width: 40, height: 40)
                    // Round status dot (green = enabled, gray = paused)
                    Circle()
                        .fill(rule.isEnabled ? Color.green : Color.secondary.opacity(0.30))
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5))
                        .offset(x: 1, y: -1)
                        .accessibilityLabel(rule.isEnabled
                            ? String(localized: "habits.active.statusOn", defaultValue: "active")
                            : String(localized: "habits.active.statusOff", defaultValue: "paused"))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(rule.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(rule.ruleDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        badgeView(
                            icon: rule.executionModeIcon,
                            label: rule.executionModeLabel,
                            color: rule.executionMode == "homeKit" ? .blue : .orange
                        )
                        if rule.generatedByAI {
                            badgeView(icon: "brain", label: "AI", color: .purple)
                        }
                    }

                    if !rule.isEnabled {
                        Label(String(localized: "habits.active.paused", defaultValue: "Paused"),
                              systemImage: "pause.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let label = lastExecutedLabel(for: rule) {
                        Label(label, systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                if executingRule?.id == rule.id {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 24)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section 4: Learning

    @ViewBuilder
    private var learningSection: some View {
        let learning = learningPatterns
        Section {
            if learning.isEmpty {
                learningMicroState
            } else {
                ForEach(learning) { pattern in
                    learningPatternRow(pattern)
                }
            }
        } header: {
            Label(
                String(format: String(localized: "habits.learning.sectionTitle",
                                      defaultValue: "Learning · %d"),
                       learning.count),
                systemImage: "brain.head.profile"
            )
        } footer: {
            if !learning.isEmpty {
                Text(String(localized: "habits.learning.footer",
                            defaultValue: "Swipe left to hide a habit you are not interested in."))
            }
        }
    }

    private var learningMicroState: some View {
        HStack(spacing: 12) {
            Image(systemName: "rays")
                .font(.system(size: 18))
                .foregroundStyle(BrandColor.secondary.opacity(0.70))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "habits.learning.microstate",
                            defaultValue: "Still collecting data"))
                    .font(.subheadline.weight(.medium))
                Text(String(localized: "habits.voice.placeholder.subtitle",
                            defaultValue: "Use your home a few more days to see the first habits."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Section 5: Monitoraggio

    @ViewBuilder
    private var monitoringSection: some View {
        Section {
            monitoringMetricCards
            if behavioralService.patterns.count > 0 {
                tierChipsRow
            }
        } header: {
            Label(String(localized: "habits.monitoring.header", defaultValue: "Monitoring"),
                  systemImage: "waveform.path.ecg")
        } footer: {
            Text(String(localized: "habits.monitoring.footer",
                        defaultValue: "The on-device engine analyzes the last 30 days of activity without sending data externally."))
        }
    }

    @ViewBuilder
    private var monitoringMetricCards: some View {
        HStack(spacing: 10) {
            metricCard(
                value: "\(behavioralService.patterns.count)",
                title: String(localized: "habits.monitoring.behaviors.title",
                              defaultValue: "Raw Patterns"),
                subtitle: String(localized: "habits.monitoring.behaviors.subtitle",
                                 defaultValue: "engine total"),
                icon: "chart.bar.fill",
                color: BrandColor.primary
            )
            metricCard(
                value: "\(behavioralService.visiblePatternCount)",
                title: String(localized: "habits.monitoring.learning.title",
                              defaultValue: "Being Learned"),
                subtitle: String(localized: "habits.monitoring.learning.subtitle",
                                 defaultValue: "visible signals"),
                icon: "brain.head.profile",
                color: .indigo
            )
            metricCard(
                value: "\(eligibleEvents)",
                title: String(localized: "habits.monitoring.eventsCard.title",
                              defaultValue: "Events Collected"),
                subtitle: String(localized: "habits.monitoring.eventsCard.subtitle",
                                 defaultValue: "last 30 days"),
                icon: "bolt.fill",
                color: BrandColor.secondary
            )
        }
        .padding(.vertical, 4)
    }

    private func metricCard(
        value: String, title: String, subtitle: String, icon: String, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private var tierChipsRow: some View {
        let emerging = behavioralService.patterns.filter { $0.tier == .emerging }.count
        let forming  = behavioralService.patterns.filter { $0.tier == .forming  }.count
        let stable   = behavioralService.patterns.filter {
            $0.tier == .stable || $0.tier == .highConfidence
        }.count

        VStack(alignment: .leading, spacing: 8) {
            if let last = behavioralService.lastAnalyzed {
                Text(
                    String(format: String(localized: "habits.monitoring.lastScan",
                                          defaultValue: "Last scan: %@"),
                           last.formatted(.relative(presentation: .named)))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                tierPill(count: emerging,
                         label: String(localized: "habits.tier.emerging",
                                       defaultValue: "Emerging"),
                         color: .secondary)
                tierPill(count: forming,
                         label: String(localized: "habits.tier.forming",
                                       defaultValue: "Forming"),
                         color: .orange)
                tierPill(count: stable,
                         label: String(localized: "habits.tier.stable",
                                       defaultValue: "Stable"),
                         color: .green)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer section (encouragement)

    @ViewBuilder
    private var footerSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "leaf.fill")
                    .font(.title3)
                    .foregroundStyle(BrandColor.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "habits.footer.encourage.title",
                                defaultValue: "The more you use it, the more I learn"))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(BrandColor.primary)
                    Text(String(localized: "habits.footer.encourage.subtitle",
                                defaultValue: "Just a few more days for the first ready suggestions."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(BrandColor.surfaceLight)
    }

    // MARK: - Behavioral opportunity row

    @ViewBuilder
    private func behavioralOpportunityRow(_ opp: AutomationOpportunity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(BrandColor.secondary.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 17))
                        .foregroundStyle(BrandColor.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(opp.naturalLanguage)
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        // roomName is the sensor room for characteristic rules — skip it
                        // (scheduleSummary already includes it)
                        if !opp.roomName.isEmpty && opp.triggerType != "characteristic" {
                            Text(opp.roomName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if let schedule = opp.scheduleSummary {
                            Image(systemName: opp.triggerIcon)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(schedule)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                        }
                        if opp.origin == .conversational {
                            Text(String(localized: "behavioral.opportunity.conversational.badge",
                                        defaultValue: "Requested by you"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BrandColor.secondary)
                        } else {
                            Text(opp.confidenceLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("·").font(.caption2).foregroundStyle(.tertiary)
                            Text(
                                String(format: String(localized: "behavioral.card.observations",
                                                      defaultValue: "%d observations"),
                                       opp.observations)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    // Scena multi-azione collegata
                    if let sceneName = opp.effectSceneName {
                        Label(sceneName, systemImage: "theatermasks.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.indigo.opacity(0.10), in: Capsule())
                    }
                    opportunityKindBadge(opp)
                }
                Spacer()
            }
            HStack(spacing: 12) {
                Button {
                    let rule = opp.buildRule()
                    Task {
                        do {
                            _ = try await ruleEngine.insertRule(rule, home: homeKit.currentHome)
                            behavioralService.approve(opp)
                        } catch {
                            dprint("Habits: failed to create rule from opportunity \(opp.id): \(error.localizedDescription)")
                        }
                    }
                } label: {
                    Text(String(localized: "behavioral.opportunity.approve",
                                defaultValue: "Create automation"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.primary)

                Button { behavioralService.snooze(opp) } label: {
                    Text(String(localized: "behavioral.opportunity.snooze",
                                defaultValue: "Later"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button(role: .destructive) { behavioralService.dismiss(opp) } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func opportunityKindBadge(_ opp: AutomationOpportunity) -> some View {
        let label: String
        let icon: String
        let color: Color

        if opp.origin == .conversational {
            label = String(localized: "habits.opportunity.kind.requested", defaultValue: "Richiesta da te")
            icon = "text.bubble.fill"
            color = BrandColor.secondary
        } else if opp.patternType == .scene && opp.effectSceneName != nil {
            label = String(localized: "habits.opportunity.kind.existingScene", defaultValue: "Scena esistente")
            icon = "theatermasks.fill"
            color = .indigo
        } else if opp.patternType == .scene {
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

    // MARK: - Habit pattern row (AI patterns)

    @ViewBuilder
    private func habitPatternRow(_ pattern: HabitPattern) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                ZStack {
                    Circle()
                        .fill(BrandColor.highlight.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: pattern.sfSymbol)
                        .font(.system(size: 17))
                        .foregroundStyle(BrandColor.highlight)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(pattern.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(pattern.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(pattern.confidenceLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(confidenceColor(pattern.confidence), in: Capsule())
            }
            HStack(spacing: 12) {
                Button { approveHabitPattern(pattern) } label: {
                    Text(String(localized: "habits.pattern.approve",
                                defaultValue: "Create Automatic Rule"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.primary)

                Button(role: .destructive) { habitService.dismiss(pattern) } label: {
                    Text(String(localized: "habits.pattern.dismiss",
                                defaultValue: "Dismiss"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Learning pattern row

    @ViewBuilder
    private func learningPatternRow(_ pattern: BehavioralPattern) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(learningProgressColor(pattern.confidence).opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: pattern.sfSymbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(learningProgressColor(pattern.confidence))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(habitService.name(for: pattern) ?? pattern.localizedTitle)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(learningStatusLabel(for: pattern))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(pattern.confidenceLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(learningProgressColor(pattern.confidence))
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)
                    Capsule()
                        .fill(learningProgressColor(pattern.confidence))
                        .frame(
                            width: max(4, geo.size.width * min(1.0, pattern.confidence / 0.60)),
                            height: 4
                        )
                }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                behavioralService.dismissPattern(pattern)
            } label: {
                Label(String(localized: "habits.learning.dismiss",
                             defaultValue: "Non mi interessa"),
                      systemImage: "hand.thumbsdown")
            }
        }
    }

    // MARK: - Shared helpers

    private func tierPill(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text("\(count)")
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.10), in: Capsule())
    }

    @ViewBuilder
    private func badgeView(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func lastExecutedLabel(for rule: Rule) -> String? {
        guard let date = rule.lastExecutedAt else { return nil }
        let cal     = Calendar.current
        let now     = Date()
        let timeStr = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) {
            return "Oggi \(timeStr)"
        } else if cal.isDateInYesterday(date) {
            return "Ieri \(timeStr)"
        } else if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(timeStr)"
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
    }

    private func actionIcon(for actionType: String) -> String {
        switch actionType {
        case "on":       return "lightbulb.fill"
        case "off":      return "lightbulb.slash"
        case "dim":      return "sun.min.fill"
        case "open":     return "arrow.up.square"
        case "close":    return "arrow.down.square"
        case "setMode":  return "slider.horizontal.3"
        case "setTemp":  return "thermometer.medium"
        case "setSpeed": return "wind"
        default:         return "bolt.fill"
        }
    }

    private func learningProgressColor(_ confidence: Double) -> Color {
        switch confidence {
        case 0.45...: return .green
        case 0.25..<0.45: return .orange
        default: return Color.secondary
        }
    }

    private func learningStatusLabel(for pattern: BehavioralPattern) -> String {
        switch pattern.confidence {
        case ..<0.25:
            return String(localized: "habits.learning.statusLow",
                          defaultValue: "Still observing this habit")
        case 0.25..<0.45:
            return String(localized: "habits.learning.statusMid",
                          defaultValue: "Confidence is growing — a few more days")
        default:
            return String(localized: "habits.learning.statusHigh",
                          defaultValue: "Almost ready to become a suggestion")
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        switch confidence {
        case 0.9...1.0: return .green
        case 0.75..<0.9: return .orange
        default: return .gray
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                habitService.scheduleNaming(
                    reports: behavioralService.lastBurstReport,
                    patterns: behavioralService.patterns
                )
            } label: {
                if habitService.isAnalyzing {
                    ProgressView().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(habitService.isAnalyzing)
        }
    }

    // MARK: - Actions

    private func approveHabitPattern(_ pattern: HabitPattern) {
        Task {
            if let home = homeKit.currentHome {
                do {
                    try await ruleEngine.createRule(from: pattern, home: home)
                    habitService.approve(pattern)
                } catch {
                    dprint("Habits: failed to create rule from habit pattern \(pattern.id): \(error.localizedDescription)")
                }
            }
        }
    }

    private func runNow(_ rule: Rule) {
        guard let home = homeKit.currentHome else { return }
        executingRule = rule
        Task {
            await ruleEngine.executeNow(rule, home: home)
            executingRule = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}
