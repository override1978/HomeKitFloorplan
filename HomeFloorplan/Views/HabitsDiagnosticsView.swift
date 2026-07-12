import SwiftUI
import SwiftData

// MARK: - HabitsDiagnosticsView

/// Diagnostics view exposing the full internal state of the Habits pipeline,
/// including the demo-data seed/wipe used to verify the pipeline on test
/// devices. Accessible from Settings → Diagnostics (all builds).
///
/// Five sections:
///   1. Engine On-Device  — BehavioralAnalysisService patterns + opportunities
///   2. Engine AI Habits  — HabitAnalysisService patterns + guard status
///   3. Gate Rejections   — PatternDetectionEngine.lastGateLog (last detect() run)
///   4. Persistence       — UserDefaults key sizes + backup presence
///   5. Raw Events        — AccessoryEvent count over last 30 days
struct HabitsDiagnosticsView: View {

    @Environment(BehavioralAnalysisService.self) private var behavioralService
    @Environment(HabitAnalysisService.self)      private var habitService
    @Environment(CloudKitSyncService.self)       private var cloudKitSync
    @Environment(\.modelContext) private var modelContext

    @State private var rawEventCount: Int?
    @State private var eligibleEventCount: Int?
    @State private var firstEventDate: Date?
    @State private var lastEventDate: Date?
    @State private var daysWithEvents: Int?
    @State private var sensorReadingCounts: [String: Int]?
    @State private var showsTopPatterns          = false
    @State private var showsTopSequential        = false
    @State private var showsCoupledPairs         = false
    @State private var showsContextualCandidates = false
    @State private var isRunning = false
    @State private var demoStatus: String?

