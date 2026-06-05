#if DEBUG
import Foundation

// MARK: - AITraceLogger
//
// Observability layer for the Environmental AI pipeline — DEBUG builds only.
// Zero production impact: the entire file is compiled out in Release.
//
// Covers 8 pipeline phases for every room analysis:
//   Phase 1 — Raw sensor snapshot
//   Phase 2 — Preprocessor evaluation (sigma, anomaly, shouldCallAI)
//   Phase 3 — AI payload summary (sensors included, room type)
//   Phase 4 — AI response (message, severity, intents generated)
//   Phase 5 — Validator phase (severity clamping, intent filtering)
//   Phase 6 — Resolver phase (candidates, effectiveness, selected, fallback)
//   Phase 7 — Final insight delivered to UI
//   Phase 8 — Daily aggregate counters (persisted lightweight)
//
// Usage: AITraceLogger.shared.logXxx(...)
// Daily summary: AITraceLogger.shared.dailySummary

@MainActor
final class AITraceLogger {

    static let shared = AITraceLogger()
    private init() { loadCounters() }

    // MARK: - In-memory trace ring buffer (last 24h, max 500 entries)

    private(set) var entries: [AITraceEntry] = []
    private let maxEntries = 500
    private let windowSeconds: TimeInterval = 24 * 3600

    // MARK: - Daily aggregate counters (lightweight UserDefaults persistence)

    private(set) var totalAnalysesRun: Int = 0
    private(set) var totalAnalysesSkipped: Int = 0
    private(set) var totalInsightsGenerated: Int = 0
    private(set) var totalInsightsDismissed: Int = 0

    /// Analyses run per sensor type (e.g. "humidity": 4, "temperature": 2)
    private(set) var analysesBySensor: [String: Int] = [:]
    /// Insights generated per intent (e.g. "reduceHumidity": 3, "coolRoom": 1)
    private(set) var insightsByIntent: [String: Int] = [:]
    /// Clamping events: how often LLM severity was downgraded
    private(set) var totalSeverityClamps: Int = 0
    /// Filter events: how often intents were removed by room-type filter
    private(set) var totalIntentFilters: Int = 0
    /// Low-anomaly events: negative sigma + normal urgency (potential false positives)
    private(set) var totalLowAnomalies: Int = 0

    // MARK: - UserDefaults keys

    private enum Keys {
        static let analysesRun       = "AITrace_analysesRun"
        static let analysesSkipped   = "AITrace_analysesSkipped"
        static let insightsGenerated = "AITrace_insightsGenerated"
        static let insightsDismissed = "AITrace_insightsDismissed"
        static let analysesBySensor  = "AITrace_analysesBySensor"
        static let insightsByIntent  = "AITrace_insightsByIntent"
        static let severityClamps    = "AITrace_severityClamps"
        static let intentFilters     = "AITrace_intentFilters"
        static let lowAnomalies      = "AITrace_lowAnomalies"
        static let lastResetDate     = "AITrace_lastResetDate"
    }

    // MARK: - Phase 1: Raw Sensor Snapshot

    func logRawSnapshot(roomName: String, sensors: [(type: String, value: Double)]) {
        let lines = sensors.map { "  \($0.type): \($0.value)" }.joined(separator: "\n")
        log("📡 [P1-Raw] \(roomName)\n\(lines)")
        appendEntry(AITraceEntry(phase: 1, roomName: roomName, detail: "Raw: \(sensors.map { "\($0.type)=\($0.value)" }.joined(separator: ", "))"))
    }

    // MARK: - Phase 2: Preprocessor Evaluation

