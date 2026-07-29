import Foundation
import SwiftData
import Observation

// MARK: - Retention constants
// Stored in a caseless enum so they are never inferred as @MainActor-isolated.
private enum DLCRetention {
    nonisolated static let sensorRaw        = 30
    nonisolated static let accessoryRaw     = 30
    nonisolated static let effectivenessRaw = 90
    nonisolated static let alertResolved    = 30
    nonisolated static let alertOrphan      = 90
    nonisolated static let insight          = 30
}

// MARK: - DataLifecycleService

/// Centralized Home Knowledge Retention & Data Lifecycle Engine.
///
/// Architectural principle: **Raw data is temporary. Knowledge is permanent.**
///
/// Responsibilities (in execution order):
///   1. Aggregate raw sensor readings   → DailySensorSummary   (permanent)
///   2. Aggregate raw accessory events  → AccessoryUsageSummary (permanent)
///   3. Aggregate effectiveness events  → EffectivenessSummary  (permanent)
///   4. Prune expired insight records (>30 days)
///   5. Prune resolved/stale SensorAlertEvents
///   6. Prune raw ActionEffectivenessEvents (>90 days, after aggregation)
///
/// Aggregation always runs BEFORE pruning to ensure no knowledge is lost.
/// All SwiftData I/O is dispatched to a background task via `Task.detached`
/// so the main actor is never blocked. Called exclusively from the
/// `com.homefloorplan.dataLifecycle` BGProcessingTask.
///
/// Does NOT modify: AI algorithms, Rule Engine, Habit Analysis, Action Resolver,
/// Outcome Measurement logic, or any @Model schema beyond lifecycle records.
@Observable
@MainActor
final class DataLifecycleService {

    // MARK: - State

    /// True while a cycle is in progress (prevents concurrent runs).
    var isRunning: Bool = false

    /// Date the last successful full cycle completed.
    var lastCycleDate: Date? {
        UserDefaults.standard.object(forKey: Self.lastCycleDateKey) as? Date
    }

    // MARK: - Constants

    private static let lastCycleDateKey = "dataLifecycle.lastCycleDate"

    // MARK: - Private

    private let modelContainer: ModelContainer

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Diagnostica salute dati

    /// Scrive nel log diagnostico esportabile lo stato dello strato aggregati.
    ///
    /// Serve a rispondere da remoto — su un pannello a muro in TestFlight, dove
    /// non si può attaccare Xcode senza spostare il device sull'ambiente CloudKit
    /// di sviluppo — a una domanda sola: **il ciclo giornaliero è mai girato qui?**
    ///
    /// Va in `SyncDiagnosticsLogger` e non dietro `#if DEBUG` di proposito: è
    /// l'unico canale leggibile in produzione, esportabile da Impostazioni →
    /// iCloud. Costa quattro fetchCount all'avvio.
    ///
    /// `events` è il conteggio degli `AccessoryEvent` grezzi, e mancava. È
    /// l'unico ingresso da cui dipende tutta la pila delle Abitudini
    /// (`UsageEvidenceService` legge solo quelli), quindi senza quel numero non
    /// si distingue "le evidenze d'uso non trovano nulla" da "non c'è nulla da
    /// cui trovarlo" — che è la stessa ambiguità che ha fatto costruire per
    /// intero tre motori abitudini prima di scoprire che giravano a vuoto.
    /// `usageSummaries` non basta a scioglierla: l'aggregazione chiude solo le
    /// settimane ISO complete, quindi resta ferma per giorni anche quando gli
    /// eventi arrivano.
    nonisolated static func logDataHealth(modelContainer: ModelContainer, isMaster: Bool) {
        let ctx = ModelContext(modelContainer)
        let readings  = (try? ctx.fetchCount(FetchDescriptor<SensorReading>())) ?? -1
        let summaries = (try? ctx.fetchCount(FetchDescriptor<DailySensorSummary>())) ?? -1
        let usage     = (try? ctx.fetchCount(FetchDescriptor<AccessoryUsageSummary>())) ?? -1
        let events    = (try? ctx.fetchCount(FetchDescriptor<AccessoryEvent>())) ?? -1
        let lastCycle = UserDefaults.standard.object(forKey: lastCycleDateKey) as? Date

        SyncDiagnosticsLogger.log(
            "Data health: lastLifecycleCycle=\(lastCycle.map { ISO8601DateFormatter().string(from: $0) } ?? "NEVER") "
            + "readings=\(readings) events=\(events) dailySummaries=\(summaries) usageSummaries=\(usage) isMaster=\(isMaster)"
        )
    }

