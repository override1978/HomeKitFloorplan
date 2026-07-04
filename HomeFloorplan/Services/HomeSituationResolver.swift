import Foundation

enum HomeSituationDomain: String, Codable, Hashable, CaseIterable, Identifiable {
    case air
    case climate
    case lights
    case loads
    case security
    case routine

    var id: String { rawValue }
}

struct HomeSituation: Identifiable, Hashable {
    let key: String
    let domain: HomeSituationDomain
    let insights: [HomeInsight]

    var id: String { key }
    var primary: HomeInsight { insights[0] }
    var sourceCount: Int { insights.count }
}

@MainActor
enum HomeSituationResolver {
    static func resolve(_ insights: [HomeInsight]) -> [HomeSituation] {
        let sorted = insights.sorted(by: insightSort)
        let grouped = Dictionary(grouping: sorted, by: aggregateKey(for:))

        return grouped.values.map { values in
            let groupInsights = values.sorted(by: insightSort)
            return HomeSituation(
                key: aggregateKey(for: groupInsights[0]),
                domain: domain(for: groupInsights[0]),
                insights: groupInsights
            )
        }
        .sorted { lhs, rhs in
            insightSort(lhs.primary, rhs.primary)
        }
    }

    static func domain(for insight: HomeInsight) -> HomeSituationDomain {
        let text = normalized([
            insight.title,
            insight.message,
            insight.sourceEntityName ?? "",
            insight.relatedEntityName ?? "",
            insight.dedupeKey
        ].joined(separator: " "))

        if text.contains("co2") || text.contains("co₂") || text.contains("aria") || text.contains("air") || text.contains("qualita-aria") || text.contains("air-quality") || text.contains("pm") || text.contains("voc") {
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

    static func insightSort(_ lhs: HomeInsight, _ rhs: HomeInsight) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        let lhsScore = lhs.score?.composite ?? lhs.confidence
        let rhsScore = rhs.score?.composite ?? rhs.confidence
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return lhs.updatedAt > rhs.updatedAt
    }

    private static func aggregateKey(for insight: HomeInsight) -> String {
        let domain = domain(for: insight)
        let room = normalized(insight.roomName ?? insight.sourceEntityName ?? "")
        let text = normalized([
            insight.title,
            insight.message,
            insight.sourceEntityName ?? "",
            insight.dedupeKey
        ].joined(separator: " "))
        let issue = aggregateIssueToken(for: text, domain: domain)
        return "\(domain.rawValue)|\(room)|\(issue)"
    }

    private static func aggregateIssueToken(for text: String, domain: HomeSituationDomain) -> String {
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

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "₂", with: "2")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