    func logPreprocessor(
        roomName: String,
        result: PreProcessorResult,
        baselineStats: [String: BaselineStat] = [:]
    ) {
        let sensorLines = result.sensorStatuses.map { s -> String in
            let sigmaStr = s.deviationSigma.map { String(format: "σ=%.2f", $0) } ?? "σ=n/a"
            let dirIcon: String
            switch s.anomalyDirection {
            case "high": dirIcon = "⬆HIGH"
            case "low":  dirIcon = "⬇LOW"
            default:     dirIcon = "ok"
            }
            let actionTag = s.actionableAnomaly ? " ⚡actionable" : ""
            if let b = baselineStats[s.type] {
                return "  \(s.type): val=\(String(format: "%.1f", s.value)) urgency=\(s.urgency) " +
                       "\(sigmaStr) [\(dirIcon)]\(actionTag) | " +
                       "baseline avg=\(String(format: "%.1f", b.avg)) " +
                       "sd=\(String(format: "%.2f", b.stdDev)) n=\(b.sampleCount)"
            }
            return "  \(s.type): val=\(String(format: "%.1f", s.value)) urgency=\(s.urgency) " +
                   "\(sigmaStr) [\(dirIcon)]\(actionTag) | baseline n/a"
        }.joined(separator: "\n")

        let gateStr = result.shouldCallAI ? "✅ CALL AI" : "🛑 SKIP AI"
        log("🔍 [P2-Pre] \(roomName) | roomType=\(result.roomType.rawValue) ceiling=\(result.severityCeiling.rawValue) \(gateStr)\n\(sensorLines)")

        // Track per-sensor analysis counts
        for s in result.sensorStatuses {
            analysesBySensor[s.type, default: 0] += 1
            // Track low-anomaly events: isAnomaly + direction=low + urgency=normal
            // (regardless of actionability — we want to see ALL statistical low anomalies in the trace)
            if s.isAnomaly, s.anomalyDirection == "low", s.urgency == "normal" {
                totalLowAnomalies += 1
            }
        }
        if result.shouldCallAI {
            totalAnalysesRun += 1
        } else {
            totalAnalysesSkipped += 1
        }
        saveCounters()

        // Build compact detail string: for each sensor show value, urgency, sigma, direction, actionable, baseline
        let detailParts = result.sensorStatuses.map { s -> String in
            let dirSuffix: String
            switch s.anomalyDirection {
            case "high": dirSuffix = "⬆"
            case "low":  dirSuffix = "⬇"
            default:     dirSuffix = "·"
            }
            let sigmaStr = s.deviationSigma.map { String(format: "%.2f", $0) } ?? "?"
            let actionStr = s.actionableAnomaly ? " act=✓" : ""
            var part = "\(s.type)=\(String(format: "%.1f", s.value)) \(s.urgency) σ=\(sigmaStr)\(dirSuffix)\(actionStr)"
            if let b = baselineStats[s.type] {
                part += " [avg=\(String(format: "%.1f", b.avg)) sd=\(String(format: "%.2f", b.stdDev)) n=\(b.sampleCount)]"
            }
            return part
        }

        appendEntry(AITraceEntry(
            phase: 2,
            roomName: roomName,
            detail: "roomType=\(result.roomType.rawValue) ceiling=\(result.severityCeiling.rawValue) " +
                    "shouldCallAI=\(result.shouldCallAI) | " +
                    detailParts.joined(separator: " • ")
        ))
    }

    // MARK: - Phase 3: AI Payload Summary

    func logPayload(roomName: String, roomType: String, anomalousSensors: [String], actionableSensors: [String] = []) {
        let anomStr   = anomalousSensors.isEmpty  ? "none" : anomalousSensors.joined(separator: ", ")
        let actionStr = actionableSensors.isEmpty ? "none" : actionableSensors.joined(separator: ", ")
        log("📤 [P3-Pay] \(roomName) | roomType=\(roomType) anomalous=[\(anomStr)] actionable=[\(actionStr)]")
        appendEntry(AITraceEntry(phase: 3, roomName: roomName,
                                 detail: "anomalous=[\(anomStr)] actionable=[\(actionStr)]"))
    }

    // MARK: - Phase 4: AI Response

    func logAIResponse(roomName: String, hasInsight: Bool, message: String?, severity: String?, intents: [String]) {
        if hasInsight {
            log("🤖 [P4-AI] \(roomName) | severity=\(severity ?? "?") intents=\(intents) message=\"\(message ?? "")\"")
        } else {
            log("🤖 [P4-AI] \(roomName) | hasInsight=false")
        }
        appendEntry(AITraceEntry(phase: 4, roomName: roomName, detail: "hasInsight=\(hasInsight) severity=\(severity ?? "nil") intents=\(intents)"))
    }

    // MARK: - Phase 5: Validator (Severity Clamping + Intent Filtering)