    // MARK: - Full Cycle

    /// Runs the complete lifecycle cycle: aggregate raw telemetry into permanent knowledge,
    /// then prune expired raw records. Safe to call multiple times — deduplication guards
    /// prevent double-aggregation.
    ///
    /// Order: aggregate first, prune last. This guarantees knowledge is preserved before
    /// any raw data is removed.
    func runFullCycle() async {
        guard !isRunning else {
            dprint("🗂 DataLifecycle: skipped (already running)")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let container = modelContainer
        let start = Date()

        // One-way, idempotent migration from legacy environmental insight records
        // to the unified home insight store. Runs outside pruning because it never deletes.
        Self.backfillPersistedHomeInsights(context: modelContainer.mainContext)
        try? modelContainer.mainContext.save()

        await Task.detached(priority: .background) {
            let ctx = ModelContext(container)

            // ── Phase 1: Aggregate (preserve knowledge) ───────────────────────
            Self.aggregateSensorReadings(context: ctx)
            Self.aggregateAccessoryEvents(context: ctx)
            Self.aggregateEffectivenessEvents(context: ctx)

            // ── Phase 2: Prune (remove expired raw data) ──────────────────────
            // Local data preservation is the default. Cloud data can be rebuilt from
            // the device, but local SwiftData records must not be removed silently.
            if !LocalDataProtection.shouldPreserveSwiftData {
                Self.prunePersistedInsights(context: ctx)
                Self.prunePersistedHomeInsights(context: ctx)
                Self.pruneSensorAlertEvents(context: ctx)
                Self.pruneActionEffectivenessEvents(context: ctx)
                Self.pruneRoomAnalysisStates(context: ctx)

                // Il grezzo per ultimo: le Fasi 1 l'hanno appena distillato in
                // summary permanenti, quindi ora è ridondante. L'ordine conta —
                // potare prima di aggregare butterebbe conoscenza.
                Self.pruneRawTelemetry(context: ctx)
            }

            // ── Phase 3: Persist all changes ──────────────────────────────────
            try? ctx.save()
        }.value

        // Le ricorrenze ambientali derivano dai DailySensorSummary appena
        // prodotti: stanno nello stesso ciclo, non fuori. Erano invocate solo
        // dal BGProcessingTask, quindi con quel task mai concesso non sono mai
        // state calcolate — ed è il motivo per cui la prova a vuoto sulle
        // automazioni ambientali trovava zero ricorrenze.
        await EnvironmentalPatternAnalyzer.analyze(modelContainer: container)

        UserDefaults.standard.set(Date(), forKey: Self.lastCycleDateKey)
        dprint("🗂 DataLifecycle: cycle complete in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
    }

    // MARK: - Phase 1a: Sensor Aggregation

    private nonisolated static func aggregateSensorReadings(context: ModelContext) {
        let cal = Calendar.current
        // Aggregate all completed days (before today midnight). Today's data stays raw.
        let aggregationCutoff = cal.startOfDay(for: Date())

        let rawDescriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate<SensorReading> { $0.timestamp < aggregationCutoff }
        )
        let readings = (try? context.fetch(rawDescriptor)) ?? []
        guard !readings.isEmpty else { return }

        // Load existing summaries to prevent duplicates (bounded by raw retention window).
        let existingCutoff = Date().addingTimeInterval(-Double(DLCRetention.sensorRaw + 2) * 86400)
        let existingDesc = FetchDescriptor<DailySensorSummary>(
            predicate: #Predicate<DailySensorSummary> { $0.date > existingCutoff }
        )
        let existing = (try? context.fetch(existingDesc)) ?? []
        let existingKeys = Set(existing.map {
            "\($0.roomName)|\($0.serviceTypeRaw)|\(cal.startOfDay(for: $0.date).timeIntervalSince1970)"
        })

        // Group by (startOfDay, roomName, serviceTypeRaw).
        var groups: [String: [SensorReading]] = [:]
        for r in readings {
            let day = cal.startOfDay(for: r.timestamp)
            let key = "\(r.roomName)|\(r.serviceTypeRaw)|\(day.timeIntervalSince1970)"
            groups[key, default: []].append(r)
        }

        var inserted = 0
        for (key, rds) in groups {
            guard !existingKeys.contains(key), let first = rds.first else { continue }
            let day    = cal.startOfDay(for: first.timestamp)
            let values = rds.map(\.value)
            let (avg, stdDev) = Self.timeWeightedStats(rds, dayStart: day, calendar: cal)
            let mn     = values.min() ?? avg
            let mx     = values.max() ?? avg
            let peak = rds.max { $0.value < $1.value }

            context.insert(DailySensorSummary(
                date: day,
                roomName: first.roomName,
                serviceTypeRaw: first.serviceTypeRaw,
                sampleCount: values.count,
                average: avg,
                minimum: mn,
                maximum: mx,
                standardDeviation: stdDev,
                peakValue: peak?.value ?? mx,
                peakAt: peak?.timestamp ?? day,
                isOutlierDay: values.count < 8
            ))
            inserted += 1
        }
        #if DEBUG
        if inserted > 0 { print("🗂  → \(inserted) DailySensorSummary created") }
        #endif
    }

    /// Media e deviazione standard giornaliere, pesate sul tempo.
    ///
    /// Erano una media semplice sui campioni, e funzionava finché i campioni
    /// erano equispaziati. Da quando `SensorSampleGate` non archivia più le
    /// letture ripetute non lo sono più: un'ora di valore fermo lascia una riga,
    /// un'ora movimentata ne lascia quattro. La media semplice avrebbe quindi
    /// dato quattro volte più peso alle ore agitate — e siccome queste medie
    /// diventano le baseline con cui si giudicano le anomalie, l'errore non
    /// sarebbe rimasto confinato alla statistica.
    ///
    /// Pesando ogni lettura per quanto è rimasta valida, il risultato descrive
    /// la giornata invece del nostro criterio di scrittura: gli aggregati
    /// vecchi e quelli nuovi restano confrontabili, e cambiare di nuovo le
    /// soglie in futuro non li sposterà.
    ///
    /// Il peso si calcola **dentro ogni sensore**, non sul gruppo mescolato, e
    /// non è un dettaglio: un gruppo è una coppia (stanza, tipo), quindi due
    /// termometri nella stessa stanza finiscono nello stesso gruppo con letture
    /// separate da frazioni di secondo. Misurando la distanza dalla riga
    /// successiva senza distinguere il sensore, il primo dei due avrebbe pesato
    /// pochi decimi di secondo e il secondo si sarebbe preso l'intero
    /// intervallo: una stanza con due sensori ne avrebbe di fatto ignorato uno.
    ///
    /// I pesi restano però in secondi, senza normalizzare per sensore: due
    /// sensori che campionano allo stesso ritmo si equivalgono da soli, mentre
    /// uno che ha risposto solo per mezz'ora pesa per quella mezz'ora e non
    /// quanto uno che ha coperto l'intera giornata.
    ///
    /// Internal e non private: è l'unico calcolo di questo file che produce
    /// numeri di cui ci si fida a valle, e vale la pena poterlo provare da solo.
    nonisolated static func timeWeightedStats(
        _ readings: [SensorReading],
        dayStart: Date,
        calendar: Calendar
    ) -> (average: Double, standardDeviation: Double) {
        guard !readings.isEmpty else { return (0, 0) }

        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart

        // (valore, secondi per cui quel valore è rimasto valido).
        var weighted: [(value: Double, weight: Double)] = []
        weighted.reserveCapacity(readings.count)

        for (_, perSensor) in Dictionary(grouping: readings, by: \.accessoryUUID) {
            let sorted = perSensor.sorted { $0.timestamp < $1.timestamp }
            guard let last = sorted.last else { continue }

            // L'ultima lettura vale fino a fine giornata, ma non oltre un
            // battito: se il sensore ha smesso di rispondere a mezzogiorno,
            // quel valore non può reclamare le dodici ore successive.
            let tail = min(max(dayEnd.timeIntervalSince(last.timestamp), 0), SensorSampleGate.maxGap)

            var spans: [Double] = []
            spans.reserveCapacity(sorted.count)
            for (i, r) in sorted.enumerated() {
                let span = i < sorted.count - 1
                    ? sorted[i + 1].timestamp.timeIntervalSince(r.timestamp)
                    : tail
                spans.append(max(span, 0))
            }

            if spans.reduce(0, +) > 0 {
                for (i, r) in sorted.enumerated() { weighted.append((r.value, spans[i])) }
            } else {
                // Letture tutte allo stesso istante: il tempo non distingue
                // nulla, contano una a testa.
                for r in sorted { weighted.append((r.value, 1)) }
            }
        }

        let totalWeight = weighted.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return (0, 0) }

        let avg = weighted.reduce(0) { $0 + $1.value * $1.weight } / totalWeight
        let variance = weighted.reduce(0) { $0 + pow($1.value - avg, 2) * $1.weight } / totalWeight
        return (avg, sqrt(variance))
    }

