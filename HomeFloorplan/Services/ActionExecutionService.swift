import Foundation
import HomeKit
import SwiftData
import Observation

// MARK: - ActionExecutionService

/// Punto di esecuzione centralizzato per tutte le AINextAction generate dall'AI.
///
/// Sprint 5A — responsabilità:
///   - Wrapping dell'esecuzione HomeKit (via NextActionExecutor interno)
///   - Tracking dell'esito esecuzione (via ActionEffectivenessTracker)
///   - Eliminazione delle istanze duplicate di NextActionExecutor nelle view
///
/// Sprint 5B — aggiunge:
///   - Baseline snapshot sensore dal SwiftData prima dell'esecuzione HomeKit
///   - eventID restituito dal tracker → usato da SensorLogger per il follow-up
///
/// Le view chiamano esclusivamente `execute(_:insight:in:)`.
/// Nessuna view deve istanziare direttamente NextActionExecutor o chiamare
/// ActionEffectivenessTracker.trackExecution().
@Observable
@MainActor
final class ActionExecutionService {

    // MARK: - Dependencies

    /// Tracker condiviso con AmbientalAIService per raccogliere gli esiti.
    /// Deve essere la stessa istanza iniettata in AmbientalAIService.
    let tracker: ActionEffectivenessTracker

    private let executor: NextActionExecutor
    private let modelContainer: ModelContainer

    // MARK: - Init

    init(tracker: ActionEffectivenessTracker, modelContainer: ModelContainer) {
        self.tracker = tracker
        self.executor = NextActionExecutor()
        self.modelContainer = modelContainer
    }

    // MARK: - Public API

    /// Esegue una AINextAction HomeKit e registra l'esito nel tracker.
    ///
    /// Sprint 5B: legge la baseline dal SwiftData prima di scrivere su HomeKit,
    /// così SensorLogger può calcolare il delta al prossimo campionamento.
    ///
    /// - Parameters:
    ///   - action:  L'azione da eseguire. Se `isTip` (nessun accessorio), ritorna `false` senza errori.
    ///   - insight: L'insight AI di origine, usato per il tracking (intentRaw, roomName, severity).
    ///   - home:    La casa HomeKit su cui eseguire l'azione.
    /// - Returns: `true` se HomeKit ha accettato il comando, `false` altrimenti.
    @discardableResult
    func execute(
        _ action: AINextAction,
        insight: AmbientalAIInsight,
        in home: HMHome
    ) async -> Bool {
        guard !action.isTip else { return false }

        // Normalizza actionType: il resolver produce "suggest", l'executor richiede "executeNow".
        // La conversione avviene qui una volta sola, non più in ogni view.
        let executable: AINextAction
        if action.actionType == "suggest" {
            executable = AINextAction(
                id: action.id,
                label: action.label,
                actionType: "executeNow",
                accessoryID: action.accessoryID,
                accessoryActionType: action.accessoryActionType,
                accessoryValue: action.accessoryValue,
                accessoryValue2: action.accessoryValue2
            )
        } else {
            executable = action
        }

        // Sprint 5B: snapshot baseline before HomeKit write
        let intentRaw = insight.resolvedIntents.first ?? "unknown"
        let sensorType = Self.primarySensorType(for: intentRaw)
        let baselineSnapshot = sensorType.flatMap {
            latestReading(roomName: insight.roomName, sensorTypeRaw: $0.rawValue)
        }
        let baselineValue: Double? = baselineSnapshot?.0
        let baselineReadAt: Date? = baselineSnapshot?.1

        let success = await executor.execute(executable, in: home)

        if success {
            tracker.trackExecution(
                intentRaw: intentRaw,
                roomName: insight.roomName,
                resolvedCategory: nil,
                accessoryID: action.accessoryID,
                accessoryActionType: action.accessoryActionType,
                severityRaw: insight.severity.rawValue,
                suggestedAt: insight.generatedAt,
                sensorTypeRaw: sensorType?.rawValue,
                baselineValue: baselineValue,
                baselineReadAt: baselineReadAt
            )
        }

        return success
    }

    /// Esegue un'azione raw (senza insight AI associato).
    /// Non registra nel tracker perché non proviene da un insight ambientale.
    @discardableResult
    func executeRaw(_ action: AINextAction, in home: HMHome) async -> Bool {
        await executor.execute(action, in: home)
    }

    // MARK: - Baseline helpers

    /// Restituisce (value, timestamp) dell'ultima lettura disponibile in SwiftData
    /// per la stanza e il tipo di sensore indicati. nil se nessuna lettura in DB.
    private func latestReading(roomName: String, sensorTypeRaw: String) -> (Double, Date)? {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { $0.roomName == roomName && $0.serviceTypeRaw == sensorTypeRaw },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let reading = (try? context.fetch(descriptor))?.first else { return nil }
        return (reading.value, reading.timestamp)
    }

    /// Mappa intent → tipo di sensore primario da monitorare per il follow-up.
    ///
    /// Sprint 5C: aggiunto mapping per CO₂ e VOC.
    /// nil = nessun sensore misurabile per questo intent (tip, respondToSmoke, respondToCO).
    private static func primarySensorType(for intentRaw: String) -> SensorServiceType? {
        switch intentRaw {
        case "coolRoom", "heatRoom":               return .temperature
        case "reduceHumidity", "increaseHumidity": return .humidity
        case "improveAirQuality", "ventilateRoom": return .airQuality
        case "reduceCO2":                          return .carbonDioxide
        case "reduceVOC":                          return .vocDensity
        default:                                   return nil
        }
    }
}