    func logValidator(
        roomName: String,
        llmSeverity: String, clampedSeverity: String,
        rawIntents: [String], filteredIntents: [String]
    ) {
        let clampNote = llmSeverity != clampedSeverity
            ? "⬇ CLAMPED \(llmSeverity)→\(clampedSeverity)"
            : "ok (\(clampedSeverity))"

        let removedIntents = Set(rawIntents).subtracting(filteredIntents)
        let filterNote = removedIntents.isEmpty
            ? "no filter"
            : "⛔ FILTERED: \(removedIntents.sorted().joined(separator: ", "))"

        log("🛡 [P5-Val] \(roomName) | severity \(clampNote) | intents \(filterNote)")

        if llmSeverity != clampedSeverity {
            totalSeverityClamps += 1
        }
        if !removedIntents.isEmpty {
            totalIntentFilters += 1
        }
        saveCounters()

        appendEntry(AITraceEntry(phase: 5, roomName: roomName, detail: "severity \(clampNote) | \(filterNote)"))
    }

    // MARK: - Phase 6: Resolver

    func logResolverIntent(
        roomName: String,
        intent: String,
        candidates: [(name: String, score: Double)],
        selected: String?,
        isFallback: Bool
    ) {
        let candidatesStr = candidates.map { "\($0.name)(eff=\(String(format: "%.2f", $0.score)))" }.joined(separator: ", ")
        if let sel = selected {
            let kind = isFallback ? "fallback-tip" : "accessory"
            log("⚙️ [P6-Res] \(roomName)/\(intent) | candidates=[\(candidatesStr)] → \(kind):\(sel)")
        } else {
            log("⚙️ [P6-Res] \(roomName)/\(intent) | candidates=[\(candidatesStr)] → no match")
        }
        appendEntry(AITraceEntry(phase: 6, roomName: roomName, detail: "intent=\(intent) selected=\(selected ?? "none") fallback=\(isFallback)"))
    }

    // MARK: - Phase 7: Final Insight

    func logFinalInsight(roomName: String, severity: String, message: String, actionsCount: Int) {
        log("✅ [P7-Out] \(roomName) | severity=\(severity) actions=\(actionsCount) message=\"\(message)\"")

        totalInsightsGenerated += 1
        saveCounters()

        appendEntry(AITraceEntry(phase: 7, roomName: roomName, detail: "severity=\(severity) actions=\(actionsCount)"))
    }

    /// Call when an insight is dismissed by the user (tracks dismissal rate).
    func logInsightDismissed(roomName: String, intents: [String]) {
        log("👆 [P7-Dis] \(roomName) dismissed | intents=\(intents)")
        totalInsightsDismissed += 1
        for intent in intents {
            insightsByIntent[intent, default: 0] += 1
        }
        saveCounters()
    }

    // MARK: - Daily Summary (Phase 8)

    var dailySummary: String {
        var lines: [String] = []
        lines.append("═══════════════════════════════════")
        lines.append("📊 [AITrace Daily Summary]")
        lines.append("  Analyses run:      \(totalAnalysesRun)")
        lines.append("  Analyses skipped:  \(totalAnalysesSkipped)")
        let skipRate = totalAnalysesRun + totalAnalysesSkipped > 0
            ? Int(Double(totalAnalysesSkipped) / Double(totalAnalysesRun + totalAnalysesSkipped) * 100)
            : 0
        lines.append("  Skip rate:         \(skipRate)%")
        lines.append("  Insights generated:\(totalInsightsGenerated)")
        lines.append("  Insights dismissed:\(totalInsightsDismissed)")
        lines.append("  Severity clamps:   \(totalSeverityClamps)")
        lines.append("  Intent filters:    \(totalIntentFilters)")
        lines.append("  Low anomalies:     \(totalLowAnomalies) (σ<0 + urgency=normal → possible false positive)")
        if !analysesBySensor.isEmpty {
            lines.append("  By sensor:")
            for (sensor, count) in analysesBySensor.sorted(by: { $0.value > $1.value }) {
                lines.append("    \(sensor): \(count)")
            }
        }
        if !insightsByIntent.isEmpty {
            lines.append("  Intents (dismissed):")
            for (intent, count) in insightsByIntent.sorted(by: { $0.value > $1.value }) {
                lines.append("    \(intent): \(count)")
            }
        }
        lines.append("═══════════════════════════════════")
        return lines.joined(separator: "\n")
    }

