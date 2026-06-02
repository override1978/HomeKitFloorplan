import Foundation
import SwiftData
import Observation

// MARK: - HabitAnalysisService

/// Analizza gli ultimi 14 giorni di AccessoryEvent e rileva pattern comportamentali.
/// I pattern vengono proposti all'utente, che può trasformarli in regole con 1 tap.
///
/// Frequenza: ogni ora (solo se app attiva).
/// Graceful degradation: se AI non configurata o offline, `patterns` rimane invariato.
@Observable
@MainActor
final class HabitAnalysisService {

    // MARK: - State

    var patterns: [HabitPattern] = []
    var isAnalyzing: Bool = false
    var lastAnalyzed: Date?

    // MARK: - Private

    private let aiSettings: AISettings
    private let modelContainer: ModelContainer
    private let minIntervalBetweenAnalyses: TimeInterval = 60 * 60  // 1 ora

    // MARK: - Init

    init(aiSettings: AISettings, modelContainer: ModelContainer) {
        self.aiSettings = aiSettings
        self.modelContainer = modelContainer
        loadPersistedPatterns()
    }

    // MARK: - Public API

    /// Analizza gli eventi degli ultimi 14 giorni e aggiunge nuovi pattern non ancora noti.
    func analyzeHabits() async {
        guard aiSettings.isOperational, aiSettings.suggestionsEnabled else { return }

        // Rispetta l'intervallo minimo
        if let last = lastAnalyzed,
           Date().timeIntervalSince(last) < minIntervalBetweenAnalyses { return }

        isAnalyzing = true
        defer {
            isAnalyzing = false
            lastAnalyzed = Date()
            persistPatterns()
        }

        let events = loadRecentEvents(days: 14)
        guard !events.isEmpty else { return }

        let payload = buildPayload(events: events)

        let systemPrompt = """
        Sei un assistente per la domotica domestica. Analizza i pattern di utilizzo degli accessori \
        e identifica le abitudini significative (confidenza > 0.75, frequenza > 5 giorni su 7). \
        Per ogni abitudine trovata, genera anche la regola corrispondente in formato strutturato. \
        Rispondi SOLO con un JSON array (nessun testo aggiuntivo, nessun markdown):
        [{"accessoryName":"...","accessoryID":"...","roomName":"...","description":"testo breve in italiano (max 1 frase)","confidence":0.87,"rule":{"triggerType":"calendar"|"characteristic","time":"22:18","weekdays":[1,2,3,4,5,6,7],"action":"on"|"off"|"dim"|"open"|"close","value":30}}]
        """

        do {
            let service = AIService(settings: aiSettings)
            let response = try await service.sendPrompt(
                systemPrompt: systemPrompt,
                userPrompt: payload
            )
            let newPatterns = parsePatterns(from: response)
            mergePatterns(newPatterns)
        } catch {
            // Graceful degradation
        }
    }

    /// Approva un pattern: cambia lo stato a .approved.
    /// Il chiamante (es. HabitsView) passerà il pattern a RuleEngineService.
    func approve(_ pattern: HabitPattern) {
        updateStatus(id: pattern.id, status: .approved)
    }

    /// Dismissal di un pattern.
    func dismiss(_ pattern: HabitPattern) {
        updateStatus(id: pattern.id, status: .dismissed)
    }

    // MARK: - Computed

    /// Pattern in attesa di decisione utente.
    var pendingPatterns: [HabitPattern] {
        patterns.filter { $0.status == .pending }
            .sorted { $0.confidence > $1.confidence }
    }

    // MARK: - Payload Builder

