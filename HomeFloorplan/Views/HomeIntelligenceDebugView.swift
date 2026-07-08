import SwiftData
import SwiftUI

@MainActor
struct HomeIntelligenceDebugView: View {
    @Query(sort: \PersistedHomeInsight.updatedAt, order: .reverse) private var persistedHomeInsights: [PersistedHomeInsight]
    @Query(sort: \AccessoryEvent.timestamp, order: .reverse) private var accessoryEvents: [AccessoryEvent]
    @Query(sort: \SensorReading.timestamp, order: .reverse) private var sensorReadings: [SensorReading]
    @Query(sort: \DailySensorSummary.date, order: .reverse) private var dailySensorSummaries: [DailySensorSummary]
    @Query(sort: \AccessoryUsageSummary.weekStartDate, order: .reverse) private var accessoryUsageSummaries: [AccessoryUsageSummary]
    @Query private var sensorAlertThresholds: [SensorAlertThreshold]

    @Environment(ProactiveIntelligenceService.self) private var proactiveService
    @Environment(CloudKitSyncService.self) private var cloudKitSync
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: DebugTab = .insights
    @State private var schemaSeedResult: String?

    private enum DebugTab: String, CaseIterable, Identifiable {
        case insights = "Insights"
        case signals = "Signals"
        case baselines = "Baselines"
        case anomalies = "Anomalies"
        case coverage = "Coverage"
        case intervals = "Intervals"

        var id: String { rawValue }
    }