    // MARK: - Phase 1b: Accessory Event Aggregation

    private nonisolated static func aggregateAccessoryEvents(context: ModelContext) {
        let cal = Calendar.current
        // Only aggregate events from closed ISO weeks (before the current week's Monday).
        let weekAggregationCutoff = cal.startOfISOWeek(for: Date())

        let rawDescriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate<AccessoryEvent> { $0.timestamp < weekAggregationCutoff }
        )
        let events = (try? context.fetch(rawDescriptor)) ?? []
        guard !events.isEmpty else { return }

        // Load existing summaries for deduplication.
        let existingCutoff = Date().addingTimeInterval(-Double(DLCRetention.accessoryRaw + 7) * 86400)
        let existingDesc = FetchDescriptor<AccessoryUsageSummary>(
            predicate: #Predicate<AccessoryUsageSummary> { $0.weekStartDate > existingCutoff }
        )
        let existing = (try? context.fetch(existingDesc)) ?? []
        let existingKeys = Set(existing.map {
            "\($0.accessoryID.uuidString)|\($0.weekStartDate.timeIntervalSince1970)|\($0.eventType)"
        })

        // Group by (weekStartDate, accessoryID, eventType).
        var groups: [String: [AccessoryEvent]] = [:]
        for e in events {
            let weekStart = cal.startOfISOWeek(for: e.timestamp)
            let key = "\(e.accessoryID.uuidString)|\(weekStart.timeIntervalSince1970)|\(e.eventType)"
            groups[key, default: []].append(e)
        }

