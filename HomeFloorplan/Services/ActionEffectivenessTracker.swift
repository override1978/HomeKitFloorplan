import Foundation
import SwiftData
import Observation

// MARK: - ActionEffectivenessTracker

/// Registra e analizza l'efficacia dei chip AI generati da AmbientalAIService.
///
/// Responsabilità:
/// - Tracciare l'esito di ogni chip (executed / dismissed / expired)
/// - Calcolare execution rate per intent e per stanza
/// - Fornire statistiche aggregate per insight futuri
///
/// Injection: condiviso tra AmbientalAIService e le view che eseguono i chip.
@Observable
@MainActor
final class ActionEffectivenessTracker {

    // MARK: - Private

    private let context: ModelContext
    /// Minimum number of complete outcome measurements required before returning a meaningful average.
    private let minimumSamplesRequired = 3

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.context = ModelContext(modelContainer)
    }

    // MARK: - Track API

    /// Registra che un chip è stato eseguito (utente ha tappato).
    /// - Returns: l'UUID dell'evento creato, usato da ActionExecutionService per aggiornare la baseline.
    @discardableResult
    func trackExecution(
        intentRaw: String,
        roomName: String,
        resolvedCategory: String?,
        accessoryID: String?,
        accessoryActionType: String?,
        severityRaw: String,
        suggestedAt: Date,
        sensorTypeRaw: String? = nil,
        baselineValue: Double? = nil,
        baselineReadAt: Date? = nil
    ) -> UUID {
        let event = ActionEffectivenessEvent(
            intentRaw: intentRaw,
            roomName: roomName,
            resolvedCategory: resolvedCategory,
            accessoryID: accessoryID,
            accessoryActionType: accessoryActionType,
            outcome: "executed",
            suggestedAt: suggestedAt,
            interactedAt: Date(),
            severityRaw: severityRaw,
            sensorTypeRaw: sensorTypeRaw,
            baselineValue: baselineValue,
            baselineReadAt: baselineReadAt
        )
        persist(event)
        dprint("📊 [Tracker] executed — intent:\(intentRaw) room:\(roomName) cat:\(resolvedCategory ?? "tip") baseline:\(baselineValue.map { String(format: "%.1f", $0) } ?? "n/a")")
        return event.id
    }

    /// Registra che un insight è stato dismesso dall'utente senza eseguire azioni.
    func trackDismissal(
        intents: [String],
        roomName: String,
        severityRaw: String,
        suggestedAt: Date,
        reason: DismissalReason = .unclear
    ) {
        for intentRaw in intents {
            let event = ActionEffectivenessEvent(
                intentRaw: intentRaw,
                roomName: roomName,
                resolvedCategory: nil,
                accessoryID: nil,
                accessoryActionType: nil,
                outcome: "dismissed",
                dismissalReasonRaw: reason.rawValue,
                suggestedAt: suggestedAt,
                interactedAt: Date(),
                severityRaw: severityRaw
            )
            persist(event)
        }
        dprint("📊 [Tracker] dismissed — intents:\(intents) room:\(roomName) reason:\(reason.rawValue)")
    }

    /// Registra che un insight è scaduto senza alcuna interazione.
    func trackExpiration(
        intents: [String],
        roomName: String,
        severityRaw: String,
        suggestedAt: Date
    ) {
        for intentRaw in intents {
            let event = ActionEffectivenessEvent(
                intentRaw: intentRaw,
                roomName: roomName,
                resolvedCategory: nil,
                accessoryID: nil,
                accessoryActionType: nil,
                outcome: "expired",
                suggestedAt: suggestedAt,
                interactedAt: nil,
                severityRaw: severityRaw
            )
            persist(event)
        }
        dprint("📊 [Tracker] expired — intents:\(intents) room:\(roomName)")
    }

    // MARK: - Analytics

    /// Percentuale di chip eseguiti rispetto al totale suggerito per un dato intent.
    /// Considera solo eventi degli ultimi `days` giorni.
    func executionRate(for intentRaw: String, days: Int = 30) -> Double {
        let events = fetchEvents(days: days)
            .filter { $0.intentRaw == intentRaw }
        guard !events.isEmpty else { return 0 }
        let executed = events.filter { $0.outcome == "executed" }.count
        return Double(executed) / Double(events.count)
    }

    /// Statistiche aggregate per tutti gli intent negli ultimi `days` giorni.
    /// Restituisce un array di (intentRaw, executed, dismissed, expired).
    func summaryStats(days: Int = 30) -> [(intentRaw: String, executed: Int, dismissed: Int, expired: Int)] {
        let events = fetchEvents(days: days)
        let grouped = Dictionary(grouping: events, by: \.intentRaw)

        return grouped.map { intentRaw, evts in
            let executed  = evts.filter { $0.outcome == "executed"  }.count
            let dismissed = evts.filter { $0.outcome == "dismissed" }.count
            let expired   = evts.filter { $0.outcome == "expired"   }.count
            return (intentRaw: intentRaw, executed: executed, dismissed: dismissed, expired: expired)
        }.sorted { $0.intentRaw < $1.intentRaw }
    }

    // MARK: - Outcome Measurement (Sprint 5B/5C)

    // Follow-up validity window: reading must arrive between 3 and 90 minutes
    // after execution to be considered a meaningful environmental response.
    private static let followUpMinInterval: TimeInterval =  3 * 60
    private static let followUpMaxInterval: TimeInterval = 90 * 60

    // MARK: OutcomeConfig (Sprint 5C)
    //
    // Sensor-type-specific scoring parameters.
    //
    // direction:   +1 = higher is better (heatRoom, increaseHumidity)
    //              -1 = lower is better  (coolRoom, reduceHumidity, airQuality, CO₂, VOC)
    //
    // targetDelta: absolute delta (in sensor units) that yields a score of 1.0.
    //   Grounded in domain physiology / IAQ standards:
    //     temperature  → 2 °C shift is a perceptible, meaningful HVAC response
    //     humidity     → 5 %RH shift is an actionable dehumidification result
    //     airQuality   → 1 index step (HAP 1–5 scale) is significant
    //     carbonDioxide→ 200 ppm reduction is meaningful (OMS comfort threshold shift)
    //     carbonMonoxide→ 5 ppm reduction is safety-relevant
    //     vocDensity   → 100 µg/m³ reduction is measurable purifier output
    //
    // Any sensor type not explicitly listed falls back to the "unknown" entry.

    private struct OutcomeConfig {
        let direction:   Double   // +1 or -1
        let targetDelta: Double   // delta for score 1.0
    }

    private static let outcomeConfigs: [String: OutcomeConfig] = [
        // Temperature intents
        "coolRoom":           OutcomeConfig(direction: -1, targetDelta: 2.0),
        "heatRoom":           OutcomeConfig(direction: +1, targetDelta: 2.0),
        // Humidity intents
        "reduceHumidity":     OutcomeConfig(direction: -1, targetDelta: 5.0),
        "increaseHumidity":   OutcomeConfig(direction: +1, targetDelta: 5.0),
        // Air quality / ventilation intents — HAP scale 1 (excellent) to 5 (poor)
        "improveAirQuality":  OutcomeConfig(direction: -1, targetDelta: 1.0),
        "ventilateRoom":      OutcomeConfig(direction: -1, targetDelta: 1.0),
        // Safety intents — measurement unreliable in short window, kept for completeness
        "respondToSmoke":     OutcomeConfig(direction: -1, targetDelta: 1.0),
        "respondToCO":        OutcomeConfig(direction: -1, targetDelta: 5.0),
        // CO₂ intent (Sprint 5C)
        "reduceCO2":          OutcomeConfig(direction: -1, targetDelta: 200.0),
        // VOC intent (Sprint 5C)
        "reduceVOC":          OutcomeConfig(direction: -1, targetDelta: 100.0),
        // Fallback
        "unknown":            OutcomeConfig(direction: -1, targetDelta: 3.0),
    ]

    /// Returns the OutcomeConfig for a given intentRaw.
    /// Falls back to "unknown" if the intent is not in the catalog.
    private static func outcomeConfig(for intentRaw: String) -> OutcomeConfig {
        outcomeConfigs[intentRaw] ?? outcomeConfigs["unknown"]!
    }

    /// Chiamato da SensorLogger dopo ogni campionamento per chiudere le misurazioni pending.
    ///
    /// Per ogni evento con `measurementState == "pending"` e un `sensorTypeRaw` corrispondente
    /// alla nuova lettura, calcola il delta e l'effectivenessScore usando i parametri
    /// sensor-specific di OutcomeConfig.
    func recordOutcome(
        roomName: String,
        sensorTypeRaw: String,
        followUpValue: Double,
        readAt: Date
    ) {
        let descriptor = FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate { $0.measurementState == "pending" && $0.roomName == roomName && $0.sensorTypeRaw == sensorTypeRaw }
        )
        guard let pending = try? context.fetch(descriptor), !pending.isEmpty else { return }

        for event in pending {
            guard let baseline = event.baselineValue,
                  let baselineReadAt = event.baselineReadAt else {
                // Shouldn't happen — but if baseline is missing, mark unreliable
                event.measurementState = "unreliable"
                continue
            }

            let interval = readAt.timeIntervalSince(baselineReadAt)

            guard interval >= Self.followUpMinInterval else {
                // Reading arrived too quickly — skip this cycle, keep "pending"
                continue
            }

            if interval > Self.followUpMaxInterval {
                // Reading arrived too late — not attributable to the action
                event.measurementState = "unreliable"
                dprint("📊 [Tracker] outcome unreliable — event:\(event.id) interval:\(Int(interval/60))min")
                continue
            }

            let delta = followUpValue - baseline
            event.followUpValue = followUpValue
            event.followUpReadAt = readAt
            event.deltaValue = delta

            // Sprint 5C: sensor-type-specific scoring via OutcomeConfig
            let config = Self.outcomeConfig(for: event.intentRaw)
            let signedDelta = delta * config.direction  // positive = moved in right direction
            let score = max(0, min(1, signedDelta / config.targetDelta))
            event.effectivenessScore = score
            event.measurementState = "complete"

            dprint("📊 [Tracker] outcome complete — intent:\(event.intentRaw) sensor:\(sensorTypeRaw) baseline:\(String(format: "%.1f", baseline)) followUp:\(String(format: "%.1f", followUpValue)) Δ:\(String(format: "%.1f", delta)) score:\(String(format: "%.2f", score)) [target±\(config.targetDelta)]")
        }

        try? context.save()
    }

    // MARK: - Outcome Analytics

    /// Struttura restituita da outcomeStats.
    struct OutcomeStat {
        let intentRaw: String
        let sampleCount: Int
        let averageScore: Double
        let averageDelta: Double
    }

    /// Statistiche di efficacia per intent, basate sulle misurazioni "complete".
    /// Considera solo gli ultimi `days` giorni.
    func outcomeStats(days: Int = 30) -> [OutcomeStat] {
        let events = fetchEvents(days: days)
            .filter { $0.measurementState == "complete" }
        let grouped = Dictionary(grouping: events, by: \.intentRaw)

        return grouped.compactMap { intentRaw, evts in
            let scores  = evts.compactMap(\.effectivenessScore)
            let deltas  = evts.compactMap(\.deltaValue)
            guard !scores.isEmpty else { return nil }
            return OutcomeStat(
                intentRaw: intentRaw,
                sampleCount: scores.count,
                averageScore: scores.reduce(0, +) / Double(scores.count),
                averageDelta: deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
            )
        }.sorted { $0.intentRaw < $1.intentRaw }
    }

    /// Efficacia media (0–1) per un intent specifico. 0 se meno di `minimumSamplesRequired` misurazioni.
    func averageEffectiveness(for intentRaw: String, days: Int = 30) -> Double {
        let scores = fetchEvents(days: days)
            .filter { $0.intentRaw == intentRaw && $0.measurementState == "complete" }
            .compactMap(\.effectivenessScore)
        guard scores.count >= minimumSamplesRequired else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Efficacia media (0–1) per un accessorio specifico in un dato intent.
    /// Usato da ActionResolver (Sprint 6) per ordinare i candidati per accessory.
    /// Restituisce 0.5 (neutro) se meno di `minimumSamplesRequired` misurazioni — evita di
    /// promuovere accessori con un singolo campione di successo.
    func averageEffectiveness(for intentRaw: String, accessoryID: String, days: Int = 30) -> Double {
        let scores = fetchEvents(days: days)
            .filter {
                $0.intentRaw == intentRaw &&
                $0.accessoryID == accessoryID &&
                $0.measurementState == "complete"
            }
            .compactMap(\.effectivenessScore)
        guard scores.count >= minimumSamplesRequired else { return 0.5 }   // neutral prior: insufficient data
        return scores.reduce(0, +) / Double(scores.count)
    }

    // MARK: - Maintenance

    /// Elimina eventi più vecchi di `days` giorni per contenere la dimensione del DB.
    func cleanup(olderThan days: Int = 90) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let descriptor = FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate { $0.suggestedAt < cutoff }
        )
        guard let old = try? context.fetch(descriptor) else { return }
        for event in old { context.delete(event) }
        try? context.save()
        dprint("📊 [Tracker] cleanup: rimossi \(old.count) eventi più vecchi di \(days) giorni")
    }

    // MARK: - Private

    private func persist(_ event: ActionEffectivenessEvent) {
        context.insert(event)
        try? context.save()
    }

    private func fetchEvents(days: Int) -> [ActionEffectivenessEvent] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        let descriptor = FetchDescriptor<ActionEffectivenessEvent>(
            predicate: #Predicate { $0.suggestedAt >= cutoff },
            sortBy: [SortDescriptor(\.suggestedAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }
}
