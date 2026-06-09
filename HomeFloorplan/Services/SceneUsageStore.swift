import Foundation
import SwiftData
import Observation

// MARK: - SceneUsageSummary

/// Statistiche d'uso aggregate per una singola scena.
struct SceneUsageSummary {
    let sceneName: String
    /// Numero totale di esecuzioni negli ultimi 30 giorni.
    let totalExecutions: Int
    /// Timestamp dell'ultima esecuzione (nil se mai eseguita).
    let lastExecutedAt: Date?
    /// Orario medio di esecuzione "HH:mm" (nil se meno di 2 esecuzioni).
    let averageTimeOfDay: String?
    /// Giorni della settimana (1=Dom … 7=Sab) in cui viene usata.
    let typicalWeekdays: [Int]
}

// MARK: - SceneIntentCategory

/// Categoria di intento per le scene — sostituisce il filtro per stanza.
enum SceneIntentCategory: String, CaseIterable, Identifiable {
    case all        = "all"
    case routine    = "routine"
    case comfort    = "comfort"
    case security   = "security"
    case presence   = "presence"
    case climate    = "climate"
    case favorites  = "favorites"

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .all:       return "scenes.category.all"
        case .routine:   return "scenes.category.routine"
        case .comfort:   return "scenes.category.comfort"
        case .security:  return "scenes.category.security"
        case .presence:  return "scenes.category.presence"
        case .climate:   return "scenes.category.climate"
        case .favorites: return "scenes.category.favorites"
        }
    }

    var defaultLabel: String {
        switch self {
        case .all:       return "Tutte"
        case .routine:   return "Routine"
        case .comfort:   return "Comfort"
        case .security:  return "Sicurezza"
        case .presence:  return "Presenza"
        case .climate:   return "Clima"
        case .favorites: return "Preferite"
        }
    }

    var sfSymbol: String {
        switch self {
        case .all:       return "square.grid.2x2"
        case .routine:   return "clock.arrow.2.circlepath"
        case .comfort:   return "sofa.fill"
        case .security:  return "shield.fill"
        case .presence:  return "figure.walk"
        case .climate:   return "thermometer.medium"
        case .favorites: return "star.fill"
        }
    }

    /// Keyword IT+EN per l'inferenza automatica dalla categoria.
    var keywords: [String] {
        switch self {
        case .all:       return []
        case .routine:
            return ["buongiorno","buonanotte","morning","night","wake","sleep",
                    "sveglia","notte","sera","mattina","routine","daily"]
        case .comfort:
            return ["relax","atmosfera","comfort","cinema","film","movie","tv",
                    "lettura","read","cena","dinner","musica","music","party",
                    "festa","yoga","meditazione","pranzo"]
        case .security:
            return ["sicurezza","security","allarme","alarm","antifurto",
                    "shield","protezi"]
        case .presence:
            return ["arrivo","arrival","uscita","departure","away","benvenuto",
                    "welcome","casa","leave","tornato","ritorno"]
        case .climate:
            return ["clima","temperature","caldo","freddo","heat","cool",
                    "aria","air","riscalda","fresco","termostato","fan","eco"]
        case .favorites:
            return [] // gestito dalla usage data
        }
    }
}

// MARK: - SceneUsageStore

/// Servizio stateless che aggrega dati di esecuzione scene da ActivityEvent.
/// Fornisce:
/// - Statistiche per scena (conteggio, ultima esecuzione, orario medio)
/// - Suggerimenti contestuali (ora del giorno + stagione)
/// - Classificazione in SceneIntentCategory
/// - Lista delle preferite (top N per frequenza)
@Observable
@MainActor
final class SceneUsageStore {

    // MARK: - State

    /// Mappa sceneName → summary (aggiornata da loadUsageData()).
    private(set) var usageByScene: [String: SceneUsageSummary] = [:]

    // MARK: - Init

    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Public API