        var inserted = 0
        for (_, evts) in groups {
            guard let first = evts.first else { continue }
            let weekStart = cal.startOfISOWeek(for: first.timestamp)
            let key = "\(first.accessoryID.uuidString)|\(weekStart.timeIntervalSince1970)|\(first.eventType)"
            guard !existingKeys.contains(key) else { continue }

            let onEvents  = evts.filter { $0.state }
            let offEvents = evts.filter { !$0.state }

            // Average hour of day for on-events.
            let onHours = onEvents.map { e -> Double in
                let c = cal.dateComponents([.hour, .minute], from: e.timestamp)
                return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60.0
            }
            let avgHour = onHours.isEmpty ? 0 : onHours.reduce(0, +) / Double(onHours.count)

            // Weekday distribution for on-events (Calendar.weekday: 1=Sun … 7=Sat).
            var wd = [1: 0, 2: 0, 3: 0, 4: 0, 5: 0, 6: 0, 7: 0]
            for e in onEvents {
                let w = cal.component(.weekday, from: e.timestamp)
                wd[w, default: 0] += 1
            }

            context.insert(AccessoryUsageSummary(
                weekStartDate: weekStart,
                accessoryID: first.accessoryID,
                accessoryName: first.accessoryName,
                roomName: first.roomName ?? "",
                eventType: first.eventType,
                onCount: onEvents.count,
                offCount: offEvents.count,
                avgActivationHour: avgHour,
                wdSun: wd[1]!, wdMon: wd[2]!, wdTue: wd[3]!, wdWed: wd[4]!,
                wdThu: wd[5]!, wdFri: wd[6]!, wdSat: wd[7]!
            ))
            inserted += 1
        }
        #if DEBUG
        if inserted > 0 { print("🗂  → \(inserted) AccessoryUsageSummary created") }
        #endif
    }

    // MARK: - Phase 1c: Effectiveness Aggregation

    private nonisolated static func aggregateEffectivenessEvents(context: ModelContext) {
        let cal = Calendar.current
        // Only aggregate events from closed calendar months.
        var monthComps     = cal.dateComponents([.year, .month], from: Date())
        monthComps.day     = 1
        guard let currentMonthStart = cal.date(from: monthComps) else { return }

        let rawDescriptor = FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate<ActionEffectivenessEvent> { $0.suggestedAt < currentMonthStart }
        )
        let events = (try? context.fetch(rawDescriptor)) ?? []
        guard !events.isEmpty else { return }

        // Load existing summaries for deduplication.
        let existingCutoff = Date().addingTimeInterval(-Double(DLCRetention.effectivenessRaw + 31) * 86400)
        let existingDesc = FetchDescriptor<EffectivenessSummary>(
            predicate: #Predicate<EffectivenessSummary> { $0.monthStart > existingCutoff }
        )
        let existing = (try? context.fetch(existingDesc)) ?? []
        let existingKeys = Set(existing.map {
            "\($0.intentRaw)|\($0.monthStart.timeIntervalSince1970)"
        })

        // Group by (monthStart, intentRaw).
        var groups: [String: [ActionEffectivenessEvent]] = [:]
        for e in events {
            var mc  = cal.dateComponents([.year, .month], from: e.suggestedAt)
            mc.day  = 1
            guard let ms = cal.date(from: mc) else { continue }
            let key = "\(e.intentRaw)|\(ms.timeIntervalSince1970)"
            groups[key, default: []].append(e)
        }

        var inserted = 0
        for (_, evts) in groups {
            guard let first = evts.first else { continue }
            var mc = cal.dateComponents([.year, .month], from: first.suggestedAt)
            mc.day = 1
            guard let ms = cal.date(from: mc) else { continue }
            let key = "\(first.intentRaw)|\(ms.timeIntervalSince1970)"
            guard !existingKeys.contains(key) else { continue }

            let executed  = evts.filter { $0.outcome == "executed" }.count
            let dismissed = evts.filter { $0.outcome == "dismissed" }.count
            let expired   = evts.filter { $0.outcome == "expired" }.count
            let scores    = evts.compactMap { $0.effectivenessScore }
            let avgScore  = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            let confidence = evts.isEmpty ? 0 : Double(scores.count) / Double(evts.count)

            context.insert(EffectivenessSummary(
                monthStart: ms,
                intentRaw: first.intentRaw,
                executedCount: executed,
                dismissedCount: dismissed,
                expiredCount: expired,
                measuredCount: scores.count,
                avgEffectivenessScore: avgScore,
                confidence: confidence
            ))
            inserted += 1
        }
        #if DEBUG
        if inserted > 0 { print("🗂  → \(inserted) EffectivenessSummary created") }
        #endif
    }

    // MARK: - Phase 1d: Backfill PersistedHomeInsight

    private static func backfillPersistedHomeInsights(context: ModelContext) {
        let legacyInsights = (try? context.fetch(FetchDescriptor<PersistedInsight>())) ?? []
        guard !legacyInsights.isEmpty else { return }

        let existingHomeInsights = (try? context.fetch(FetchDescriptor<PersistedHomeInsight>())) ?? []
        var existingByDedupeKey = Dictionary(uniqueKeysWithValues: existingHomeInsights.map { ($0.dedupeKey, $0) })

        var inserted = 0
        var updated = 0
        var skipped = 0
        let legacySourceType = String(describing: PersistedInsight.self)
        for legacyInsight in legacyInsights {
            let homeInsight = mapLegacyInsightToHomeInsight(legacyInsight)
            if let existing = existingByDedupeKey[homeInsight.dedupeKey] {
                if existing.sourceRecordType == legacySourceType ||
                    existing.sourceRecordID == legacyInsight.id.uuidString {
                    existing.update(from: homeInsight)
                    updated += 1
                } else {
                    skipped += 1
                }
            } else {
                let record = PersistedHomeInsight(insight: homeInsight)
                context.insert(record)
                existingByDedupeKey[homeInsight.dedupeKey] = record
                inserted += 1
            }
        }

        #if DEBUG
        if inserted > 0 || updated > 0 || skipped > 0 {
            print("🗂  → PersistedHomeInsight backfilled (\(inserted) inserted, \(updated) updated, \(skipped) skipped)")
        }
        #endif
    }

    private static func mapLegacyInsightToHomeInsight(_ insight: PersistedInsight) -> HomeInsight {
        HomeInsight(
            id: insight.id,
            kind: homeInsightKind(intelligenceLevelRaw: insight.intelligenceLevelRaw, severityRaw: insight.severityRaw),
            category: .environment,
            severity: homeInsightSeverity(insight.severityRaw),
            status: homeInsightStatus(insight.statusRaw),
            title: insight.patternKey ?? insight.roomName,
            message: insight.message,
            whyExplanation: insight.whyExplanation,
            sourceEntityID: insight.sourceAccessoryID,
            sourceEntityName: insight.sourceAccessoryName,
            roomName: insight.roomName,
            createdAt: insight.generatedAt,
            updatedAt: insight.generatedAt,
            startedAt: insight.generatedAt,
            resolvedAt: nil,
            confidence: insight.confidenceScore ?? 0.7,
            dedupeKey: insight.patternKey ?? "persistedInsight|\(insight.roomName)|\(insight.id.uuidString)",
            suggestedActionJSON: insight.nextActionsJSON,
            sourceRecordType: String(describing: PersistedInsight.self),
            sourceRecordID: insight.id.uuidString,
            syncPolicy: .syncFull
        )
    }

    private static func homeInsightKind(intelligenceLevelRaw: String?, severityRaw: String) -> HomeInsightKind {
        if severityRaw == InsightSeverity.anomaly.rawValue { return .anomaly }
        switch intelligenceLevelRaw.flatMap(IntelligenceLevel.init(rawValue:)) {
        case .prediction:
            return .prediction
        case .recommendation:
            return .recommendation
        case .pattern:
            return .environment
        case .observation, nil:
            return .environment
        }
    }

    private static func homeInsightSeverity(_ rawValue: String) -> HomeInsightSeverity {
        switch InsightSeverity(rawValue: rawValue) {
        case .anomaly:
            return .high
        case .warning:
            return .medium
        case .info, nil:
            return .info
        }
    }

    private static func homeInsightStatus(_ rawValue: String) -> HomeInsightStatus {
        switch InsightPersistedStatus(rawValue: rawValue) {
        case .dismissed:
            return .dismissed
        case .expired:
            return .expired
        case .executed:
            return .executed
        case .active, nil:
            return .active
        }
    }

    // MARK: - Phase 2a: Prune PersistedInsight

    // MARK: - Phase 2e: Potatura della telemetria grezza

    /// Numero massimo di record grezzi cancellati per ciclo.
    ///
    /// Il primo giro su un device che non ha mai potato trova oltre 150.000
    /// letture: cancellarle in una transazione bloccherebbe il pannello per
    /// minuti. Con questo tetto lo smaltimento si distribuisce su qualche
    /// giorno, invisibile all'uso.
    private static let maxRawDeletionsPerCycle = 20_000
    private static let rawDeletionBatchSize    = 1_000

    /// Cancella letture ed eventi grezzi già distillati negli aggregati.
    ///
    /// Non esisteva: il file dichiara "Raw data is temporary, knowledge is
    /// permanent", ma per `SensorReading` e `AccessoryEvent` la seconda metà
    /// non era mai stata scritta. Da qui i 166.555 record trovati sul device
    /// primario, mai potati in mesi.
    private nonisolated static func pruneRawTelemetry(context: ModelContext) {
        // Guardia di sicurezza: se l'aggregazione non ha prodotto NULLA, il
        // grezzo è l'unica copia dei dati e non va toccato. Protegge dal caso
        // in cui la Fase 1 fallisca in silenzio.
        let summaries = (try? context.fetchCount(FetchDescriptor<DailySensorSummary>())) ?? 0
        guard summaries > 0 else {
            dprint("🗂 DataLifecycle: potatura grezzo saltata — nessun aggregato, il grezzo è l'unica copia")
            return
        }

        let sensorCutoff = Date().addingTimeInterval(-Double(DLCRetention.sensorRaw) * 86400)
        let deletedReadings = deleteInBatches(
            context: context,
            descriptor: FetchDescriptor<SensorReading>(
                predicate: #Predicate<SensorReading> { $0.timestamp < sensorCutoff }
            )
        )

        let eventCutoff = Date().addingTimeInterval(-Double(DLCRetention.accessoryRaw) * 86400)
        let deletedEvents = deleteInBatches(
            context: context,
            descriptor: FetchDescriptor<AccessoryEvent>(
                predicate: #Predicate<AccessoryEvent> { $0.timestamp < eventCutoff }
            )
        )

        // Logga SEMPRE, anche a zero: "non ha girato" e "ha girato senza
        // trovare nulla" sono diagnosi opposte e vanno distinte. Include la
        // lettura più vecchia rimasta, che dice se la soglia dei 30 giorni sta
        // effettivamente mordendo o se l'archivio è già in equilibrio.
        var oldest = FetchDescriptor<SensorReading>(
            sortBy: [SortDescriptor(\SensorReading.timestamp, order: .forward)]
        )
        oldest.fetchLimit = 1
        let oldestDate = (try? context.fetch(oldest))?.first?.timestamp
        let oldestText = oldestDate.map { ISO8601DateFormatter().string(from: $0) } ?? "none"

        dprint("🗂 DataLifecycle: potati \(deletedReadings) SensorReading e \(deletedEvents) AccessoryEvent · più vecchia rimasta \(oldestText)")
        SyncDiagnosticsLogger.log(
            "Raw pruning: readings=\(deletedReadings) events=\(deletedEvents) "
            + "cutoff=\(ISO8601DateFormatter().string(from: sensorCutoff)) oldestRemaining=\(oldestText)"
        )
    }

    /// Cancella a lotti con un save per lotto, fermandosi al tetto del ciclo.
    /// Un unico save da decine di migliaia di delete tiene il contesto in
    /// memoria e blocca a lungo; così il lavoro è limitato e ripetibile.
    private nonisolated static func deleteInBatches<T: PersistentModel>(
        context: ModelContext,
        descriptor: FetchDescriptor<T>
    ) -> Int {
        var deleted = 0
        while deleted < maxRawDeletionsPerCycle {
            var batch = descriptor
            batch.fetchLimit = rawDeletionBatchSize
            let records = (try? context.fetch(batch)) ?? []
            guard !records.isEmpty else { break }
            records.forEach { context.delete($0) }
            try? context.save()
            deleted += records.count
            if records.count < rawDeletionBatchSize { break }
        }
        return deleted
    }

    private nonisolated static func prunePersistedInsights(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(DLCRetention.insight) * 86400)
        let deleted = (try? context.delete(
            model: PersistedInsight.self,
            where: #Predicate<PersistedInsight> { $0.generatedAt < cutoff }
        )) != nil
        #if DEBUG
        if deleted { print("🗂  → PersistedInsight pruned (cutoff: \(DLCRetention.insight)d)") }
        #endif

        // Expire active insights generated with a stale prompt version.
        // Uses in-memory filter because #Predicate doesn't support optional-string comparisons safely.
        let currentVersion = AIPromptVersion.currentEnvironmental
        let activeRaw = InsightPersistedStatus.active.rawValue
        let expiredRaw = InsightPersistedStatus.expired.rawValue
        let all = (try? context.fetch(FetchDescriptor<PersistedInsight>())) ?? []
        var expiredCount = 0
        for record in all where record.statusRaw == activeRaw {
            if let v = record.promptVersion, v != currentVersion {
                record.statusRaw = expiredRaw
                expiredCount += 1
            }
        }
        #if DEBUG
        if expiredCount > 0 { print("🗂  → \(expiredCount) PersistedInsight(s) expired (stale prompt version)") }
        #endif
    }

    // MARK: - Phase 2a.1: Prune PersistedHomeInsight

    private nonisolated static func prunePersistedHomeInsights(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(DLCRetention.insight) * 86400)
        let deleted = (try? context.delete(
            model: PersistedHomeInsight.self,
            where: #Predicate<PersistedHomeInsight> { $0.createdAt < cutoff }
        )) != nil
        #if DEBUG
        if deleted { print("🗂  → PersistedHomeInsight pruned (cutoff: \(DLCRetention.insight)d)") }
        #endif

        // Ambient AI bridge records inherit the old 2-hour visibility window.
        let activeRaw = HomeInsightStatus.active.rawValue
        let expiredRaw = HomeInsightStatus.expired.rawValue
        let environmentRaw = HomeInsightCategory.environment.rawValue
        let legacySourceType = String(describing: PersistedInsight.self)
        let expiryCutoff = Date().addingTimeInterval(-2 * 3600)
        let all = (try? context.fetch(FetchDescriptor<PersistedHomeInsight>())) ?? []
        var expiredCount = 0
        for record in all where
            record.statusRaw == activeRaw &&
            record.categoryRaw == environmentRaw &&
            record.sourceRecordType == legacySourceType &&
            record.createdAt < expiryCutoff {
            record.statusRaw = expiredRaw
            record.updatedAt = Date()
            expiredCount += 1
        }
        #if DEBUG
        if expiredCount > 0 { print("🗂  → \(expiredCount) PersistedHomeInsight(s) expired (ambient bridge)") }
        #endif
    }


    // MARK: - Phase 2b: Prune SensorAlertEvent

    private nonisolated static func pruneSensorAlertEvents(context: ModelContext) {
        let resolvedCutoff = Date().addingTimeInterval(-Double(DLCRetention.alertResolved) * 86400)
        let staleCutoff    = Date().addingTimeInterval(-Double(DLCRetention.alertOrphan) * 86400)

        // In-memory filter required because optional Date comparison is unsafe in #Predicate.
        let all = (try? context.fetch(FetchDescriptor<SensorAlertEvent>())) ?? []
        var pruned = 0
        for alert in all {
            let resolvedAndOld = alert.resolvedAt.map { $0 < resolvedCutoff } ?? false
            let orphanedAndOld = alert.resolvedAt == nil && alert.triggeredAt < staleCutoff
            if resolvedAndOld || orphanedAndOld {
                context.delete(alert)
                pruned += 1
            }
        }
        #if DEBUG
        if pruned > 0 { print("🗂  → \(pruned) SensorAlertEvent(s) pruned") }
        #endif
    }

    // MARK: - Phase 2c: Prune ActionEffectivenessEvent

    private nonisolated static func pruneActionEffectivenessEvents(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(DLCRetention.effectivenessRaw) * 86400)
        let deleted = (try? context.delete(
            model: ActionEffectivenessEvent.self,
            where: #Predicate<ActionEffectivenessEvent> { $0.suggestedAt < cutoff }
        )) != nil
        #if DEBUG
        if deleted { print("🗂  → ActionEffectivenessEvent pruned (cutoff: \(DLCRetention.effectivenessRaw)d)") }
        #endif
    }

    // MARK: - Phase 2d: Prune RoomAnalysisState

    private nonisolated static func pruneRoomAnalysisStates(context: ModelContext) {
        let cutoff = Date().addingTimeInterval(-Double(DLCRetention.insight) * 86400)
        let deleted = (try? context.delete(
            model: RoomAnalysisState.self,
            where: #Predicate<RoomAnalysisState> { $0.lastAnalysisDate < cutoff }
        )) != nil
        #if DEBUG
        if deleted { print("🗂  → RoomAnalysisState pruned (cutoff: \(DLCRetention.insight)d)") }
        #endif
    }
}

// MARK: - Calendar + ISO week helper

private extension Calendar {
    /// Returns midnight on the ISO Monday (first day of ISO week) containing `date`.
    nonisolated func startOfISOWeek(for date: Date) -> Date {
        // Calendar.weekday: 1=Sunday, 2=Monday, …, 7=Saturday
        // Days to subtract to reach the preceding Monday:
        // Sun→6, Mon→0, Tue→1, Wed→2, Thu→3, Fri→4, Sat→5
        let weekday = component(.weekday, from: date)
        let offset  = (weekday + 5) % 7  // 0 for Monday, 6 for Sunday
        return startOfDay(for: date.addingTimeInterval(-Double(offset) * 86400))
    }
}