    var body: some View {
        List {
            engineOnDeviceSection
            engineAISection
            gateRejectionsSection
            contextualCandidatesSection
            correlationOutcomesSection
            burstSection
            coupledPairsSection
            persistenceSection
            rawEventsSection
            topPatternsSection
            demoDataSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Habits Diagnostics")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task {
                        isRunning = true
                        await behavioralService.analyze()
                        rawEventCount      = behavioralService.rawEventCount(days: 30)
                        eligibleEventCount = behavioralService.eligibleEventCount(days: 30)
                        firstEventDate     = behavioralService.firstEventDate()
                        lastEventDate      = behavioralService.lastEventDate()
                        daysWithEvents     = behavioralService.daysWithEvents(days: 30)
                        await loadSensorReadingCounts()
                        isRunning = false
                    }
                } label: {
                    if isRunning {
                        ProgressView().frame(width: 20, height: 20)
                    } else {
                        Label("Run Analysis", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRunning)
            }
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportText) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task {
            rawEventCount      = behavioralService.rawEventCount(days: 30)
            eligibleEventCount = behavioralService.eligibleEventCount(days: 30)
            firstEventDate     = behavioralService.firstEventDate()
            lastEventDate      = behavioralService.lastEventDate()
            daysWithEvents     = behavioralService.daysWithEvents(days: 30)
            await loadSensorReadingCounts()
        }
    }

    // MARK: - Demo data

    private var demoDataSection: some View {
        Section {
            // L'analisi programmata gira SOLO sul master (HomeFloorplanApp):
            // su uno slave i risultati locali vengono sovrascritti dalla sync
            // e le opportunity mostrate arrivano dal master. Il demo va provato
            // sul device master.
            HStack {
                Text("Questo device è il master")
                Spacer()
                if cloudKitSync.isMaster {
                    Text("Sì").foregroundStyle(.green)
                } else {
                    Text("NO — il demo va eseguito sul master")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Button {
                Task {
                    isRunning = true
                    do {
                        try HabitScenarioFactory.seedDemoHistory(into: modelContext)
                        // I pattern in-memory di seed precedenti sopravvivrebbero al
                        // merge dell'analisi (con statistiche congelate): via prima.
                        behavioralService.patterns.removeAll { pattern in
                            pattern.accessoryID.map(HabitScenarioFactory.DemoID.allAccessoryIDs.contains) == true
                        }
                        await behavioralService.analyze()
                        let contextual = behavioralService.patterns.filter { $0.patternType == .contextual }.count
                        demoStatus = "Seed ok · \(behavioralService.lastAnalyzedEventCount) eventi analizzati · \(behavioralService.patterns.count) pattern (\(contextual) contestuali) · \(behavioralService.pendingOpportunities.count) suggerimenti pendenti"
                    } catch {
                        demoStatus = "Seed FALLITO: \(error.localizedDescription)"
                    }
                    isRunning = false
                }
            } label: {
                Label("Inietta scenari demo (15 gg di storia)", systemImage: "wand.and.stars")
            }
            .disabled(isRunning)

            Button(role: .destructive) {
                Task {
                    isRunning = true
                    do {
                        try HabitScenarioFactory.wipeDemoData(from: modelContext)
                        behavioralService.patterns.removeAll { pattern in
                            pattern.accessoryID.map(HabitScenarioFactory.DemoID.allAccessoryIDs.contains) == true
                        }
                        await behavioralService.analyze()
                        demoStatus = "Wipe ok · restano \(behavioralService.patterns.count) pattern · \(behavioralService.pendingOpportunities.count) suggerimenti"
                    } catch {
                        demoStatus = "Wipe FALLITO: \(error.localizedDescription)"
                    }
                    isRunning = false
                }
            } label: {
                Label("Rimuovi dati demo e derivati", systemImage: "trash")
            }
            .disabled(isRunning)

            if let demoStatus {
                Text(demoStatus)
                    .font(.caption)
                    .foregroundStyle(demoStatus.contains("FALLITO") ? .red : .secondary)
            }
        } header: {
            Text("Demo Data")
        } footer: {
            Text("Storia sintetica (clima col caldo, riscaldamento col freddo, luci con poca luce, correlazione spuria umidità→luci, coppia P2v2, routine mattutina) per verificare la pipeline abitudini → automazioni in minuti invece che in settimane. Il wipe rimuove anche pattern e opportunity derivati, che sincronizzano via CloudKit.")
        }
    }

    // MARK: - Section 1: Engine On-Device

    @ViewBuilder
    private var engineOnDeviceSection: some View {
        Section {
            diagRow("Last analysis", value: behavioralService.lastAnalyzed
                .map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            diagRow("Is analyzing", value: behavioralService.isAnalyzing ? "Yes" : "No")
            // Event window stats
            let count = behavioralService.lastAnalyzedEventCount
            let from  = behavioralService.lastAnalyzedEventEarliestAt
                .map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "?"
            let to    = behavioralService.lastAnalyzedEventLatestAt
                .map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "?"
            diagRow("Events analyzed", value: count > 0 ? "\(count)  (\(from) → \(to))" : "—")
            if let earliest = behavioralService.lastAnalyzedEventEarliestAt,
               let latest   = behavioralService.lastAnalyzedEventLatestAt {
                let d = (Calendar.current.dateComponents([.day], from: earliest, to: latest).day ?? 0) + 1
                diagRow("Days covered", value: "\(max(1, d))")
            }
            let temporalCount   = behavioralService.patterns.filter { $0.patternType == .temporal || $0.patternType == .scene || $0.patternType == .lighting }.count
            let sequentialCount = behavioralService.patterns.filter { $0.patternType == .sequential }.count
            diagRow("Total patterns", value: "\(behavioralService.patterns.count)  (temporal \(temporalCount) · seq \(sequentialCount))")
            diagRow("  Emerging",        value: "\(behavioralService.patterns.filter { $0.tier == .emerging }.count)")
            diagRow("  Forming",         value: "\(behavioralService.patterns.filter { $0.tier == .forming }.count)")
            diagRow("  Stable",          value: "\(behavioralService.patterns.filter { $0.tier == .stable }.count)")
            diagRow("  High confidence", value: "\(behavioralService.patterns.filter { $0.tier == .highConfidence }.count)")
            diagRow("  Decaying",        value: "\(behavioralService.patterns.filter { $0.tier == .decaying }.count)")
            diagRow("  Dormant",         value: "\(behavioralService.patterns.filter { $0.tier == .dormant }.count)")
            diagRow("Opportunities (pending)",   value: "\(behavioralService.opportunities.filter { $0.status == .pending }.count)")
            diagRow("Opportunities (snoozed)",   value: "\(behavioralService.opportunities.filter { $0.status == .snoozed }.count)")
            diagRow("Opportunities (approved)",  value: "\(behavioralService.opportunities.filter { $0.status == .approved }.count)")
            diagRow("Opportunities (dismissed)", value: "\(behavioralService.opportunities.filter { $0.status == .dismissed }.count)")
        } header: {
            Text("Engine On-Device")
        }
    }

    // MARK: - Section 2: Engine AI Habits

    @ViewBuilder
    private var engineAISection: some View {
        let aiSettings = AISettings()
        Section {
            diagRow("Last analysis", value: habitService.lastAnalyzed
                .map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
            diagRow("Is analyzing",        value: habitService.isAnalyzing ? "Yes" : "No")
            diagRow("AI operational",      value: aiSettings.isOperational ? "✓ Yes" : "✗ No")
            diagRow("Suggestions enabled", value: aiSettings.suggestionsEnabled ? "✓ Yes" : "✗ No")
            diagRow("Guard passes",        value: (aiSettings.isOperational && aiSettings.suggestionsEnabled) ? "✓ Yes" : "✗ No — analysis skipped")
            diagRow("Cluster names cached", value: "\(habitService.clusterNames.count)")
            let burstCount = behavioralService.lastBurstReport.count
            let unnamedCount = behavioralService.lastBurstReport.filter { habitService.clusterNames[$0.signature] == nil }.count
            diagRow("Clusters named/total", value: burstCount == 0 ? "0/0" : "\(burstCount - unnamedCount)/\(burstCount)")
            diagRow("Patterns (pending)",   value: "\(habitService.patterns.filter { $0.status == .pending }.count)")
            diagRow("Patterns (approved)",  value: "\(habitService.patterns.filter { $0.status == .approved }.count)")
            diagRow("Patterns (dismissed)", value: "\(habitService.patterns.filter { $0.status == .dismissed }.count)")
            if let result = habitService.lastCallResult {
                HStack(alignment: .top) {
                    Text("Last call")
                        .font(.subheadline)
                    Spacer()
                    Text(result.displayString)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Engine AI Habits")
        }
    }

    // MARK: - Section 3: Gate Rejections

    @ViewBuilder
    private var gateRejectionsSection: some View {
        let log = PatternDetectionEngine.lastGateLog
        Section {
            if log.isEmpty {
                Text("No data — tap \"Run Analysis\" (top-left) to populate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(log) { rejection in
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rejection.reason.rawValue)
                                .font(.caption.weight(.medium))
                            if !rejection.detail.isEmpty {
                                Text(rejection.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(rejection.count)×")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(rejection.count > 10 ? .red : .orange)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Gate Rejections (last run)")
        } footer: {
            if !log.isEmpty {
                let total = log.reduce(0) { $0 + $1.count }
                Text("\(total) total rejections across \(log.count) gate(s)")
            }
        }
    }

    // MARK: - Section 3b: Contextual Candidates

    /// Formats a minute-of-day (0–1439) as "HH:mm".
    private static func minuteLabel(_ m: Int) -> String {
        String(format: "%02d:%02d", m / 60, m % 60)
    }

    @ViewBuilder
    private var contextualCandidatesSection: some View {
        let candidates = PatternDetectionEngine.lastContextualCandidates
        Section {
            if candidates.isEmpty {
                Text("No data — tap \"Run Analysis\" to populate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                DisclosureGroup(isExpanded: $showsContextualCandidates) {
                    ForEach(candidates) { c in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(c.accessoryName) · \(c.action)")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(c.occurrences)×")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(c.occurrences >= 10 ? .orange : .secondary)
                            }
                            HStack(spacing: 6) {
                                Text("σ=\(c.stdDevMinutes)m")
                                Text("·")
                                Text("\(c.distinctDays)d")
                                Text("·")
                                Text("\(Self.minuteLabel(c.minMinuteOfDay))–\(Self.minuteLabel(c.maxMinuteOfDay))")
                                if let room = c.roomName, !room.isEmpty {
                                    Text("·")
                                    Text(room)
                                        .lineLimit(1)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    HStack {
                        Text("Contextual Candidates (rejected by time gate)")
                            .font(.subheadline)
                        Spacer()
                        Text("\(candidates.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Contextual Candidates")
        } footer: {
            if !candidates.isEmpty {
                Text("Groups with time spread > 60 min — candidates for environmental correlation (temp, lux, humidity). Sorted by occurrences desc, top 20.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section 3b-bis: Correlation Outcomes

    @ViewBuilder
    private var correlationOutcomesSection: some View {
        let outcomes = behavioralService.lastContextualOutcomes
        Section {
            if outcomes.isEmpty {
                Text("No data — tap \"Run Analysis\" to populate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(outcomes.sorted(by: { $0.score > $1.score })) { o in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(o.candidateLabel) × \(o.sensorTypeRaw)")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(o.accepted ? "✓" : "✗")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(o.accepted ? .green : .secondary)
                        }
                        Text("hit=\(String(format: "%.2f", o.hitRate)) · base=\(String(format: "%.2f", o.baseRate)) · score=\(String(format: "%.2f", o.score))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Correlation Outcomes")
        } footer: {
            if !outcomes.isEmpty {
                Text("Why each candidate×sensor pair passed or failed the correlation gates (hitRate ≥ 0.70, baseRate ≤ 0.50, score ≥ 0.40). The verdict on whether contextual habits can emerge from this home's data lives here.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section 3c: Burst Clusters

    @ViewBuilder
    private var burstSection: some View {
        let clusters = behavioralService.lastBurstReport
        let absorbed = behavioralService.lastAbsorbedEventCount
        Section {
            if clusters.isEmpty && absorbed == 0 {
                Text("No data — tap \"Run Analysis\" to populate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                diagRow("Events absorbed by bursts", value: "\(absorbed)")
                diagRow("Distinct burst clusters",   value: "\(clusters.count)")
                ForEach(clusters.prefix(8)) { cluster in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(cluster.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("\(cluster.occurrenceCount)×")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(cluster.occurrenceCount >= 3 ? Color.accentColor : .secondary)
                        }
                        HStack(spacing: 6) {
                            Text("\(cluster.memberCount) core accessories")
                            if cluster.matchedSceneName != nil {
                                Text("· scene matched ✓")
                                    .foregroundStyle(.green)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Burst Clusters (last run)")
        } footer: {
            if absorbed > 0 {
                Text("\(absorbed) events grouped into \(clusters.count) cluster(s) via Jaccard similarity — excluded from individual pattern detection")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section 3c: Coupled Pairs

    @ViewBuilder
    private var coupledPairsSection: some View {
        let pairs = behavioralService.lastCoupledPairs
        Section {
            if pairs.isEmpty {
                Text("No coupled pairs detected — tap \"Run Analysis\" to populate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                DisclosureGroup(isExpanded: $showsCoupledPairs) {
                    ForEach(pairs) { pair in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(pair.deviceA) ↔ \(pair.deviceB)")
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f/d", pair.dailyFrequency))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.red)
                            }
                            HStack(spacing: 6) {
                                Text(pair.isBidirectional ? "Bidirectional" : "High-frequency")
                                Text("·")
                                Text("hours=\(pair.distinctHours)")
                                Text("·")
                                Text("days=\(pair.daysCoverage)/\(pair.totalEventDays)")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    HStack {
                        Text("Coupled pairs excluded from sequential")
                            .font(.subheadline)
                        Spacer()
                        Text("\(pairs.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Device Coupling (last run)")
        } footer: {
            if !pairs.isEmpty {
                Text("Coupling criteria: frequency ≥ 6/day (or bidirectional ≥ 3/day) AND hours ≥ 5 AND days ≥ 60% — excludes from sequential.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Section 4: Persistence

    @ViewBuilder
    private var persistenceSection: some View {
        // Use the actual profile-scoped keys from the service so the displayed size matches
        // what analyze() really writes (profile-scoped keys differ from the global fallback).
        let entries: [(key: String, label: String)] = [
            (behavioralService.currentPatternKey,    "Behavioral Patterns"),
            (behavioralService.currentOpportunityKey, "Behavioral Opportunities"),
            ("habitPatterns.persisted",              "AI Habit Patterns"),
        ]
        Section {
            ForEach(entries, id: \.key) { entry in
                let info = versionedStoreInfo(key: entry.key)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.label)
                        .font(.subheadline)
                    HStack(spacing: 8) {
                        Text(info.stored > 0 ? formatBytes(info.stored) : "empty")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(info.stored > 0 ? .primary : .secondary)
                        if info.backup > 0 {
                            Text("· backup: \(formatBytes(info.backup))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("· no backup")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Persistence")
        }
    }

    // MARK: - Section 5: Raw Events

    private static let eventDateFormat: Date.FormatStyle =
        .dateTime.day().month(.abbreviated).hour().minute()

    @ViewBuilder
    private var rawEventsSection: some View {
        Section {
            HStack {
                Text("AccessoryEvents (last 30 days)")
                    .font(.subheadline)
                Spacer()
                if let count = rawEventCount {
                    Text("\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(count == 0 ? .orange : .secondary)
                } else {
                    ProgressView().scaleEffect(0.8)
                }
            }
            HStack {
                Text("Habit-eligible events (last 30 days)")
                    .font(.subheadline)
                Spacer()
                if let count = eligibleEventCount {
                    Text("\(count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(count == 0 ? .orange : .secondary)
                } else {
                    ProgressView().scaleEffect(0.8)
                }
            }
            diagRow("First event",
                    value: firstEventDate.map { $0.formatted(Self.eventDateFormat) } ?? "—")
            diagRow("Last event",
                    value: lastEventDate.map  { $0.formatted(Self.eventDateFormat) } ?? "—")
            diagRow("Days with events (last 30d)",
                    value: daysWithEvents.map { "\($0)" } ?? "—")
            // SensorReadings per type — last 7 days
            HStack {
                Text("SensorReadings (last 7d)")
                    .font(.subheadline)
                Spacer()
                if let counts = sensorReadingCounts {
                    Text("\(counts.values.reduce(0, +))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().scaleEffect(0.8)
                }
            }
            if let counts = sensorReadingCounts {
                let shownTypes: [SensorServiceType] = [.temperature, .humidity, .carbonDioxide, .lightSensor, .outdoorTemperature, .outdoorHumidity]
                let homeLocConfigured = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey) != 0
                    || UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey) != 0
                ForEach(shownTypes) { type in
                    let n = counts[type.rawValue, default: 0]
                    if type == .outdoorTemperature || type == .outdoorHumidity {
                        if !homeLocConfigured {
                            diagRow("  \(type.displayName) (7d)", value: "⚠ location not set")
                        } else if n == 0 {
                            diagRow("  \(type.displayName) (7d)", value: "⏳ waiting for sample")
                        } else {
                            diagRow("  \(type.displayName) (7d)", value: Self.sensorCountLabel(n))
                        }
                    } else {
                        diagRow("  \(type.displayName) (7d)", value: Self.sensorCountLabel(n))
                    }
                }
            }
        } header: {
            Text("Raw Events")
        } footer: {
            if let raw = rawEventCount, let eligible = eligibleEventCount, raw > 0 {
                Text("light / blind / switch / thermostat / fan / airPurifier / outlet only (\(Int(Double(eligible) / Double(max(1, raw)) * 100))% of total)")
                    .foregroundStyle(.secondary)
            } else if let count = rawEventCount, count == 0 {
                Text("No events recorded — patterns cannot be detected without data.")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Section 6: Top Temporal Patterns

    @ViewBuilder
    private var topPatternsSection: some View {
        let temporal = behavioralService.patterns
            .filter { $0.patternType == .temporal || $0.patternType == .scene || $0.patternType == .lighting }
            .sorted { ($0.distinctActiveDays ?? 0) > ($1.distinctActiveDays ?? 0) }
            .prefix(15)
        let sequential = behavioralService.patterns
            .filter { $0.patternType == .sequential }
            .sorted { ($0.distinctActiveDays ?? 0) > ($1.distinctActiveDays ?? 0) }
            .prefix(10)

        Section {
            DisclosureGroup(isExpanded: $showsTopPatterns) {
                if temporal.isEmpty {
                    Text("No temporal patterns — run analysis first")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(Array(temporal)) { p in
                        let span = max(1, Calendar.current.dateComponents([.day], from: p.firstObservedAt, to: p.lastObservedAt).day ?? 0)
                        let clusterOcc: Int? = (p.patternType == .scene &&
                            (p.causeSignature?.hasPrefix("burst_cluster:") ?? false))
                            ? PatternDetectionEngine.lastBurstReport
                                .first(where: { $0.signature == p.causeSignature })?.occurrenceCount
                            : nil
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(p.accessoryName) · \(p.action.rawValue)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(p.confidenceLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text(p.dayType?.rawValue ?? "daily")
                                Text("·")
                                Text(p.avgTimeString)
                                Text("±\(p.timeDeviationMinutes)m")
                                Text("·")
                                if let d = p.distinctActiveDays {
                                    Text("active \(d)/\(p.expectedActiveDays)d")
                                }
                                Text("span \(span)d")
                                if let occ = clusterOcc {
                                    Text("·")
                                    Text("cluster: \(occ) occ")
                                        .foregroundStyle(.purple)
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } label: {
                HStack {
                    Text("Top 15 Temporal")
                        .font(.subheadline)
                    Spacer()
                    Text("(\(temporal.count) shown)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Top Patterns — Temporal")
        }

        Section {
            DisclosureGroup(isExpanded: $showsTopSequential) {
                if sequential.isEmpty {
                    Text("No sequential patterns")
                        .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                } else {
                    ForEach(Array(sequential)) { p in
                        let span = max(1, Calendar.current.dateComponents([.day], from: p.firstObservedAt, to: p.lastObservedAt).day ?? 0)
                        let gapMin = max(1, Int((p.avgGapSeconds ?? 60) / 60))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(p.causeName ?? "?") → \(p.accessoryName) \(p.action.rawValue)")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(p.confidenceLabel)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 4) {
                                Text("gap \(gapMin)m")
                                Text("·")
                                Text("\(p.observations) hits")
                                Text("·")
                                if let d = p.distinctActiveDays {
                                    Text("active \(d)/\(p.expectedActiveDays)d")
                                }
                                Text("span \(span)d")
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } label: {
                HStack {
                    Text("Top 10 Sequential")
                        .font(.subheadline)
                    Spacer()
                    Text("(\(sequential.count) shown)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Top Patterns — Sequential")
        }
    }

    // MARK: - Helpers

    /// Formats a 7-day reading count with daily average: "1680 (~240/d)" or "—".
    private static func sensorCountLabel(_ count: Int, windowDays: Int = 7) -> String {
        guard count > 0 else { return "—" }
        let perDay = count / max(1, windowDays)
        return "\(count) (~\(perDay)/d)"
    }

    @MainActor
    private func loadSensorReadingCounts() async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let readings = (try? modelContext.fetch(descriptor)) ?? []
        sensorReadingCounts = Dictionary(grouping: readings, by: \.serviceTypeRaw)
            .mapValues { $0.count }
    }

    private func diagRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes) B" }
        return String(format: "%.1f KB", Double(bytes) / 1_024.0)
    }

    // MARK: - Export (B2)

    private var exportText: String {
        let aiSettings = AISettings()
        let now = Date().formatted(date: .abbreviated, time: .complete)

        // Engine On-Device — event window
        let evtCount = behavioralService.lastAnalyzedEventCount
        let evtFrom  = behavioralService.lastAnalyzedEventEarliestAt
            .map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "?"
        let evtTo    = behavioralService.lastAnalyzedEventLatestAt
            .map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "?"
        let evtDays: String = {
            guard let e = behavioralService.lastAnalyzedEventEarliestAt,
                  let l = behavioralService.lastAnalyzedEventLatestAt else { return "—" }
            let d = (Calendar.current.dateComponents([.day], from: e, to: l).day ?? 0) + 1
            return "\(max(1, d))"
        }()
        let temporalCount   = behavioralService.patterns.filter { $0.patternType == .temporal || $0.patternType == .scene || $0.patternType == .lighting }.count
        let sequentialCount = behavioralService.patterns.filter { $0.patternType == .sequential }.count

        var lines: [String] = [
            "HomeFloorplan — Habits Diagnostics",
            "Generated: \(now)",
            "",
            "=== Engine On-Device ===",
            "Last analysis:      \(behavioralService.lastAnalyzed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")",
            "Events analyzed:    \(evtCount > 0 ? "\(evtCount)  (\(evtFrom) → \(evtTo))" : "—")",
            "Days covered:       \(evtDays)",
            "Total patterns:     \(behavioralService.patterns.count)  (temporal \(temporalCount) · seq \(sequentialCount))",
            "  Emerging:         \(behavioralService.patterns.filter { $0.tier == .emerging }.count)",
            "  Forming:          \(behavioralService.patterns.filter { $0.tier == .forming }.count)",
            "  Stable:           \(behavioralService.patterns.filter { $0.tier == .stable }.count)",
            "  High confidence:  \(behavioralService.patterns.filter { $0.tier == .highConfidence }.count)",
            "  Decaying:         \(behavioralService.patterns.filter { $0.tier == .decaying }.count)",
            "  Dormant:          \(behavioralService.patterns.filter { $0.tier == .dormant }.count)",
            "Opportunities:      pending=\(behavioralService.opportunities.filter { $0.status == .pending }.count)  snoozed=\(behavioralService.opportunities.filter { $0.status == .snoozed }.count)  approved=\(behavioralService.opportunities.filter { $0.status == .approved }.count)  dismissed=\(behavioralService.opportunities.filter { $0.status == .dismissed }.count)",
            "",
            "=== Engine AI Habits ===",
            "Last analysis:      \(habitService.lastAnalyzed.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")",
            "AI operational:     \(aiSettings.isOperational)",
            "Suggestions enabled:\(aiSettings.suggestionsEnabled)",
            "Guard passes:       \(aiSettings.isOperational && aiSettings.suggestionsEnabled)",
            "Last call:          \(habitService.lastCallResult?.displayString ?? "n/a")",
            "Cluster names:      cached=\(habitService.clusterNames.count)  unnamed=\(behavioralService.lastBurstReport.filter { habitService.clusterNames[$0.signature] == nil }.count)/\(behavioralService.lastBurstReport.count)",
            "Patterns:           pending=\(habitService.patterns.filter { $0.status == .pending }.count)  approved=\(habitService.patterns.filter { $0.status == .approved }.count)  dismissed=\(habitService.patterns.filter { $0.status == .dismissed }.count)",
            "",
            "=== Gate Rejections (last run) ===",
        ]

        let log = PatternDetectionEngine.lastGateLog
        if log.isEmpty {
            lines.append("No data recorded — run analysis first.")
        } else {
            for r in log {
                lines.append("\(r.reason.rawValue): \(r.count)×\(r.detail.isEmpty ? "" : "  (\(r.detail))")")
            }
        }

        lines += ["", "=== Contextual Candidates (rejected by time gate) ==="]
        let candidates = PatternDetectionEngine.lastContextualCandidates
        if candidates.isEmpty {
            lines.append("No data recorded — run analysis first.")
        } else {
            lines.append("Top \(candidates.count) by occurrences (σ > 60 min = time-scattered, environmental candidate):")
            for c in candidates {
                let room = c.roomName.map { "  room=\($0)" } ?? ""
                lines.append("  \(c.occurrences)×  \(c.accessoryName) [\(c.action)]  σ=\(c.stdDevMinutes)m  days=\(c.distinctDays)  \(HabitsDiagnosticsView.minuteLabel(c.minMinuteOfDay))–\(HabitsDiagnosticsView.minuteLabel(c.maxMinuteOfDay))\(room)")
            }
        }

        lines += ["", "=== Correlation Outcomes (last run) ==="]
        let outcomes = behavioralService.lastContextualOutcomes
        if outcomes.isEmpty {
            lines.append("No candidate×sensor pairs evaluated — run analysis first.")
        } else {
            lines.append("Every candidate×sensor pair the correlation engine evaluated (gates: hitRate ≥ 0.70, baseRate ≤ 0.50, score ≥ 0.40):")
            for o in outcomes.sorted(by: { $0.score > $1.score }) {
                let verdict = o.accepted ? "✓ ACCEPTED" : "✗ rejected"
                lines.append("  \(verdict)  \(o.candidateLabel) × \(o.sensorTypeRaw)  hit=\(String(format: "%.2f", o.hitRate))  base=\(String(format: "%.2f", o.baseRate))  score=\(String(format: "%.2f", o.score))")
            }
        }

        lines += ["", "=== Burst Clusters (last run) ==="]
        let bursts = behavioralService.lastBurstReport
        if bursts.isEmpty {
            lines.append("No data recorded — run analysis first.")
        } else {
            lines.append("Events absorbed:  \(behavioralService.lastAbsorbedEventCount)")
            lines.append("Distinct clusters: \(bursts.count)")
            for b in bursts {
                let matched = b.matchedSceneName != nil ? "  [scene matched]" : ""
                lines.append("  \(b.occurrenceCount)× \(b.label) (\(b.memberCount) core accessories)\(matched)")
            }
        }

        lines += ["", "=== Device Coupling (last run) ==="]
        let coupled = behavioralService.lastCoupledPairs
        if coupled.isEmpty {
            lines.append("No coupled pairs detected.")
        } else {
            for p in coupled {
                let bidir = p.isBidirectional ? "  [bidir]" : ""
                lines.append("  \(String(format: "%.1f", p.dailyFrequency))/d  hours=\(p.distinctHours)  days=\(p.daysCoverage)/\(p.totalEventDays)  \(p.deviceA) ↔ \(p.deviceB)\(bidir)")
            }
        }

        lines += ["", "=== Persistence ==="]
        for (key, label) in [
            (behavioralService.currentPatternKey,     "Behavioral Patterns"),
            (behavioralService.currentOpportunityKey, "Behavioral Opportunities"),
            ("habitPatterns.persisted",               "AI Habit Patterns"),
        ] {
            let info = versionedStoreInfo(key: key)
            lines.append("\(label): \(formatBytes(info.stored))  backup=\(info.backup > 0 ? formatBytes(info.backup) : "none")  [\(key)]")
        }

        let sensorTotal = sensorReadingCounts?.values.reduce(0, +) ?? 0
        let shownTypes: [SensorServiceType] = [.temperature, .humidity, .carbonDioxide, .lightSensor, .outdoorTemperature, .outdoorHumidity]
        lines += [
            "",
            "=== Raw Events ===",
            "AccessoryEvents (last 30d):     \(rawEventCount.map { "\($0)" } ?? "—")",
            "Habit-eligible (last 30d):      \(eligibleEventCount.map { "\($0)" } ?? "—")",
            "First event (all-time):         \(firstEventDate.map { $0.formatted(Self.eventDateFormat) } ?? "—")",
            "Last event (all-time):          \(lastEventDate.map  { $0.formatted(Self.eventDateFormat) } ?? "—")",
            "Days with events (last 30d):    \(daysWithEvents.map { "\($0)" } ?? "—")",
            "SensorReadings (last 7d):       \(sensorTotal)",
        ]
        if let counts = sensorReadingCounts {
            let homeLocConfigured = UserDefaults.standard.double(forKey: LocationPresenceService.homeLatKey) != 0
                || UserDefaults.standard.double(forKey: LocationPresenceService.homeLonKey) != 0
            for type in shownTypes {
                let n = counts[type.rawValue, default: 0]
                if type == .outdoorTemperature || type == .outdoorHumidity {
                    if !homeLocConfigured {
                        lines.append("  \(type.displayName):  ⚠ location not set")
                    } else if n == 0 {
                        lines.append("  \(type.displayName):  ⏳ waiting for sample")
                    } else {
                        lines.append("  \(type.displayName):  \(Self.sensorCountLabel(n))")
                    }
                } else {
                    lines.append("  \(type.displayName):  \(Self.sensorCountLabel(n))")
                }
            }
        }

        // Top 15 Temporal
        lines += ["", "=== Top 15 Temporal (by distinctActiveDays) ==="]
        let topTemporal = behavioralService.patterns
            .filter { $0.patternType == .temporal || $0.patternType == .scene || $0.patternType == .lighting }
            .sorted { ($0.distinctActiveDays ?? 0) > ($1.distinctActiveDays ?? 0) }
            .prefix(15)
        if topTemporal.isEmpty {
            lines.append("No temporal patterns — run analysis first.")
        } else {
            for p in topTemporal {
                let span = max(1, Calendar.current.dateComponents([.day], from: p.firstObservedAt, to: p.lastObservedAt).day ?? 0)
                let active = p.distinctActiveDays.map { "\($0)" } ?? "?"
                var line = "\(p.accessoryName) [\(p.action.rawValue)] \(p.dayType?.rawValue ?? "daily") \(p.avgTimeString)±\(p.timeDeviationMinutes)m  conf=\(p.confidenceLabel)  active=\(active)/\(p.expectedActiveDays)d  span=\(span)d"
                if p.patternType == .scene, let sig = p.causeSignature, sig.hasPrefix("burst_cluster:"),
                   let occ = PatternDetectionEngine.lastBurstReport.first(where: { $0.signature == sig })?.occurrenceCount {
                    line += "  cluster: \(occ) occ"
                }
                lines.append(line)
            }
        }

        // Top 10 Sequential
        lines += ["", "=== Top 10 Sequential (by distinctActiveDays) ==="]
        let topSequential = behavioralService.patterns
            .filter { $0.patternType == .sequential }
            .sorted { ($0.distinctActiveDays ?? 0) > ($1.distinctActiveDays ?? 0) }
            .prefix(10)
        if topSequential.isEmpty {
            lines.append("No sequential patterns.")
        } else {
            for p in topSequential {
                let span    = max(1, Calendar.current.dateComponents([.day], from: p.firstObservedAt, to: p.lastObservedAt).day ?? 0)
                let active  = p.distinctActiveDays.map { "\($0)" } ?? "?"
                let gapMin  = max(1, Int((p.avgGapSeconds ?? 60) / 60))
                lines.append("\(p.causeName ?? "?") → \(p.accessoryName) \(p.action.rawValue)  gap=\(gapMin)m  \(p.observations) hits  conf=\(p.confidenceLabel)  active=\(active)/\(p.expectedActiveDays)d  span=\(span)d")
            }
        }

        return lines.joined(separator: "\n")
    }
}
