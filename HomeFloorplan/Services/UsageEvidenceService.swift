import Foundation
import SwiftData

/// Ponte tra lo store eventi e `UsageEvidenceBuilder`: pesca gli
/// `AccessoryEvent` recenti e li riduce a evidenze d'uso mostrabili.
@MainActor
enum UsageEvidenceService {

    /// Evidenze + funnel diagnostico dagli ultimi `days` giorni.
    static func evidencesWithReport(modelContainer: ModelContainer,
                                    days: Int = 21)
    -> (evidences: [UsageEvidenceBuilder.Evidence], funnel: UsageEvidenceBuilder.FunnelReport) {
        UsageEvidenceBuilder.buildWithReport(from: samples(modelContainer: modelContainer, days: days))
    }

    /// Evidenze dagli ultimi `days` giorni, ordinate per forza.
    static func evidences(modelContainer: ModelContainer,
                          days: Int = 21) -> [UsageEvidenceBuilder.Evidence] {
        UsageEvidenceBuilder.build(from: samples(modelContainer: modelContainer, days: days))
    }

    /// Fetch grezzo dei campioni evento (condiviso con l'interprete LLM).
    static func samples(modelContainer: ModelContainer,
                        days: Int) -> [UsageEvidenceBuilder.EventSample] {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        var descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\AccessoryEvent.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 4000

        let events = (try? context.fetch(descriptor)) ?? []
        return UsageEvidenceBuilder.stateTransitions(events.map {
            UsageEvidenceBuilder.EventSample(
                accessoryID: $0.accessoryID,
                accessoryName: $0.accessoryName,
                roomName: $0.roomName,
                eventType: $0.eventType,
                state: $0.state,
                timestamp: $0.timestamp,
                origin: $0.originRaw
            )
        })
    }

    /// Numero di `AccessoryEvent` di tipo azionabile registrati negli ultimi
    /// `days` giorni — metrica di raccolta dati mostrata in HabitsView.
    static func eligibleEventCount(modelContainer: ModelContainer, days: Int = 30) -> Int {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff }
        )
        let allowed = UsageEvidenceBuilder.Configuration().allowedEventTypes
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { allowed.contains($0.eventType) }.count
    }
}
