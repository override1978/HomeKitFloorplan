import Foundation
import SwiftData

/// Ponte tra lo store eventi e `UsageEvidenceBuilder`: pesca gli
/// `AccessoryEvent` recenti e li riduce a evidenze d'uso mostrabili.
@MainActor
enum UsageEvidenceService {

    /// Evidenze dagli ultimi `days` giorni, ordinate per forza.
    static func evidences(modelContainer: ModelContainer,
                          days: Int = 21) -> [UsageEvidenceBuilder.Evidence] {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)

        var descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy: [SortDescriptor(\AccessoryEvent.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 4000

        let events = (try? context.fetch(descriptor)) ?? []
        let samples = events.map {
            UsageEvidenceBuilder.EventSample(
                accessoryID: $0.accessoryID,
                accessoryName: $0.accessoryName,
                roomName: $0.roomName,
                eventType: $0.eventType,
                state: $0.state,
                timestamp: $0.timestamp
            )
        }
        return UsageEvidenceBuilder.build(from: samples)
    }
}