    private func buildPayload(events: [AccessoryEvent]) -> String {
        // Raggruppa per accessoryID
        let grouped = Dictionary(grouping: events, by: \.accessoryID)

        var accessories: [[String: Any]] = []
        for (accessoryID, eventsForAccessory) in grouped {
            guard let first = eventsForAccessory.first else { continue }

            let onEvents  = eventsForAccessory.filter { $0.state }
            let offEvents = eventsForAccessory.filter { !$0.state }

            var patternsArr: [[String: Any]] = []

            // Pattern accensione
            if let avgOnTime = averageTimeString(from: onEvents.map(\.timestamp)) {
                let weekdays = Array(Set(onEvents.map(\.weekday))).sorted()
                let frequency = Double(Set(onEvents.map {
                    Calendar.current.startOfDay(for: $0.timestamp)
                }).count) / 14.0

                var p: [String: Any] = [
                    "action":    "on",
                    "avgTime":   avgOnTime,
                    "weekdays":  weekdays,
                    "frequency": Double(round(frequency * 100) / 100),
                ]

                // Brightness media se disponibile
                let brightVals = onEvents.compactMap(\.brightness)
                if !brightVals.isEmpty {
                    let avgBrightness = brightVals.reduce(0, +) / Double(brightVals.count)
                    if avgBrightness < 0.95 {
                        p["action"] = "dim:\(Int(avgBrightness * 100))"
                    }
                }
                patternsArr.append(p)
            }

            // Pattern spegnimento
            if let avgOffTime = averageTimeString(from: offEvents.map(\.timestamp)) {
                let weekdays = Array(Set(offEvents.map(\.weekday))).sorted()
                let frequency = Double(Set(offEvents.map {
                    Calendar.current.startOfDay(for: $0.timestamp)
                }).count) / 14.0

                patternsArr.append([
                    "action":    "off",
                    "avgTime":   avgOffTime,
                    "weekdays":  weekdays,
                    "frequency": Double(round(frequency * 100) / 100),
                ])
            }

            guard !patternsArr.isEmpty else { continue }

            accessories.append([
                "name":     first.accessoryName,
                "id":       accessoryID.uuidString,
                "type":     first.eventType,
                "room":     first.roomName ?? "",
                "patterns": patternsArr,
            ])
        }

        let payloadDict: [String: Any] = [
            "analysisWindow": "14 days",
            "accessories":    accessories,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"analysisWindow\":\"14 days\",\"accessories\":[]}" }

        return str
    }

    // MARK: - Response Parser

    private func parsePatterns(from response: String) -> [HabitPattern] {
        let cleaned = extractJSONArray(from: response)
        guard let data = cleaned.data(using: .utf8),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return jsonArray.compactMap { item -> HabitPattern? in
            guard let name        = item["accessoryName"] as? String,
                  let idStr       = item["accessoryID"] as? String ?? (item["accessoryName"] as? String),
                  let room        = item["roomName"] as? String,
                  let description = item["description"] as? String,
                  let confidence  = item["confidence"] as? Double,
                  confidence >= 0.75,
                  let ruleDict    = item["rule"] as? [String: Any],
                  let ruleData    = try? JSONSerialization.data(withJSONObject: ruleDict),
                  let ruleJSON    = String(data: ruleData, encoding: .utf8)
            else { return nil }

            let accessoryID = UUID(uuidString: idStr) ?? UUID()

            return HabitPattern(
                accessoryName:    name,
                accessoryID:      accessoryID,
                roomName:         room,
                description:      description,
                confidence:       confidence,
                suggestedRuleJSON: ruleJSON
            )
        }
    }

    private func extractJSONArray(from string: String) -> String {
        guard let start = string.firstIndex(of: "["),
              let end = string.lastIndex(of: "]")
        else { return "[]" }
        return String(string[start...end])
    }

    // MARK: - Pattern Merge

    private func mergePatterns(_ newPatterns: [HabitPattern]) {
        // Aggiungi solo pattern non già presenti (confronto per accessoryID + descrizione)
        for new in newPatterns {
            let alreadyExists = patterns.contains {
                $0.accessoryID == new.accessoryID &&
                $0.description == new.description &&
                $0.status != .dismissed
            }
            if !alreadyExists {
                patterns.append(new)
            }
        }
    }

    private func updateStatus(id: UUID, status: PatternStatus) {
        if let idx = patterns.firstIndex(where: { $0.id == id }) {
            patterns[idx].status = status
        }
        persistPatterns()
    }

    // MARK: - Persistence (UserDefaults, solo dati non sensibili)

    private let persistKey = "habitPatterns.persisted"

    private func persistPatterns() {
        guard let data = try? JSONEncoder().encode(patterns) else { return }
        UserDefaults.standard.set(data, forKey: persistKey)
    }

    private func loadPersistedPatterns() {
        guard let data = UserDefaults.standard.data(forKey: persistKey),
              let saved = try? JSONDecoder().decode([HabitPattern].self, from: data)
        else { return }
        patterns = saved
    }

    // MARK: - Data Loading

    private func loadRecentEvents(days: Int) -> [AccessoryEvent] {
        let context = ModelContext(modelContainer)
        let cutoff = Date(timeIntervalSinceNow: -Double(days) * 24 * 3600)

        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate<AccessoryEvent> { $0.timestamp >= cutoff }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Time Helpers

    private func averageTimeString(from dates: [Date]) -> String? {
        guard !dates.isEmpty else { return nil }
        let cal = Calendar.current
        var totalMinutes = 0
        for date in dates {
            totalMinutes += cal.component(.hour, from: date) * 60 + cal.component(.minute, from: date)
        }
        let avg = totalMinutes / dates.count
        return String(format: "%02d:%02d", avg / 60, avg % 60)
    }
}
