import SwiftUI
import HomeKit

// MARK: - HabitsView

/// Narrative 5-section habits dashboard.
/// 1. La voce       — serif phrase from top-confidence pattern (always visible)
/// 2. Pronta per te — pending suggestion cards (hidden when empty)
/// 3. Attive        — HomeKit automations created through the unified builder
/// 4. Sto imparando — patterns building toward 0.60 threshold (always visible)
/// 5. Monitoraggio  — real engine metrics + warm footer
struct HabitsView: View {

    @Environment(HabitAnalysisService.self)      private var habitService
    @Environment(BehavioralAnalysisService.self) private var behavioralService
    @Environment(HomeKitService.self)            private var homeKit
    @Environment(HomeKitScenesService.self)      private var scenesService
    @Environment(HomeKitAutomationsService.self) private var automationsService

    @State private var showAISettings       = false
    @State private var showAllOpportunities = false
    @State private var reviewingProposal: AutomationProposal?
    @State private var reviewingOpportunity: AutomationOpportunity?
    @State private var reviewingHabitPattern: HabitPattern?
    @State private var showManualAutomationWizard = false
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
                .sheet(isPresented: $showManualAutomationWizard, onDismiss: {
                    automationsService.refresh()
                }) {
                    AutomationWizardSheet()
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
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

    private func proposal(from opportunity: AutomationOpportunity) -> AutomationProposal {
        scenesService.refresh()
        let capabilities = homeKit.currentHome.map {
            AutomationCapabilityCatalog.capabilities(in: $0)
        } ?? []

        return AutomationProposalMapper.proposal(
            from: opportunity,
            capabilities: capabilities,
            scenes: scenesService.scenes,
            sourcePattern: behavioralService.patterns.first { $0.id == opportunity.patternID }
        )
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
            automationsService.automations.count
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
        EmptyView()
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
                    reviewingOpportunity = opp
                    reviewingProposal = proposal(from: opp)
                } label: {
                    Text(String(localized: "behavioral.opportunity.approve",
                                defaultValue: "Review automation"))
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
                    Text(pattern.patternDescription)
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
                Button { reviewHabitPattern(pattern) } label: {
                    Text(String(localized: "habits.pattern.approve",
                                defaultValue: "Review automation"))
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

            if !isPatternConvertibleToAutomation(pattern), pattern.confidence >= 0.45 {
                Button {
                    showManualAutomationWizard = true
                } label: {
                    Label(String(localized: "habits.learning.createManual",
                                 defaultValue: "Create manually"),
                          systemImage: "plus.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(BrandColor.primary)
            }
        }
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isPatternConvertibleToAutomation(pattern), pattern.confidence >= 0.45 {
                Button {
                    showManualAutomationWizard = true
                } label: {
                    Label(String(localized: "habits.learning.createManual",
                                 defaultValue: "Create manually"),
                          systemImage: "plus.circle")
                }
                .tint(BrandColor.primary)
            }

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

    private func learningProgressColor(_ confidence: Double) -> Color {
        switch confidence {
        case 0.45...: return .green
        case 0.25..<0.45: return .orange
        default: return Color.secondary
        }
    }

    private func learningStatusLabel(for pattern: BehavioralPattern) -> String {
        if !isPatternConvertibleToAutomation(pattern), pattern.confidence >= 0.45 {
            return String(localized: "habits.learning.statusInsightOnly",
                          defaultValue: "Pattern observed — insight only for now")
        }

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

    private func isPatternConvertibleToAutomation(_ pattern: BehavioralPattern) -> Bool {
        switch pattern.patternType {
        case .temporal, .lighting:
            return pattern.accessoryID != nil && isSupportedAutomationAction(pattern.action)

        case .scene:
            let sceneName = pattern.causeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !sceneName.isEmpty

        case .sequential, .contextual:
            return false
        }
    }

    private func isSupportedAutomationAction(_ action: BehavioralAction) -> Bool {
        switch action {
        case .on, .off, .dim, .activate, .lock, .unlock, .open, .close:
            return true
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

    private func reviewHabitPattern(_ pattern: HabitPattern) {
        scenesService.refresh()
        let capabilities = homeKit.currentHome.map {
            AutomationCapabilityCatalog.capabilities(in: $0)
        } ?? []
        reviewingOpportunity = nil
        reviewingHabitPattern = pattern
        reviewingProposal = AutomationProposalMapper.proposal(
            from: pattern,
            capabilities: capabilities,
            scenes: scenesService.scenes
        )
    }
}
