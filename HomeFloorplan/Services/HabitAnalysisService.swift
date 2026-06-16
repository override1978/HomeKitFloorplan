import Foundation
import SwiftData
import Observation

// MARK: - ClusterNamingInput

struct ClusterNamingInput {
    let clusterID:        String    // "burst_cluster:A|B|C|D"
    let memberNames:      [String]  // parsed from clusterID (top-4 accessories)
    let dominantRoom:     String?   // nil — burst clusters span multiple rooms
    let typicalTime:      String    // e.g. "22:30" from matching BehavioralPattern
    let matchedSceneName: String?   // HomeKit scene name if matched
}

// MARK: - HabitCallResult

enum HabitCallResult {
    case skipped(reason: String)
    case success(namedCount: Int, cachedCount: Int)
    case error(message: String)
    case empty

    var displayString: String {
        switch self {
        case .skipped(let reason):
            return "Skipped — \(reason)"
        case .success(let named, let cached):
            return "✓ named \(named) clusters · \(cached) from cache"
        case .error(let msg):
            return "✗ \(msg)"
        case .empty:
            return "No unnamed clusters"
        }
    }
}

// MARK: - HabitAnalysisService

/// Assigns human-readable names to burst-cluster routines using the on-device LLM.
///
/// Triggered by BehavioralAnalysisService at the end of each analyze() run.
/// The naming call runs in an unstructured Task so it is never cancelled by a view lifecycle.
/// Names are persisted via VersionedStore and only un-named clusters are sent to the LLM.
@Observable
@MainActor
final class HabitAnalysisService {

    // MARK: - State

    /// Legacy HabitPattern storage (approve/dismiss flows still work).
    var patterns: [HabitPattern] = []
    var isAnalyzing: Bool = false
    var lastAnalyzed: Date?
    var lastCallResult: HabitCallResult?

    /// clusterID → human-readable name assigned by the LLM.
    private(set) var clusterNames: [String: String] = [:]

    // MARK: - Private

    private let aiSettings: AISettings
    private let modelContainer: ModelContainer
    private let minIntervalBetweenNaming: TimeInterval = 60 * 60  // 1 hour

    // MARK: - Init

    init(aiSettings: AISettings, modelContainer: ModelContainer) {
        self.aiSettings = aiSettings
        self.modelContainer = modelContainer
        loadPersistedPatterns()
        loadPersistedClusterNames()
    }

    // MARK: - Cluster Naming (primary entry point)

    /// Called from BehavioralAnalysisService.analyze() and from HabitsView.task.
    /// Spawns an unstructured Task so the LLM call is not bound to any view lifecycle.
    /// When `reports` is empty (app just launched, analyze() not yet run this session),
    /// falls back to deriving cluster inputs from persisted .scene patterns so unnamed
    /// clusters are named without waiting for the next 12h analyze() cycle.
    func scheduleNaming(reports: [BurstReport], patterns: [BehavioralPattern]) {
        guard aiSettings.isOperational, aiSettings.suggestionsEnabled else {
            lastCallResult = .skipped(reason: "AI not configured or suggestions disabled")
            return
        }
        // Build inputs: prefer live BurstReport data; fall back to persisted .scene patterns
        // when no analysis has run yet this session (lastBurstReport is empty on first launch).
        let inputs: [ClusterNamingInput]
        if !reports.isEmpty {
            inputs = buildInputs(from: reports, patterns: patterns)
        } else {
            inputs = buildInputsFromPatterns(patterns)
        }
        guard !inputs.isEmpty else { return }

        // Throttle: skip only when ALL clusters already have a name AND ran recently.
        // If any cluster is unnamed, proceed regardless of the interval (covers first run and new clusters).
        let hasUnnamed = inputs.contains { clusterNames[$0.clusterID] == nil }
        if !hasUnnamed,
           let last = lastAnalyzed,
           Date().timeIntervalSince(last) < minIntervalBetweenNaming {
            return
        }

        Task {
            await nameClusters(inputs: inputs)
        }
    }

    // MARK: - Cluster name lookup

    /// Returns the LLM-assigned name for a burst-cluster BehavioralPattern, or nil.
    func name(for pattern: BehavioralPattern) -> String? {
        guard pattern.patternType == .scene,
              let sig = pattern.causeSignature,
              sig.hasPrefix("burst_cluster:")
        else { return nil }
        return clusterNames[sig]
    }

    // MARK: - Approve / Dismiss (legacy HabitPattern card actions)

    func approve(_ pattern: HabitPattern) {
        updateStatus(id: pattern.id, status: .approved)
    }

    func dismiss(_ pattern: HabitPattern) {
        updateStatus(id: pattern.id, status: .dismissed)
    }

