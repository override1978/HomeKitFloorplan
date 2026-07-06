import Foundation

// MARK: - ContextualCondition

/// Condizione ambientale dominante di un pattern contestuale, codificata nella
/// `causeSignature` del BehavioralPattern come "context:<tipo>:<direzione>:<soglia>"
/// — zero schema change, stessa strategia dei sequenziali P1.
struct ContextualCondition: Equatable {
    let sensorTypeRaw: String
    /// "above" | "below" — gli stessi valori che AutomationProposalMapper.sensorSelection si aspetta.
    let direction: String
    let threshold: Double

    static let signaturePrefix = "context:"

    var signature: String {
        "\(Self.signaturePrefix)\(sensorTypeRaw):\(direction):\(threshold)"
    }

    static func parse(fromSignature signature: String) -> ContextualCondition? {
        guard signature.hasPrefix(signaturePrefix) else { return nil }
        let parts = signature
            .dropFirst(signaturePrefix.count)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              parts[1] == "above" || parts[1] == "below",
              let threshold = Double(parts[2]) else {
            return nil
        }
        return ContextualCondition(
            sensorTypeRaw: String(parts[0]),
            direction: String(parts[1]),
            threshold: threshold
        )
    }
}

// MARK: - ContextualCorrelationEngine

/// P2 — Contextual Phase (vedi Docs/P2-ContextualPhase-Spec.md).
///
/// Trasforma i ContextualCandidate (gruppi respinti dal gate orario perché non hanno
/// un orario fisso) in pattern `.contextual` correlandoli con le condizioni ambientali:
/// "chiudi le tende quando fa caldo" non vive sull'orologio, vive sul termometro.
@MainActor
enum ContextualCorrelationEngine {

    struct Configuration {
        var minimumObservations = 5
        var minimumDistinctDays = 4
        var minimumHitRate = 0.70
        var maximumBaseRate = 0.50
        var minimumScore = 0.40
        /// Finestra per associare a un evento la lettura sensore più vicina
        /// (allineata al campionamento ~15 min del SensorLogger).
        var sampleWindow: TimeInterval = 15 * 60
    }

    /// Esito diagnostico per ogni coppia candidato×sensore valutata.
    struct CorrelationOutcome: Identifiable {
        var id: String { "\(candidateLabel)|\(sensorTypeRaw)" }
        let candidateLabel: String
        let sensorTypeRaw: String
        let hitRate: Double
        let baseRate: Double
        let score: Double
        let accepted: Bool
    }

    private(set) static var lastOutcomes: [CorrelationOutcome] = []

    /// Tipi sensore candidati come condizione, per stanza e globali (outdoor).
    private static let roomSensorTypes: [SensorServiceType] = [
        .temperature, .humidity, .lightSensor, .carbonDioxide, .airQuality, .vocDensity
    ]
    private static let outdoorSensorTypes: [SensorServiceType] = [
        .outdoorTemperature, .outdoorHumidity
    ]

    // MARK: - Entry point