    private var insights: [HomeInsight] {
        persistedHomeInsights
            .map { $0.toHomeInsight() }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var signalSamples: [HomeSignalEvent] {
        let accessorySignals = accessoryEvents.prefix(40).flatMap { event -> [HomeSignalEvent] in
            var signals = [HomeSignalEventMapper.map(event)]
            if let brightness = HomeSignalEventMapper.mapBrightness(event) {
                signals.append(brightness)
            }
            return signals
        }
        let sensorSignals = sensorReadings.prefix(40).map(HomeSignalEventMapper.map)
        return Array((accessorySignals + sensorSignals).sorted { $0.timestamp > $1.timestamp }.prefix(60))
    }

    private var anomalySignals: [HomeSignalEvent] {
        sensorReadings.prefix(120).map(HomeSignalEventMapper.map)
    }

    private var stateIntervals: [HomeStateInterval] {
        HomeStateIntervalBuilder.build(from: accessoryEvents)
    }

    private var baselineSamples: [HomeBaseline] {
        HomeBaselineEngine.buildMergedBaselines(
            dailySensorSummaries: dailySensorSummaries,
            accessoryUsageSummaries: accessoryUsageSummaries,
            sensorReadings: sensorReadings,
            accessoryEvents: accessoryEvents
        )
    }

    private var anomalyInsights: [HomeInsight] {
        (anomalyEvaluations.compactMap(\.insight) + intervalAnomalyInsights)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var intervalAnomalyInsights: [HomeInsight] {
        HomeAnomalyDetector.detect(
            intervals: stateIntervals,
            baselines: baselineSamples
        )
    }

    private var anomalyEvaluations: [HomeAnomalyDetector.Evaluation] {
        HomeAnomalyDetector.evaluate(
            signals: anomalySignals,
            baselines: baselineSamples,
            thresholds: sensorAlertThresholds
        )
    }

    private var activeInsightCount: Int {
        insights.filter { $0.status == .active }.count
    }

    private var syncedInsightCount: Int {
        insights.filter { $0.syncPolicy != .localOnly }.count
    }

    /// Timing dell'ultimo runCycle (diagnosi M6): step ordinati per costo.
    @ViewBuilder
    private var cycleTimingsCard: some View {
        if !proactiveService.lastCycleTimings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Ultimo runCycle", systemImage: "stopwatch")
                        .font(.subheadline.weight(.bold))
                    Spacer()
                    Text("\(Int(proactiveService.lastCycleTotalMilliseconds.rounded())) ms")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(proactiveService.lastCycleTotalMilliseconds > 250 ? .red : .primary)
                }
                ForEach(proactiveService.lastCycleTimings.sorted { $0.milliseconds > $1.milliseconds }) { step in
                    HStack {
                        Text(step.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(step.milliseconds.rounded())) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(step.milliseconds > 100 ? .orange : .secondary)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        }
    }

    /// Seed per la creazione dello schema CloudKit in Development: la just-in-time
    /// schema registra SOLO i campi non-nil al primo save, e production non fa
    /// just-in-time — un record type nato monco e deployato farebbe fallire i save
    /// futuri (es. il primo snoozedUntil reale). Il seed valorizza tutti i campi.
    private var cloudKitSchemaSeedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Schema CloudKit — seed opportunità", systemImage: "icloud.and.arrow.up")
                .font(.subheadline.weight(.bold))
            Text("Crea un'AutomationOpportunity di prova con TUTTI i campi valorizzati (inclusa la coppia di condizioni P2 v2). Verifica in Console (Development) che il record type abbia tutti i campi di toCKRecord, deploya in Production, poi elimina il seed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Crea seed") { seedCloudKitSchemaOpportunity() }
                    .buttonStyle(.borderedProminent)
                Button("Elimina seed", role: .destructive) { deleteSchemaSeeds() }
                    .buttonStyle(.bordered)
            }
            if let schemaSeedResult {
                Text(schemaSeedResult)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
    }

    private static let schemaSeedTitle = "CloudKit schema seed"

    private func seedCloudKitSchemaOpportunity() {
        let conditions = [
            ContextualCondition(sensorTypeRaw: "temperature", direction: "above", threshold: 27.5),
            ContextualCondition(sensorTypeRaw: "lightSensor", direction: "below", threshold: 100, roomName: "Balcone")
        ]
        let seed = AutomationOpportunity(
            profileID: UUID(),
            createdAt: .now,
            lastUpdatedAt: .now,
            title: Self.schemaSeedTitle,
            naturalLanguage: "Record di prova per la creazione dello schema — eliminami dalla Console",
            roomName: "Studio",
            patternID: UUID(),
            confidence: 0.5,
            observations: 1,
            firstObservedAt: .now,
            lastObservedAt: .now,
            avgTimeString: "21:30",
            timeDeviationMinutes: 0,
            dayTypeLabel: "test",
            patternTypeRaw: BehavioralPatternType.contextual.rawValue,
            triggerType: "characteristic",
            triggerTime: "21:30",
            triggerWeekdaysRaw: "1,2,3,4,5,6,7",
            triggerSensorType: "temperature",
            triggerThreshold: 27.5,
            triggerDirection: "above",
            triggerConditionsRaw: ContextualCondition.signature(for: conditions),
            effectAccessoryIDString: UUID().uuidString,
            effectActionRaw: "on",
            effectValue: 50,
            effectValue2: 20,
            effectSceneName: "Scena Test",
            statusRaw: OpportunityStatus.dismissed.rawValue,  // mai visibile come card
            snoozedUntil: .now.addingTimeInterval(3600),
            dismissedAt: .now,
            approvedAt: .now,
            originRaw: OpportunityOrigin.conversational.rawValue
        )
        modelContext.insert(seed)
        do {
            try modelContext.save()
            cloudKitSync.syncAfterSave()
            schemaSeedResult = "In coda per il sync: opportunity:\(seed.id.uuidString)"
        } catch {
            schemaSeedResult = "Errore save: \(error.localizedDescription)"
        }
    }

    private func deleteSchemaSeeds() {
        let title = Self.schemaSeedTitle
        let seeds = (try? modelContext.fetch(FetchDescriptor<AutomationOpportunity>(
            predicate: #Predicate { $0.title == title }
        ))) ?? []
        for seed in seeds {
            cloudKitSync.markOpportunityDeleted(seed.id)
            modelContext.delete(seed)
        }
        try? modelContext.save()
        schemaSeedResult = seeds.isEmpty
            ? "Nessun seed da eliminare"
            : "Eliminati \(seeds.count) seed (anche dal record CloudKit)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                summaryGrid
                cycleTimingsCard
                cloudKitSchemaSeedCard
                Picker("Debug section", selection: $selectedTab) {
                    ForEach(DebugTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                switch selectedTab {
                case .insights:
                    insightList
                case .signals:
                    signalList
                case .baselines:
                    baselineList
                case .anomalies:
                    anomalyList
                case .coverage:
                    coverageList
                case .intervals:
                    intervalList
                }
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .background(BrandColor.subtleGradient.ignoresSafeArea())
        .navigationTitle("Intelligence Debug")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Home Intelligence Domain", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold))
            Text("Read-only projection of existing SwiftData records into HomeSignalEvent, HomeBaseline and HomeInsight.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            SummaryTile(title: "Insights", value: insights.count.formatted(), subtitle: "\(activeInsightCount) active")
            SummaryTile(title: "Signals", value: signalSamples.count.formatted(), subtitle: "latest mapped samples")
            SummaryTile(title: "Baselines", value: baselineSamples.count.formatted(), subtitle: "persisted + live preview")
            SummaryTile(title: "Anomalies", value: anomalyInsights.count.formatted(), subtitle: "baseline + intervals")
            SummaryTile(title: "Coverage", value: anomalyEvaluations.count.formatted(), subtitle: "evaluated signals")
            SummaryTile(title: "Intervals", value: stateIntervals.count.formatted(), subtitle: "state durations")
            SummaryTile(title: "Sync", value: syncedInsightCount.formatted(), subtitle: "non-local insights")
        }
    }

    @ViewBuilder
    private var insightList: some View {
        if insights.isEmpty {
            emptyState("No mapped insights", systemImage: "sparkles.rectangle.stack")
        } else {
            VStack(spacing: 12) {
                ForEach(insights.prefix(80)) { insight in
                    InsightDebugRow(insight: insight)
                }
            }
        }
    }

    @ViewBuilder
    private var signalList: some View {
        if signalSamples.isEmpty {
            emptyState("No mapped signals", systemImage: "waveform.path.ecg")
        } else {
            VStack(spacing: 12) {
                ForEach(signalSamples) { signal in
                    SignalDebugRow(signal: signal)
                }
            }
        }
    }

    @ViewBuilder
    private var baselineList: some View {
        if baselineSamples.isEmpty {
            emptyState("No mapped baselines", systemImage: "chart.xyaxis.line")
        } else {
            VStack(spacing: 12) {
                ForEach(baselineSamples) { baseline in
                    BaselineDebugRow(baseline: baseline)
                }
            }
        }
    }

    @ViewBuilder
    private var anomalyList: some View {
        if anomalyInsights.isEmpty {
            emptyState("No detected anomalies", systemImage: "exclamationmark.triangle")
        } else {
            VStack(spacing: 12) {
                ForEach(anomalyInsights) { insight in
                    InsightDebugRow(insight: insight)
                }
            }
        }
    }

    @ViewBuilder
    private var coverageList: some View {
        if anomalyEvaluations.isEmpty {
            emptyState("No anomaly coverage", systemImage: "list.bullet.clipboard")
        } else {
            VStack(spacing: 12) {
                ForEach(anomalyEvaluations) { evaluation in
                    AnomalyCoverageDebugRow(evaluation: evaluation)
                }
            }
        }
    }

    @ViewBuilder
    private var intervalList: some View {
        if stateIntervals.isEmpty {
            emptyState("No state intervals", systemImage: "timer")
        } else {
            VStack(spacing: 12) {
                ForEach(stateIntervals) { interval in
                    StateIntervalDebugRow(interval: interval)
                }
            }
        }
    }

    private func emptyState(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text("Run the app long enough to collect telemetry, summaries or generated insights.")
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

private struct SummaryTile: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InsightDebugRow: View {
    let insight: HomeInsight

    var body: some View {
        DebugCard(icon: icon, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(insight.title)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(insight.severity.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                }

                Text(insight.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DebugMetadata(items: [
                    "kind: \(insight.kind.rawValue)",
                    "category: \(insight.category.rawValue)",
                    "status: \(insight.status.rawValue)",
                    "sync: \(insight.syncPolicy.rawValue)",
                    "confidence: \(Self.percent(insight.confidence))",
                    "source: \(insight.sourceRecordType ?? "-")"
                ])

                Text("dedupe: \(insight.dedupeKey)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var icon: String {
        switch insight.category {
        case .environment, .weather: return "leaf.fill"
        case .security: return "shield.lefthalf.filled"
        case .habits: return "brain.head.profile"
        case .automation: return "wand.and.sparkles"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .deviceHealth: return "stethoscope"
        case .presence: return "person.fill.viewfinder"
        case .lighting: return "lightbulb.fill"
        case .system: return "gearshape"
        }
    }

    private var tint: Color {
        switch insight.severity {
        case .critical, .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .info: return .secondary
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct SignalDebugRow: View {
    let signal: HomeSignalEvent

    var body: some View {
        DebugCard(icon: "waveform.path.ecg", tint: .blue) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(signal.entityName)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(signal.value.displayValue)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }

                DebugMetadata(items: [
                    "type: \(signal.signalType.rawValue)",
                    "source: \(signal.sourceKind.rawValue)",
                    "entity: \(signal.entityKind.rawValue)",
                    "room: \(signal.roomName ?? "-")",
                    "raw: \(signal.rawSourceType)",
                    "time: \(signal.timestamp.formatted(date: .abbreviated, time: .shortened))"
                ])
            }
        }
    }
}

private struct BaselineDebugRow: View {
    let baseline: HomeBaseline

    var body: some View {
        DebugCard(icon: "chart.xyaxis.line", tint: .green) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(baseline.entityName ?? baseline.roomName ?? "Home baseline")
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(baseline.windowRaw)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.14), in: Capsule())
                        .foregroundStyle(.green)
                }

                DebugMetadata(items: [
                    "type: \(baseline.signalType.rawValue)",
                    "kind: \(baseline.baselineKind.rawValue)",
                    "samples: \(baseline.sampleCount)",
                    "mean: \(value(baseline.mean))",
                    "p90: \(value(baseline.p90))",
                    "p95: \(value(baseline.p95))",
                    "std: \(value(baseline.standardDeviation))",
                    "confidence: \(Int((baseline.confidence * 100).rounded()))%",
                    "context: \(baseline.contextKey ?? "-")"
                ])
            }
        }
    }

    private func value(_ value: Double?) -> String {
        guard let value else { return "-" }
        if baseline.baselineKind == .duration {
            return Self.duration(value)
        }
        return String(format: "%.2f", value)
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int(seconds.rounded()) / 60)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0, remainingMinutes > 0 {
            return "\(hours)h \(remainingMinutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

private struct AnomalyCoverageDebugRow: View {
    let evaluation: HomeAnomalyDetector.Evaluation

    var body: some View {
        DebugCard(icon: icon, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(evaluation.outcome.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                }

                Text(evaluation.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DebugMetadata(items: [
                    "value: \(Self.value(evaluation.value))",
                    "type: \(evaluation.signal.signalType.rawValue)",
                    "room: \(evaluation.signal.roomName ?? "-")",
                    "baseline: \(evaluation.baseline == nil ? "no" : "yes")",
                    "threshold: \(evaluation.threshold == nil ? "no" : "yes")",
                    "breach: \(evaluation.thresholdBreachDescription ?? "-")",
                    "delta: \(Self.value(evaluation.absoluteDelta))",
                    "minDelta: \(Self.value(evaluation.minimumDelta))",
                    "z: \(Self.value(evaluation.zScore))",
                    "p95: \(evaluation.p95Exceeded ? "yes" : "no")",
                    "relative: \(evaluation.allowsRelativeBaseline ? "yes" : "no")"
                ])
            }
        }
    }

    private var title: String {
        if let roomName = evaluation.signal.roomName, !roomName.isEmpty {
            return "\(roomName) \(evaluation.signal.entityName)"
        }
        return evaluation.signal.entityName
    }

    private var icon: String {
        evaluation.insight == nil ? "checklist.unchecked" : "exclamationmark.triangle.fill"
    }

    private var tint: Color {
        switch evaluation.outcome {
        case .emitted: return .orange
        case .missingBaseline: return .red
        case .smallDelta, .belowThreshold: return .blue
        case .relativeDisabled: return .secondary
        case .nonNumeric: return .gray
        }
    }

    private static func value(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }
}

private struct StateIntervalDebugRow: View {
    let interval: HomeStateInterval

    var body: some View {
        DebugCard(icon: icon, tint: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    Spacer(minLength: 12)
                    Text(statusLabel)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tint.opacity(0.14), in: Capsule())
                        .foregroundStyle(tint)
                }

                Text("\(interval.stateRaw) for \(duration)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                DebugMetadata(items: [
                    "type: \(interval.signalType.rawValue)",
                    "room: \(interval.roomName ?? "-")",
                    "started: \(interval.startedAt.formatted(date: .abbreviated, time: .shortened))",
                    "ended: \(interval.endedAt?.formatted(date: .abbreviated, time: .shortened) ?? "-")",
                    "duration: \(duration)",
                    "events: \(interval.sourceEventIDs.count)",
                    "confidence: \(Int((interval.confidence * 100).rounded()))%"
                ])
            }
        }
    }

    private var title: String {
        if let roomName = interval.roomName, !roomName.isEmpty {
            return "\(roomName) \(interval.entityName)"
        }
        return interval.entityName
    }

    private var icon: String {
        if interval.stateRaw == "heating" {
            return "thermometer"
        }

        switch interval.signalType {
        case .contact: return "door.left.hand.open"
        case .power: return "powerplug"
        case .active: return "switch.2"
        case .motion: return "figure.walk.motion"
        default: return "timer"
        }
    }

    private var tint: Color {
        interval.isActive ? .orange : .blue
    }

    private var statusLabel: String {
        guard interval.isActive else { return "closed" }
        return interval.stateRaw
    }

    private var duration: String {
        let seconds = max(0, interval.durationSeconds)
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

private struct DebugCard<Content: View>: View {
    let icon: String
    let tint: Color
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct DebugMetadata: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(in: proposal.width ?? 0, subviews: subviews)
        return CGSize(
            width: proposal.width ?? rows.map(\.width).max() ?? 0,
            height: rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        for row in rows(in: bounds.width, subviews: subviews) {
            var x = origin.x
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: origin.y),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            origin.y += row.height + spacing
        }
    }

    private func rows(in maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        guard maxWidth > 0 else {
            return [Row(items: subviews.map { RowItem(subview: $0, size: $0.sizeThatFits(.unspecified)) })]
        }

        var rows: [Row] = []
        var currentItems: [RowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let additionalWidth = currentItems.isEmpty ? size.width : size.width + spacing
            if currentWidth + additionalWidth > maxWidth, !currentItems.isEmpty {
                rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = []
                currentWidth = 0
                currentHeight = 0
            }

            currentItems.append(RowItem(subview: subview, size: size))
            currentWidth += currentItems.count == 1 ? size.width : size.width + spacing
            currentHeight = max(currentHeight, size.height)
        }

        if !currentItems.isEmpty {
            rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
        }

        return rows
    }

    private struct Row {
        var items: [RowItem]
        var width: CGFloat
        var height: CGFloat

        init(items: [RowItem], width: CGFloat? = nil, height: CGFloat? = nil) {
            self.items = items
            self.width = width ?? items.map(\.size.width).reduce(0, +)
            self.height = height ?? items.map(\.size.height).max() ?? 0
        }
    }

    private struct RowItem {
        var subview: LayoutSubview
        var size: CGSize
    }
}