    /// Prints the daily summary to console.
    func printDailySummary() {
        print(dailySummary)
    }

    /// Resets all counters (e.g. called at midnight or on explicit user action).
    func resetCounters() {
        totalAnalysesRun = 0
        totalAnalysesSkipped = 0
        totalInsightsGenerated = 0
        totalInsightsDismissed = 0
        analysesBySensor = [:]
        insightsByIntent = [:]
        totalSeverityClamps = 0
        totalIntentFilters = 0
        totalLowAnomalies = 0
        saveCounters()
        log("🔄 [AITrace] Counters reset")
    }

    // MARK: - Private Helpers

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] \(message)")
    }

    private func appendEntry(_ entry: AITraceEntry) {
        // Prune expired entries (> 24h old)
        let cutoff = Date().addingTimeInterval(-windowSeconds)
        entries = entries.filter { $0.timestamp >= cutoff }

        entries.append(entry)

        // Hard cap to avoid unbounded memory growth
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    // MARK: - Counter Persistence

    private func saveCounters() {
        let ud = UserDefaults.standard
        ud.set(totalAnalysesRun,       forKey: Keys.analysesRun)
        ud.set(totalAnalysesSkipped,   forKey: Keys.analysesSkipped)
        ud.set(totalInsightsGenerated, forKey: Keys.insightsGenerated)
        ud.set(totalInsightsDismissed, forKey: Keys.insightsDismissed)
        ud.set(analysesBySensor,       forKey: Keys.analysesBySensor)
        ud.set(insightsByIntent,       forKey: Keys.insightsByIntent)
        ud.set(totalSeverityClamps,    forKey: Keys.severityClamps)
        ud.set(totalIntentFilters,     forKey: Keys.intentFilters)
        ud.set(totalLowAnomalies,      forKey: Keys.lowAnomalies)
        // Record reset date on first save of the day
        if ud.object(forKey: Keys.lastResetDate) == nil {
            ud.set(Date(), forKey: Keys.lastResetDate)
        }
    }

    private func loadCounters() {
        let ud = UserDefaults.standard

        // Auto-reset if last reset was on a different calendar day
        if let lastReset = ud.object(forKey: Keys.lastResetDate) as? Date {
            if !Calendar.current.isDateInToday(lastReset) {
                ud.removeObject(forKey: Keys.lastResetDate)
                // Don't load stale counters — start fresh
                return
            }
        }

        totalAnalysesRun       = ud.integer(forKey: Keys.analysesRun)
        totalAnalysesSkipped   = ud.integer(forKey: Keys.analysesSkipped)
        totalInsightsGenerated = ud.integer(forKey: Keys.insightsGenerated)
        totalInsightsDismissed = ud.integer(forKey: Keys.insightsDismissed)
        analysesBySensor       = ud.dictionary(forKey: Keys.analysesBySensor) as? [String: Int] ?? [:]
        insightsByIntent       = ud.dictionary(forKey: Keys.insightsByIntent)  as? [String: Int] ?? [:]
        totalSeverityClamps    = ud.integer(forKey: Keys.severityClamps)
        totalIntentFilters     = ud.integer(forKey: Keys.intentFilters)
        totalLowAnomalies      = ud.integer(forKey: Keys.lowAnomalies)
    }
}

// MARK: - BaselineStat

/// Baseline statistics for one sensor type, passed to logPreprocessor for telemetry.
struct BaselineStat {
    /// Mean value over the 7-day window.
    let avg: Double
    /// Population standard deviation over the 7-day window.
    let stdDev: Double
    /// Number of raw SensorReading samples used.
    let sampleCount: Int
}

// MARK: - AITraceEntry

/// Single pipeline trace entry stored in the in-memory ring buffer.
struct AITraceEntry: Identifiable {
    let id: UUID = UUID()
    let timestamp: Date = Date()
    /// Pipeline phase number (1–7).
    let phase: Int
    let roomName: String
    let detail: String
}
#endif