    static func detect(
        candidates: [ContextualCandidate],
        accessoryEvents: [BehavioralEvent],
        readings: [SensorReading],
        configuration: Configuration = Configuration()
    ) -> [BehavioralPattern] {
        lastOutcomes = []
        guard !candidates.isEmpty, !readings.isEmpty else { return [] }

        // Serie temporali ordinate: per (stanza|tipo) e, per gli outdoor, solo per tipo.
        var roomSeries: [String: [(t: Double, v: Double)]] = [:]
        var outdoorSeries: [String: [(t: Double, v: Double)]] = [:]
        let outdoorRaws = Set(outdoorSensorTypes.map(\.rawValue))
        for reading in readings {
            let sample = (reading.timestamp.timeIntervalSinceReferenceDate, reading.value)
            if outdoorRaws.contains(reading.serviceTypeRaw) {
                outdoorSeries[reading.serviceTypeRaw, default: []].append(sample)
            } else {
                roomSeries["\(normalizedRoom(reading.roomName))|\(reading.serviceTypeRaw)", default: []].append(sample)
            }
        }
        for key in roomSeries.keys { roomSeries[key]?.sort { $0.t < $1.t } }
        for key in outdoorSeries.keys { outdoorSeries[key]?.sort { $0.t < $1.t } }

        var results: [BehavioralPattern] = []

        for candidate in candidates {
            guard candidate.occurrences >= configuration.minimumObservations,
                  candidate.distinctDays >= configuration.minimumDistinctDays else { continue }

            // Eventi del gruppo: stesso criterio di raggruppamento del gate orario.
            let events = accessoryEvents.filter {
                $0.accessoryName == candidate.accessoryName &&
                $0.action.rawValue == candidate.action &&
                normalizedRoom($0.roomName) == normalizedRoom(candidate.roomName ?? "")
            }
            guard events.count >= configuration.minimumObservations else { continue }

            let roomKey = normalizedRoom(candidate.roomName ?? "")
            let label = "\(candidate.accessoryName)|\(candidate.action)"

            // Valuta ogni tipo sensore; vince lo score massimo.
            var best: (condition: ContextualCondition, score: Double)?
            var seriesForType: [(SensorServiceType, [(t: Double, v: Double)])] = []
            for type in roomSensorTypes {
                if let series = roomSeries["\(roomKey)|\(type.rawValue)"], series.count >= 8 {
                    seriesForType.append((type, series))
                }
            }
            for type in outdoorSensorTypes {
                if let series = outdoorSeries[type.rawValue], series.count >= 8 {
                    seriesForType.append((type, series))
                }
            }

            for (type, series) in seriesForType {
                guard let evaluation = evaluate(
                    events: events,
                    series: series,
                    type: type,
                    configuration: configuration
                ) else { continue }

                let accepted = evaluation.hitRate >= configuration.minimumHitRate
                    && evaluation.baseRate <= configuration.maximumBaseRate
                    && evaluation.score >= configuration.minimumScore
                lastOutcomes.append(CorrelationOutcome(
                    candidateLabel: label,
                    sensorTypeRaw: type.rawValue,
                    hitRate: evaluation.hitRate,
                    baseRate: evaluation.baseRate,
                    score: evaluation.score,
                    accepted: accepted
                ))

                guard accepted else { continue }
                if evaluation.score > (best?.score ?? 0) {
                    best = (evaluation.condition, evaluation.score)
                }
            }

            guard let best else { continue }
            results.append(makePattern(candidate: candidate, events: events, condition: best.condition))
        }

        return results
    }

    // MARK: - Valutazione di una singola condizione

    private static func evaluate(
        events: [BehavioralEvent],
        series: [(t: Double, v: Double)],
        type: SensorServiceType,
        configuration: Configuration
    ) -> (condition: ContextualCondition, hitRate: Double, baseRate: Double, score: Double)? {
        // Campione al momento di ogni evento: lettura più vicina entro la finestra.
        var eventSamples: [Double] = []
        for event in events {
            let t = event.timestamp.timeIntervalSinceReferenceDate
            if let value = nearestValue(in: series, at: t, window: configuration.sampleWindow) {
                eventSamples.append(value)
            }
        }
        guard eventSamples.count >= configuration.minimumObservations else { return nil }

        let baselineValues = series.map(\.v)
        guard let eventMedian = median(eventSamples),
              let baselineMedian = median(baselineValues),
              eventMedian != baselineMedian else { return nil }

        // Soglia = punto medio tra le due mediane, arrotondata a uno step leggibile.
        // (La mediana-evento pura darebbe hitRate ~50% per definizione di mediana.)
        let direction = eventMedian > baselineMedian ? "above" : "below"
        let threshold = roundToStep((eventMedian + baselineMedian) / 2, step: step(for: type))

        let satisfies: (Double) -> Bool = direction == "above"
            ? { $0 >= threshold }
            : { $0 <= threshold }

        let hitRate = Double(eventSamples.filter(satisfies).count) / Double(eventSamples.count)
        let baseRate = Double(baselineValues.filter(satisfies).count) / Double(baselineValues.count)
        let score = hitRate * (1 - baseRate)

        return (
            ContextualCondition(sensorTypeRaw: type.rawValue, direction: direction, threshold: threshold),
            hitRate,
            baseRate,
            score
        )
    }

    // MARK: - Costruzione pattern

    private static func makePattern(
        candidate: ContextualCandidate,
        events: [BehavioralEvent],
        condition: ContextualCondition
    ) -> BehavioralPattern {
        let timestamps = events.map(\.timestamp)
        let first = timestamps.min() ?? Date()
        let last = timestamps.max() ?? Date()
        let spanDays = max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 1)
        let avgMinute = events.map(\.minuteOfDay).reduce(0, +) / max(1, events.count)
        let action = events.first?.action ?? .on

