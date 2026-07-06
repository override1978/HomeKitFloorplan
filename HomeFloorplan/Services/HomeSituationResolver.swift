import Foundation

enum HomeSituationDomain: String, Codable, Hashable, CaseIterable, Identifiable {
    case air
    case climate
    case lights
    case loads
    case security
    case routine

    nonisolated var id: String { rawValue }
}

struct HomeSituation: Identifiable, Hashable {
    let key: String
    let domain: HomeSituationDomain
    let insights: [HomeInsight]

    nonisolated var id: String { key }
    nonisolated var primary: HomeInsight { insights[0] }
    nonisolated var sourceCount: Int { insights.count }
}

/// Livello di aggregazione delle situation.
///
/// Le superfici hanno esigenze opposte: in-app serve il dettaglio per dispositivo
/// (due valvole in anomalia nella stessa stanza = due card, altrimenti il problema
/// si perde), mentre le notifiche di sistema devono collassare al massimo
/// (una sola push per problema/stanza).
enum HomeSituationGranularity: nonisolated Equatable {
    /// Una situation distinta per dispositivo problematico. Per dashboard e viste di dettaglio.
    case device
    /// Una situation per problema/stanza. Per notifiche e chiavi semantiche `homeSituation|`
    /// (NON cambiare i call-site del service: le chiavi persistite dipendono da questa granularità).
    case situation
}

enum HomeSituationResolver {
    nonisolated static func resolve(
        _ insights: [HomeInsight],
        granularity: HomeSituationGranularity = .situation
    ) -> [HomeSituation] {
        let sorted = insights.sorted(by: insightSort)
        let grouped = Dictionary(grouping: sorted) { aggregateKey(for: $0, granularity: granularity) }

        return grouped.values.map { values in
            let groupInsights = values.sorted(by: insightSort)
            return HomeSituation(
                key: aggregateKey(for: groupInsights[0], granularity: granularity),
                domain: domain(for: groupInsights[0]),
                insights: groupInsights
            )
        }
        .sorted { lhs, rhs in
            insightSort(lhs.primary, rhs.primary)
        }
    }

    nonisolated static func domain(for insight: HomeInsight) -> HomeSituationDomain {
        // Classificazione strutturata quando il segnale è noto: deterministica e
        // indipendente dalla lingua. Il matching testuale resta solo come fallback
        // per sorgenti narrative (AI, security, milestone) e record pre-v21.
        if let structured = structuredDomain(for: insight) {
            return structured
        }

        let text = normalized([
            insight.title,
            insight.message,
            insight.sourceEntityName ?? "",
            insight.relatedEntityName ?? "",
            insight.dedupeKey
        ].joined(separator: " "))
        // I token corti e ambigui ("aria", "air", "pm", "voc") vanno confrontati come
        // parole intere: text.contains("aria") matchava "avaria" e classificava in Aria
        // i guasti sensore; contains("pm") matchava qualunque "rpm"/"lampada" simile.
        let words = Set(text.components(separatedBy: "-"))

        if words.contains("co2") || words.contains("aria") || words.contains("air") || text.contains("qualita-aria") || text.contains("air-quality") || words.contains("pm") || words.contains("pm2") || words.contains("pm25") || words.contains("pm10") || words.contains("voc") {
            return .air
        }
        if text.contains("clima") || text.contains("climate") || text.contains("cool") || text.contains("heat") || text.contains("raffresc") || text.contains("temperatura") || text.contains("temperature") {
            return .climate
        }
        if text.contains("luce") || text.contains("light") || text.contains("lamp") {
            return .lights
        }
        if text.contains("presa") || text.contains("outlet") || text.contains("plug") || text.contains("power") || text.contains("load") || text.contains("carico") {
            return .loads
        }
        if insight.category == .security || insight.category == .presence {
            return .security
        }
        if insight.category == .lighting {
            return .lights
        }
        if insight.category == .deviceHealth || insight.category == .maintenance {
            return .loads
        }
        if insight.kind == .habit || insight.kind == .prediction || insight.category == .habits {
            return .routine
        }
        return .routine
    }

    nonisolated private static func structuredDomain(for insight: HomeInsight) -> HomeSituationDomain? {
        guard let signalType = insight.signalType else { return nil }
        switch signalType {
        case .temperature, .humidity, .active:
            return .climate
        case .airQuality, .carbonDioxide, .vocDensity, .pm25, .pm10:
            return .air
        case .smoke, .carbonMonoxide, .contact, .motion, .presence, .lock:
            return .security
        case .power:
            return insight.category == .lighting ? .lights : .loads
        case .brightness, .lightLevel:
            return .lights
        case .battery, .reachability:
            return .loads
        case .sceneActivation, .automationExecution, .userAction, .unknown:
            return nil
        }
    }

