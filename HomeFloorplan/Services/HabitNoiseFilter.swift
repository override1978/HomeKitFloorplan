import Foundation

/// Filtro anti-rumore per l'apprendimento comportamentale.
///
/// Gli eventi accessorio registrati a ridosso di un'esecuzione scena sono effetti
/// della scena — o dello SmartLightingEngine, che agisce eseguendo scene — non
/// abitudini umane: darli in pasto al motore gli fa "imparare" il comportamento
/// delle proprie automazioni e riproporlo all'utente.
enum HabitNoiseFilter {

    /// Finestra di adiacenza a un'esecuzione scena entro cui un evento
    /// è considerato scene-driven.
    static let sceneAdjacencyWindow: TimeInterval = 10

    /// Ritorna gli eventi NON adiacenti a un'esecuzione scena.
    static func excludingSceneDrivenEvents(
        _ events: [AccessoryEvent],
        sceneExecutionTimestamps: [Date],
        window: TimeInterval = sceneAdjacencyWindow
    ) -> [AccessoryEvent] {
        guard !sceneExecutionTimestamps.isEmpty else { return events }
        let sortedScenes = sceneExecutionTimestamps
            .map(\.timeIntervalSinceReferenceDate)
            .sorted()

        return events.filter { event in
            !isAdjacent(event.timestamp.timeIntervalSinceReferenceDate,
                        toSorted: sortedScenes,
                        window: window)
        }
    }

    /// Ricerca binaria del timestamp scena più vicino.
    private static func isAdjacent(
        _ t: Double,
        toSorted sortedScenes: [Double],
        window: TimeInterval
    ) -> Bool {
        var low = 0
        var high = sortedScenes.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sortedScenes[mid] < t { low = mid + 1 } else { high = mid }
        }
        for index in [low - 1, low] where sortedScenes.indices.contains(index) {
            if abs(sortedScenes[index] - t) <= window { return true }
        }
        return false
    }
}