        return BehavioralPattern(
            id: UUID(),
            patternType: .contextual,
            detectedAt: Date(),
            accessoryName: candidate.accessoryName,
            accessoryID: events.first?.accessoryID,
            roomName: candidate.roomName ?? events.first?.roomName ?? "",
            eventTypeRaw: events.first?.eventTypeRaw ?? "light",
            action: action,
            numericValue: events.compactMap(\.numericValue).last,
            avgMinuteOfDay: avgMinute,
            timeDeviationMinutes: candidate.stdDevMinutes,
            weekdays: [],
            dayType: nil,
            causeSignature: condition.signature,
            causeName: conditionLabel(condition),
            avgGapSeconds: nil,
            observations: events.count,
            validations: events.count,
            firstObservedAt: first,
            lastObservedAt: last,
            stabilityDays: spanDays,
            distinctActiveDays: candidate.distinctDays,
            status: .active,
            dismissedAt: nil,
            approvedAt: nil,
            naturalLanguageDescription: naturalDescription(
                accessoryName: candidate.accessoryName,
                roomName: candidate.roomName,
                action: action,
                condition: condition
            )
        )
    }

    // MARK: - Descrizioni

    private static func conditionLabel(_ condition: ContextualCondition) -> String {
        let typeName = SensorServiceType(rawValue: condition.sensorTypeRaw)?.displayName ?? condition.sensorTypeRaw
        let comparison = condition.direction == "above" ? ">" : "<"
        return "\(typeName) \(comparison) \(formattedThreshold(condition))"
    }

    private static func naturalDescription(
        accessoryName: String,
        roomName: String?,
        action: BehavioralAction,
        condition: ContextualCondition
    ) -> String {
        let typeName = SensorServiceType(rawValue: condition.sensorTypeRaw)?.displayName ?? condition.sensorTypeRaw
        let value = formattedThreshold(condition)
        let room = roomName.map { " (\($0))" } ?? ""

        if isItalian {
            let verb: String
            switch action {
            case .on: verb = "Accendi"
            case .off: verb = "Spegni"
            case .dim: verb = "Regola"
            case .activate: verb = "Attiva"
            case .open: verb = "Apri"
            case .close: verb = "Chiudi"
            case .lock: verb = "Blocca"
            case .unlock: verb = "Sblocca"
            }
            let relation = condition.direction == "above" ? "supera" : "scende sotto"
            return "\(verb) \(accessoryName)\(room) quando \(typeName) \(relation) \(value)"
        }

        let verb: String
        switch action {
        case .on: verb = "Turn on"
        case .off: verb = "Turn off"
        case .dim: verb = "Dim"
        case .activate: verb = "Activate"
        case .open: verb = "Open"
        case .close: verb = "Close"
        case .lock: verb = "Lock"
        case .unlock: verb = "Unlock"
        }
        let relation = condition.direction == "above" ? "rises above" : "drops below"
        return "\(verb) \(accessoryName)\(room) when \(typeName) \(relation) \(value)"
    }

    private static func formattedThreshold(_ condition: ContextualCondition) -> String {
        let unit: String
        switch SensorServiceType(rawValue: condition.sensorTypeRaw) {
        case .temperature, .outdoorTemperature: unit = "°C"
        case .humidity, .outdoorHumidity: unit = "%"
        case .lightSensor: unit = " lux"
        case .carbonDioxide: unit = " ppm"
        case .vocDensity: unit = " µg/m³"
        default: unit = ""
        }
        let value = condition.threshold.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", condition.threshold)
            : String(format: "%.1f", condition.threshold)
        return value + unit
    }

    // MARK: - Utilità numeriche

    /// Step di arrotondamento leggibile per tipo sensore.
    static func step(for type: SensorServiceType) -> Double {
        switch type {
        case .temperature, .outdoorTemperature: return 0.5
        case .humidity, .outdoorHumidity: return 5
        case .lightSensor: return 25
        case .carbonDioxide: return 50
        case .vocDensity: return 50
        case .airQuality: return 1
        default: return 1
        }
    }

    static func roundToStep(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private static func nearestValue(
        in series: [(t: Double, v: Double)],
        at t: Double,
        window: TimeInterval
    ) -> Double? {
        guard !series.isEmpty else { return nil }
        var low = 0
        var high = series.count - 1
        while low < high {
            let mid = (low + high) / 2
            if series[mid].t < t { low = mid + 1 } else { high = mid }
        }
        var bestValue: Double?
        var bestDistance = window
        for index in [low - 1, low] where series.indices.contains(index) {
            let distance = abs(series[index].t - t)
            if distance <= bestDistance {
                bestDistance = distance
                bestValue = series[index].v
            }
        }
        return bestValue
    }

    private static func normalizedRoom(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var isItalian: Bool {
        Locale.current.identifier.lowercased().hasPrefix("it")
    }
}