    /// Carica/aggiorna le statistiche d'uso degli ultimi 30 giorni.
    func loadUsageData() {
        let context = ModelContext(modelContainer)
        let cutoff = Date(timeIntervalSinceNow: -30 * 24 * 3600)
        let sceneRaw = ActivityEventCategory.sceneExecution.rawValue

        let descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate<ActivityEvent> {
                $0.timestamp >= cutoff && $0.categoryRaw == sceneRaw
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let events = (try? context.fetch(descriptor)) ?? []

        var result: [String: SceneUsageSummary] = [:]
        let grouped = Dictionary(grouping: events, by: \.title)

        for (name, sceneEvents) in grouped {
            let timestamps = sceneEvents.map(\.timestamp)
            let last = timestamps.first  // ordinati DESC, il primo è il più recente
            let avgTime = averageTimeString(from: timestamps)
            let weekdays = Array(Set(timestamps.map {
                Calendar.current.component(.weekday, from: $0)
            })).sorted()

            result[name] = SceneUsageSummary(
                sceneName: name,
                totalExecutions: sceneEvents.count,
                lastExecutedAt: last,
                averageTimeOfDay: avgTime,
                typicalWeekdays: weekdays
            )
        }
        usageByScene = result
    }

    /// Restituisce la summary per una scena specifica.
    func summary(for sceneName: String) -> SceneUsageSummary? {
        usageByScene[sceneName]
    }

    // MARK: - Top scenes

    /// Scene più usate (per frequenza), limitate a `limit`.
    func topScenes(from scenes: [SceneItem], limit: Int = 4) -> [SceneItem] {
        scenes
            .sorted { usageByScene[$0.name]?.totalExecutions ?? 0 >
                      usageByScene[$1.name]?.totalExecutions ?? 0 }
            .filter { usageByScene[$0.name]?.totalExecutions ?? 0 > 0 }
            .prefix(limit)
            .map { $0 }
    }

    /// Nome della scena più eseguita in assoluto.
    var mostUsedSceneName: String? {
        usageByScene.values.max(by: { $0.totalExecutions < $1.totalExecutions })?.sceneName
    }

    /// Ultima scena eseguita (nome).
    var lastExecutedScene: SceneUsageSummary? {
        usageByScene.values
            .compactMap { s -> (Date, SceneUsageSummary)? in
                guard let d = s.lastExecutedAt else { return nil }
                return (d, s)
            }
            .sorted { $0.0 > $1.0 }
            .first?.1
    }

    // MARK: - Contextual suggestions

    /// Scene suggerite in base al contesto attuale (ora, giorno, stagione).
    /// Restituisce al massimo 3 suggerimenti con la relativa motivazione.
    func suggestedScenes(from scenes: [SceneItem]) -> [(scene: SceneItem, reason: SceneSuggestionReason)] {
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let weekday = Calendar.current.component(.weekday, from: now)
        let month = Calendar.current.component(.month, from: now)

        var candidates: [(scene: SceneItem, reason: SceneSuggestionReason, score: Double)] = []

        for scene in scenes {
            let name = scene.name.lowercased()
            let usage = usageByScene[scene.name]
            var score: Double = 0
            var reason: SceneSuggestionReason?

            // ── Ora del giorno ─────────────────────────────────────────
            if (hour >= 6 && hour < 9) &&
               (name.contains("buongiorno") || name.contains("morning") || name.contains("sveglia")) {
                score += 1.5
                reason = .timeOfDay
            }
            if (hour >= 21 || hour < 1) &&
               (name.contains("buonanotte") || name.contains("night") || name.contains("notte")) {
                score += 1.5
                reason = .timeOfDay
            }
            if (hour >= 17 && hour < 20) &&
               (name.contains("sera") || name.contains("evening") || name.contains("atmosfera")) {
                score += 1.0
                reason = .timeOfDay
            }

            // ── Routine settimanale ────────────────────────────────────
            if let usage, usage.typicalWeekdays.contains(weekday) {
                let freq = Double(usage.totalExecutions) / 30.0
                if freq > 0.3 {
                    score += 0.8
                    reason = reason ?? .weeklyRoutine
                }
            }

            // ── Stagione ───────────────────────────────────────────────
            let isWinter = month <= 2 || month == 12
            let isSummer = month >= 6 && month <= 8
            if isWinter && (name.contains("caldo") || name.contains("heat") || name.contains("riscalda")) {
                score += 0.7
                reason = reason ?? .season
            }
            if isSummer && (name.contains("fresco") || name.contains("cool") || name.contains("freddo")) {
                score += 0.7
                reason = reason ?? .season
            }

            // ── Orario medio storico ───────────────────────────────────
            if let avgStr = usage?.averageTimeOfDay,
               let avgHour = Int(avgStr.prefix(2)) {
                let diff = abs(hour - avgHour)
                if diff <= 1 {
                    score += 0.6
                    reason = reason ?? .usualTime
                }
            }

            if let r = reason, score > 0 {
                candidates.append((scene: scene, reason: r, score: score))
            }
        }

        return candidates
            .sorted { $0.score > $1.score }
            .prefix(3)
            .map { (scene: $0.scene, reason: $0.reason) }
    }

    // MARK: - Category classification

    /// Classifica una scena in una SceneIntentCategory.
    func category(for scene: SceneItem) -> SceneIntentCategory {
        let name = scene.name.lowercased()
        // Check in priority order
        for cat in [SceneIntentCategory.security, .presence, .routine, .comfort, .climate] {
            if cat.keywords.contains(where: { name.contains($0) }) {
                return cat
            }
        }
        return .comfort  // default
    }

    /// Filtra le scene per categoria di intento.
    func scenes(_ scenes: [SceneItem],
                inCategory category: SceneIntentCategory,
                favorites: Set<String> = []) -> [SceneItem] {
        switch category {
        case .all:
            return scenes
        case .favorites:
            // Top 6 per frequenza OR nella lista preferiti
            let top = topScenes(from: scenes, limit: 6).map(\.name)
            let topSet = Set(top).union(favorites)
            return scenes.filter { topSet.contains($0.name) }
        default:
            return scenes.filter { self.category(for: $0) == category }
        }
    }

    // MARK: - Time helper

    private func averageTimeString(from dates: [Date]) -> String? {
        guard dates.count >= 2 else { return nil }
        let cal = Calendar.current
        let totalMinutes = dates.reduce(0) {
            $0 + cal.component(.hour, from: $1) * 60 + cal.component(.minute, from: $1)
        }
        let avg = totalMinutes / dates.count
        return String(format: "%02d:%02d", avg / 60, avg % 60)
    }
}

// MARK: - SceneSuggestionReason

enum SceneSuggestionReason {
    case timeOfDay
    case weeklyRoutine
    case season
    case usualTime

    var localizedKey: String {
        switch self {
        case .timeOfDay:      return "scenes.suggestion.reason.timeOfDay"
        case .weeklyRoutine:  return "scenes.suggestion.reason.weeklyRoutine"
        case .season:         return "scenes.suggestion.reason.season"
        case .usualTime:      return "scenes.suggestion.reason.usualTime"
        }
    }

    func defaultLabel(sceneName: String) -> String {
        switch self {
        case .timeOfDay:
            return String(localized: "scenes.suggestion.reason.timeOfDay",
                          defaultValue: "Suits the current time")
        case .weeklyRoutine:
            return String(localized: "scenes.suggestion.reason.weeklyRoutine",
                          defaultValue: "Part of your routine")
        case .season:
            return String(localized: "scenes.suggestion.reason.season",
                          defaultValue: "Recommended for the season")
        case .usualTime:
            return String(localized: "scenes.suggestion.reason.usualTime",
                          defaultValue: "Usual usage time")
        }
    }
}
