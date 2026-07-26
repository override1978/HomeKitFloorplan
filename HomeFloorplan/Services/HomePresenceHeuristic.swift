import Foundation
import SwiftData

// MARK: - HomePresenceHeuristic

/// Deduce se la casa è probabilmente vuota dal silenzio degli accessori.
///
/// HomeKit non espone un'API di presenza, quindi l'unico segnale disponibile è
/// indiretto: se nessun accessorio produce eventi da alcune ore, con ogni
/// probabilità non c'è nessuno. È volutamente grezzo — serve solo a sopprimere
/// le notifiche non critiche, mai ad agire sulla casa.
///
/// Sostituisce il motore di predizione occupancy, che cercava di imparare orari
/// di arrivo e partenza dai buchi nell'attività: su una casa automatizzata i
/// buchi non esistono e non ha mai prodotto un pattern.
enum HomePresenceHeuristic {

    /// Silenzio oltre il quale la casa è considerata verosimilmente vuota.
    static let inactivityThreshold: TimeInterval = 3 * 3600

    /// Timestamp dell'ultimo evento accessorio registrato, nil se lo store è vuoto.
    static func lastActivity(modelContainer: ModelContainer) -> Date? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<AccessoryEvent>(
            sortBy: [SortDescriptor(\AccessoryEvent.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.timestamp
    }

    /// True quando nessun accessorio produce eventi da `inactivityThreshold`.
    ///
    /// Su uno store vuoto restituisce `false`: assenza di dati non è assenza di
    /// persone, e sopprimere le notifiche a un utente appena installato sarebbe
    /// il comportamento sbagliato.
    static func isLikelyAway(modelContainer: ModelContainer) -> Bool {
        guard let last = lastActivity(modelContainer: modelContainer) else { return false }
        return Date().timeIntervalSince(last) > inactivityThreshold
    }
}