    /// Issue token deterministico dal segnale strutturato. I valori coincidono con
    /// quelli prodotti dal matching testuale nei casi in cui funzionava (temperature,
    /// air-quality, open-contact, light-on, load-on) per non far cambiare le chiavi
    /// `homeSituation|` delle notifiche esistenti.
    nonisolated private static func structuredIssueToken(for insight: HomeInsight) -> String? {
        guard let signalType = insight.signalType else { return nil }
        switch signalType {
        case .temperature:
            return "temperature"
        case .humidity:
            return "humidity"
        case .airQuality, .carbonDioxide, .vocDensity, .pm25, .pm10:
            return "air-quality"
        case .contact:
            return "open-contact"
        case .power:
            return insight.category == .lighting ? "light-on" : "load-on"
        case .active:
            return "climate-active"
        case .smoke:
            return "smoke"
        case .carbonMonoxide:
            return "carbon-monoxide"
        case .motion, .presence:
            return "motion"
        case .lock:
            return "lock"
        case .brightness, .lightLevel:
            return "light-level"
        case .battery:
            return "battery"
        case .reachability:
            return "reachability"
        case .sceneActivation, .automationExecution, .userAction, .unknown:
            return nil
        }
    }

    nonisolated static func insightSort(_ lhs: HomeInsight, _ rhs: HomeInsight) -> Bool {
        let lhsSeverity = severityRank(lhs.severity)
        let rhsSeverity = severityRank(rhs.severity)
        if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity }
        let lhsScore = compositeScore(lhs.score) ?? lhs.confidence
        let rhsScore = compositeScore(rhs.score) ?? rhs.confidence
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.updatedAt > rhs.updatedAt
    }

    nonisolated private static func severityRank(_ severity: HomeInsightSeverity) -> Int {
        switch severity {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    nonisolated private static func compositeScore(_ score: HomeInsightScore?) -> Double? {
        guard let score else { return nil }
        return min(1.0,
                   0.25 * score.relevance +
                   0.25 * score.confidence +
                   0.20 * score.urgency +
                   0.20 * score.actionability +
                   0.10 * score.novelty)
    }

    nonisolated private static func aggregateKey(
        for insight: HomeInsight,
        granularity: HomeSituationGranularity
    ) -> String {
        let domain = domain(for: insight)
        let text = normalized([
            insight.title,
            insight.message,
            insight.sourceEntityName ?? "",
            insight.dedupeKey
        ].joined(separator: " "))
        let issue = structuredIssueToken(for: insight) ?? aggregateIssueToken(for: text, domain: domain)
        let room = aggregateRoomToken(
            for: normalized(insight.roomName ?? insight.sourceEntityName ?? ""),
            domain: domain,
            issue: issue
        )
        var key = "\(domain.rawValue)|\(room)|\(issue)"
        if granularity == .device, let device = deviceToken(for: insight) {
            key += "|device:\(device)"
        }
        return key
    }

    /// Token dispositivo solo per gli insight dove il dispositivo È il problema
    /// (anomalie operative da HomeStateInterval, incoerenze clima+infisso).
    /// Le misure ambientali restano aggregate per stanza anche a granularità .device:
    /// due sensori di temperatura nella stessa stanza descrivono lo stesso problema.
    nonisolated private static func deviceToken(for insight: HomeInsight) -> String? {
        let isDeviceScoped = insight.sourceRecordType == String(describing: HomeStateInterval.self)
            || insight.dedupeKey.hasPrefix("incoherence|hvacWindowOpen")
        guard isDeviceScoped else { return nil }
        return insight.sourceEntityID ?? insight.sourceEntityName
    }

    nonisolated private static func aggregateRoomToken(
        for room: String,
        domain: HomeSituationDomain,
        issue: String
    ) -> String {
        guard domain == .climate, issue == "temperature" else { return room }

        if room == "esterno"
            || room == "outdoor"
            || room == "external"
            || room == "balcone"
            || room == "terrazzo"
            || room == "giardino"
            || room == "garden" {
            return "outdoor"
        }

        return room
    }

    nonisolated private static func aggregateIssueToken(for text: String, domain: HomeSituationDomain) -> String {
        if text.contains("co2") || text.contains("co₂") || text.contains("qualita-aria") || text.contains("air-quality") {
            return "air-quality"
        }
        if text.contains("temperatura") || text.contains("temperature") || text.contains("caldo") || text.contains("hot") || text.contains("freddo") || text.contains("cold") {
            return "temperature"
        }
        if text.contains("finestra") || text.contains("window") || text.contains("porta") || text.contains("door") || text.contains("contact") {
            return "open-contact"
        }
        if text.contains("luce") || text.contains("light") || text.contains("lamp") {
            return "light-on"
        }
        if text.contains("presa") || text.contains("outlet") || text.contains("plug") || text.contains("carico") || text.contains("load") || text.contains("power") {
            return "load-on"
        }
        return "\(domain.rawValue)-\(text.prefix(28))"
    }

    nonisolated private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "₂", with: "2")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
