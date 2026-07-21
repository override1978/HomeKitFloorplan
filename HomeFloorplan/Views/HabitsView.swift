import SwiftUI
import SwiftData
import HomeKit

// MARK: - HabitsView

/// Dashboard Abitudini post-pivot (motore statistico ritirato):
/// 1. Routine osservate — evidenze d'uso deterministiche + funnel diagnostico
/// 2. AI-interpreted   — interprete LLM on-demand (gap analysis)
/// 3. Monitoraggio     — metriche raccolta dati + footer
struct HabitsView: View {

    @Environment(HabitAnalysisService.self)      private var habitService
    @Environment(BehavioralAnalysisService.self) private var behavioralService
    @Environment(HomeKitService.self)            private var homeKit
    @Environment(HomeKitScenesService.self)      private var scenesService
    @Environment(HomeKitAutomationsService.self) private var automationsService

    @State private var showAISettings       = false
    @Environment(\.modelContext) private var modelContext
    /// Evidenze d'uso (pivot): calcolate al task iniziale della view.
    @State private var usageEvidences: [UsageEvidenceBuilder.Evidence] = []
    /// Funnel diagnostico: rende spiegabile una lista vuota.
    @State private var evidenceFunnel: UsageEvidenceBuilder.FunnelReport?
    /// Livello B: interprete LLM su richiesta.
    @State private var habitInterpreter: HabitInterpreterService?
    @State private var showInterpreterSummary = false
    @State private var reviewingProposal: AutomationProposal?
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
                .sheet(item: $reviewingProposal) { proposal in
                    AutomationWizardSheet(proposal: proposal) { _ in
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
                    let report = UsageEvidenceService.evidencesWithReport(modelContainer: modelContext.container)
                    usageEvidences = report.evidences
                    evidenceFunnel = report.funnel
                    if habitInterpreter == nil {
                        habitInterpreter = HabitInterpreterService(
                            aiSettings: AISettings(),
                            modelContainer: modelContext.container,
                            homeKit: homeKit
                        )
                    }
                    eligibleEvents = behavioralService.eligibleEventCount(days: 30)
                }
        }
    }

    // MARK: - Computed helpers

    private var isAIConfigured: Bool {
        let settings = AISettings()
        return settings.isOperational && settings.suggestionsEnabled
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        List {
            learningSection
            aiInterpreterSection
            monitoringSection
            footerSection
        }
        .listStyle(.insetGrouped)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Routine osservate (evidenze)

    @ViewBuilder
    /// Pivot "da giudice a testimone": al posto del limbo "Sto Imparando"
    /// (pattern statistici mai promossi), evidenze d'uso osservate — l'utente
    /// giudica e con un tap apre il wizard pre-compilato.
    private var learningSection: some View {
        Section {
            if usageEvidences.isEmpty {
                learningMicroState
            } else {
                ForEach(usageEvidences.prefix(6)) { evidence in
                    evidenceRow(evidence)
                }
            }
        } header: {
            Label(
                String(format: String(localized: "habits.evidence.sectionTitle",
                                      defaultValue: "Observed routines · %d"),
                       usageEvidences.count),
                systemImage: "chart.bar.doc.horizontal"
            )
        } footer: {
            if !usageEvidences.isEmpty {
                Text(String(localized: "habits.evidence.footer",
                            defaultValue: "Recurring usage observed in your home. You decide which ones become automations."))
            }
        }
    }

    private func evidenceRow(_ evidence: UsageEvidenceBuilder.Evidence) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(evidence.roomName.map { "\(evidence.accessoryName) · \($0)" } ?? evidence.accessoryName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(evidenceWindowText(evidence)) · \(evidenceDaysText(evidence))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: String(localized: "habits.evidence.strength",
                                           defaultValue: "%d different days out of the last %d"),
                            evidence.distinctDays, evidence.observedSpanDays))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                reviewingProposal = AutomationProposalMapper.proposal(
                    from: evidence,
                    capabilities: homeKit.currentHome.map { AutomationCapabilityCatalog.descriptors(in: $0) } ?? [],
                    scenes: scenesService.scenes
                )
            } label: {
                Label(String(localized: "habits.evidence.create", defaultValue: "Create"),
                      systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func evidenceWindowText(_ evidence: UsageEvidenceBuilder.Evidence) -> String {
        String(format: "%02d:%02d–%02d:%02d",
               evidence.windowStartMinute / 60, evidence.windowStartMinute % 60,
               evidence.windowEndMinute / 60, evidence.windowEndMinute % 60)
    }

    private func evidenceDaysText(_ evidence: UsageEvidenceBuilder.Evidence) -> String {
        switch evidence.weekdayPattern {
        case .everyDay: return String(localized: "habits.evidence.everyDay", defaultValue: "every day")
        case .weekdays: return String(localized: "habits.evidence.weekdays", defaultValue: "weekdays")
        case .weekend:  return String(localized: "habits.evidence.weekend", defaultValue: "weekend")
        case .days:     return String(localized: "habits.evidence.someDays", defaultValue: "specific days")
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
                if let funnel = evidenceFunnel, funnel.totalEvents > 0 {
                    // Funnel diagnostico: lo zero non è mai opaco.
                    Text(evidenceFunnelText(funnel))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func evidenceFunnelText(_ funnel: UsageEvidenceBuilder.FunnelReport) -> String {
        var text = String(format: String(localized: "habits.evidence.funnel",
                                         defaultValue: "%d events · %d actionable · %d after scene filter"),
                          funnel.totalEvents, funnel.actionableOnEvents, funnel.afterBulkFilter)
        if let name = funnel.bestCandidateName {
            text += " · " + String(format: String(localized: "habits.evidence.funnel.best",
                                                  defaultValue: "best: %@ (%d days)"),
                                   name, funnel.bestCandidateDays)
        }
        if !funnel.onEventsByType.isEmpty {
            // Breakdown per tipo: l'ASSENZA di un tipo (es. "blind") qui
            // significa che quegli accessori non generano proprio eventi.
            let types = funnel.onEventsByType
                .sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
            text += "\n" + types
        }
        return text
    }

    // MARK: - Sezione interprete LLM (livello B del pivot)

    @ViewBuilder
    private var aiInterpreterSection: some View {
        if let interpreter = habitInterpreter, interpreter.isAvailable {
            Section {
                ForEach(interpreter.suggestions) { suggestion in
                    aiSuggestionRow(suggestion, interpreter: interpreter)
                }

                if interpreter.isAnalyzing {
                    HStack(spacing: 10) {
                        ProgressView().scaleEffect(0.8)
                        Text(String(localized: "habits.ai.analyzing",
                                    defaultValue: "Reading your home's usage…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await interpreter.interpret() }
                    } label: {
                        Label(
                            interpreter.lastRunAt == nil
                                ? String(localized: "habits.ai.interpret", defaultValue: "Interpret with AI")
                                : String(localized: "habits.ai.interpretAgain", defaultValue: "Interpret again"),
                            systemImage: "sparkles"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                }

                if interpreter.lastSummary != nil, !interpreter.isAnalyzing {
                    // Trasparenza totale: cosa ha visto ESATTAMENTE il modello.
                    Button {
                        showInterpreterSummary = true
                    } label: {
                        Label(String(localized: "habits.ai.showSummary",
                                     defaultValue: "What did the model see?"),
                              systemImage: "doc.text.magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .sheet(isPresented: $showInterpreterSummary) {
                        NavigationStack {
                            ScrollView {
                                Text(interpreter.lastSummary ?? "")
                                    .font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                                    .textSelection(.enabled)
                            }
                            .navigationTitle(String(localized: "habits.ai.summaryTitle",
                                                    defaultValue: "Model input"))
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .presentationDetents([.large])
                    }
                }

                if let error = interpreter.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if interpreter.lastRunAt != nil,
                          interpreter.suggestions.isEmpty,
                          !interpreter.isAnalyzing {
                    Text(String(localized: "habits.ai.noFindings",
                                defaultValue: "No routine with clear evidence right now — better an empty list than an invented one."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label(String(localized: "habits.ai.sectionTitle", defaultValue: "AI-interpreted routines"),
                      systemImage: "sparkles")
            } footer: {
                Text(String(localized: "habits.ai.footer",
                            defaultValue: "The model reads usage summaries (histograms and sequences) and proposes only what has recurring evidence. You always confirm in the wizard."))
            }
        }
    }

    private func aiSuggestionRow(_ suggestion: HabitInterpreterCore.RoutineSuggestion,
                                 interpreter: HabitInterpreterService) -> some View {
        // Il check giusto è sul CATALOGO capabilities (dove il mapper risolve
        // l'azione), non su allAccessories: TV/camere possono esistere in casa
        // ma non essere target automatizzabili.
        let capabilities = homeKit.currentHome.map { AutomationCapabilityCatalog.descriptors(in: $0) } ?? []
        let normalized = suggestion.targetAccessoryName.lowercased()
        let inCatalog = capabilities.contains {
            let name = $0.accessoryName.lowercased()
            return name == normalized || name.contains(normalized) || normalized.contains(name)
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.semibold))
                Text(suggestion.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !inCatalog {
                    Text(String(format: String(localized: "habits.ai.unresolved",
                                               defaultValue: "\"%@\" is not automatable — add the action manually in the wizard"),
                                suggestion.targetAccessoryName))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button {
                reviewingProposal = AutomationProposalMapper.proposal(
                    from: suggestion,
                    targetAccessoryID: interpreter.resolveAccessoryID(named: suggestion.targetAccessoryName),
                    capabilities: capabilities,
                    scenes: scenesService.scenes
                )
            } label: {
                Label(String(localized: "habits.evidence.create", defaultValue: "Create"),
                      systemImage: "plus.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                interpreter.dismiss(suggestion)
            } label: {
                Label(String(localized: "common.hide", defaultValue: "Hide"), systemImage: "eye.slash")
            }
        }
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
                Task {
                    let report = UsageEvidenceService.evidencesWithReport(modelContainer: modelContext.container)
                    usageEvidences = report.evidences
                    evidenceFunnel = report.funnel
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    // MARK: - Actions

}
