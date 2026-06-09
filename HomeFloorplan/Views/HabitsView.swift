import SwiftUI
import HomeKit

// MARK: - HabitsView

/// Sezione "Abitudini" — mostra i pattern rilevati dall'AI e le regole attive.
/// Raggiungibile dalla sidebar con icona `brain.head.profile`.
struct HabitsView: View {

    @Environment(HabitAnalysisService.self) private var habitService
    @Environment(RuleEngineService.self) private var ruleEngine
    @Environment(HomeKitService.self) private var homeKit

    @State private var showAISettings = false

    var body: some View {
        NavigationStack {
            Group {
                if !isAIConfigured {
                    notConfiguredBanner
                } else {
                    content
                }
            }
            .navigationTitle(String(localized: "habits.title", defaultValue: "Habits"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showAISettings) {
                NavigationStack { AISettingsView() }
            }
            .task {
                // Analisi automatica all'apertura se non fatta di recente
                await habitService.analyzeHabits()
            }
        }
    }

    // MARK: - AI not configured

    private var isAIConfigured: Bool {
        let settings = AISettings()
        return settings.isOperational && settings.suggestionsEnabled
    }

    private var notConfiguredBanner: some View {
        VStack(spacing: 24) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text(String(localized: "habits.noAI.title",
                            defaultValue: "Set up AI to get started"))
                    .font(.title3.weight(.semibold))

                Text(String(localized: "habits.noAI.subtitle",
                            defaultValue: "Enable AI and habit suggestions in Settings to detect your usage patterns."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Button {
                showAISettings = true
            } label: {
                Label(String(localized: "habits.noAI.action",
                             defaultValue: "Go to AI Settings"),
                      systemImage: "gearshape")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Main content

    @ViewBuilder
    private var content: some View {
        List {
            // Sezione analisi in corso
            if habitService.isAnalyzing {
                Section {
                    HStack(spacing: 12) {
                        ProgressView().scaleEffect(0.85)
                        Text(String(localized: "habits.analyzing",
                                    defaultValue: "Analyzing habits…"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }

            // Pattern in attesa
            let pending = habitService.pendingPatterns
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { pattern in
                        patternRow(pattern)
                    }
                } header: {
                    Text(String(localized: "habits.patterns.header",
                                defaultValue: "Detected Patterns"))
                } footer: {
                    Text(String(localized: "habits.patterns.footer",
                                defaultValue: "Based on the last 14 days of activity. Approve a pattern to create an automatic rule."))
                }
            } else if !habitService.isAnalyzing {
                Section {
                    emptyPatternsView
                }
            }

            // Regole attive
            if !ruleEngine.rules.isEmpty {
                Section {
                    ActiveRulesView()
                } header: {
                    Text(String(localized: "habits.rules.header",
                                defaultValue: "Active Rules"))
                } footer: {
                    Text(String(localized: "habits.rules.footer",
                                defaultValue: "Tap a rule to edit its parameters."))
                }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Empty patterns

    private var emptyPatternsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(String(localized: "habits.empty.title",
                        defaultValue: "The app is learning your habits"))
                .font(.subheadline.weight(.medium))
            Text(String(localized: "habits.empty.subtitle",
                        defaultValue: "Check back in a few days. At least 7 days of data are needed to detect reliable patterns."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    // MARK: - Pattern row

    @ViewBuilder
    private func patternRow(_ pattern: HabitPattern) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                // Icona
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: pattern.sfSymbol)
                        .font(.system(size: 17))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(pattern.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(pattern.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Badge confidenza
                Text(pattern.confidenceLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(confidenceColor(pattern.confidence), in: Capsule())
            }

            // Azioni
            HStack(spacing: 12) {
                Button {
                    approvePattern(pattern)
                } label: {
                    Text(String(localized: "habits.pattern.approve",
                                defaultValue: "Create Automatic Rule"))
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    habitService.dismiss(pattern)
                } label: {
                    Text(String(localized: "habits.pattern.dismiss", defaultValue: "Dismiss"))
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task { await habitService.analyzeHabits() }
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

    private func approvePattern(_ pattern: HabitPattern) {
        habitService.approve(pattern)
        Task {
            if let home = homeKit.currentHome {
                try? await ruleEngine.createRule(from: pattern, home: home)
            }
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        switch confidence {
        case 0.9...1.0: return .green
        case 0.75..<0.9: return .orange
        default: return .gray
        }
    }
}