    var pendingPatterns: [HabitPattern] {
        patterns.filter { $0.status == .pending }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Backward-compat stub (call sites in ProactiveIntelligenceService, HabitsView, App)

    func analyzeHabits(knownPatterns: [BehavioralPattern] = []) async {
        // Naming is now triggered by scheduleNaming() from BehavioralAnalysisService.
    }

    // MARK: - Stale Pattern Cleanup

    func cleanupStalePatterns() {
        let now             = Date()
        let dismissedCutoff = now.addingTimeInterval(-60 * 24 * 3600)
        let pendingCutoff   = now.addingTimeInterval(-90 * 24 * 3600)
        let before = patterns.count
        patterns.removeAll {
            ($0.status == .dismissed && $0.detectedAt < dismissedCutoff)
            || ($0.status == .pending  && $0.detectedAt < pendingCutoff)
        }
        let removed = before - patterns.count
        if removed > 0 {
            persistPatterns()
            dprint("🗂 HabitAnalysis: removed \(removed) stale pattern(s)")
        }
    }

    // MARK: - Private: Naming pipeline

    private func nameClusters(inputs: [ClusterNamingInput]) async {
        let unnamed     = inputs.filter { clusterNames[$0.clusterID] == nil }
        let cachedCount = inputs.count - unnamed.count

        guard !unnamed.isEmpty else {
            lastAnalyzed = Date()
            lastCallResult = .empty
            return
        }

        isAnalyzing = true
        defer {
            isAnalyzing  = false
            lastAnalyzed = Date()
            persistClusterNames()
        }

        do {
            let service  = AIService(settings: aiSettings)
            let newNames = try await callLLM(for: unnamed, service: service)
            for (id, name) in newNames {
                clusterNames[id] = name
            }
            lastCallResult = .success(namedCount: newNames.count, cachedCount: cachedCount)
            dprint("🏷 HabitNaming: named \(newNames.count) clusters, \(cachedCount) from cache")
        } catch {
            lastCallResult = .error(message: error.localizedDescription)
            dprint("❌ HabitNaming: \(error.localizedDescription)")
        }
    }

    private func buildInputsFromPatterns(_ patterns: [BehavioralPattern]) -> [ClusterNamingInput] {
        patterns.compactMap { pattern -> ClusterNamingInput? in
            guard pattern.patternType == .scene,
                  let sig = pattern.causeSignature,
                  sig.hasPrefix("burst_cluster:")
            else { return nil }
            let members = String(sig.dropFirst("burst_cluster:".count))
                .split(separator: "|").map(String.init)
            return ClusterNamingInput(
                clusterID:        sig,
                memberNames:      members,
                dominantRoom:     nil,
                typicalTime:      pattern.avgTimeString,
                matchedSceneName: nil
            )
        }
    }

    private func buildInputs(from reports: [BurstReport], patterns: [BehavioralPattern]) -> [ClusterNamingInput] {
        reports.map { report in
            let members = String(report.signature.dropFirst("burst_cluster:".count))
                .split(separator: "|").map(String.init)

            // Match temporal context from a BehavioralPattern with the same causeSignature
            let typicalTime = patterns.first {
                $0.patternType == .scene && $0.causeSignature == report.signature
            }?.avgTimeString ?? "?"

            return ClusterNamingInput(
                clusterID:        report.signature,
                memberNames:      members,
                dominantRoom:     nil,
                typicalTime:      typicalTime,
                matchedSceneName: report.matchedSceneName
            )
        }
    }

    private func callLLM(for inputs: [ClusterNamingInput], service: AIService) async throws -> [String: String] {
        let lang = AILocale.outputLanguage

        let systemPrompt = """
        You are a smart home assistant. RESPOND IN \(lang.uppercased()).
        Assign a short, human-readable name (2-4 words) to each home automation routine.
        Each routine is a group of accessories that activate together at a typical time.
        Use the member names and typical time to infer the purpose (e.g. "Evening Reading", "Buona Notte", "Mattina Cucina").
        Respond ONLY with a valid JSON object mapping each clusterID to its name. No markdown, no extra text.
        Example: {"burst_cluster:A|B|C|D": "Evening Reading"}
        """

        let entries = inputs.map { input -> String in
            let membersJSON = "[\(input.memberNames.map { "\"\($0)\"" }.joined(separator: ", "))]"
            var parts = ["\"members\": \(membersJSON)",
                         "\"typicalTime\": \"\(input.typicalTime)\""]
            if let scene = input.matchedSceneName {
                parts.append("\"matchedScene\": \"\(scene)\"")
            }
            return "  \"\(input.clusterID)\": { \(parts.joined(separator: ", ")) }"
        }.joined(separator: ",\n")

        let userPrompt = "{\n\(entries)\n}"

        let response = try await service.sendPrompt(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let parsed = parseClusterNames(from: response)

        // Only accept IDs that were actually requested
        let validIDs = Set(inputs.map(\.clusterID))
        return parsed.filter { validIDs.contains($0.key) }
    }

    private func parseClusterNames(from response: String) -> [String: String] {
        guard let start = response.firstIndex(of: "{"),
              let end   = response.lastIndex(of: "}"),
              start <= end,
              let data  = String(response[start...end]).data(using: .utf8),
              let dict  = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    // MARK: - Persistence

    private let persistKey = "habitPatterns.persisted"
    private var clusterNamesKey: String { "habit.clusterNames.v1.\(AILocale.languageCode)" }
    private var namingLastRunKey: String { "habit.clusterNaming.lastRun.\(AILocale.languageCode)" }

    private func persistPatterns() {
        VersionedStore<[HabitPattern]>(key: persistKey, version: 1).save(patterns)
    }

    private func loadPersistedPatterns() {
        patterns = VersionedStore<[HabitPattern]>(key: persistKey, version: 1).load() ?? []
    }

    private func persistClusterNames() {
        VersionedStore<[String: String]>(key: clusterNamesKey, version: 1).save(clusterNames)
        if let date = lastAnalyzed {
            UserDefaults.standard.set(date, forKey: namingLastRunKey)
        }
    }

    private func loadPersistedClusterNames() {
        clusterNames = VersionedStore<[String: String]>(key: clusterNamesKey, version: 1).load() ?? [:]
        lastAnalyzed = UserDefaults.standard.object(forKey: namingLastRunKey) as? Date
    }

    private func updateStatus(id: UUID, status: PatternStatus) {
        if let idx = patterns.firstIndex(where: { $0.id == id }) {
            patterns[idx].status = status
        }
        persistPatterns()
    }
}
