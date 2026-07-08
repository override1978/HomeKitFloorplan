import Foundation

// MARK: - ContextualCondition

/// Condizione ambientale di un pattern contestuale, codificata nella
/// `causeSignature` del BehavioralPattern — zero schema change, stessa strategia dei
/// sequenziali P1.
///
/// Formato legacy (mono-condizione, stanza dell'effetto):
///     "context:<tipo>:<direzione>:<soglia>"
/// Formato esteso (P2 v2 — multi-condizione e/o stanza esplicita):
///     "context:<tipo>[@<stanza>]:<direzione>:<soglia>[+<tipo>[@<stanza>]:...]"
///
/// La stanza è percent-encoded sui caratteri riservati del formato (`@ : + %`).
/// Il formato legacy resta quello di SCRITTURA per il caso mono-condizione in stanza
/// dell'effetto: le decision key utente persistite dipendono dal parsing attuale.
/// NIENTE riferimenti ad accessori HomeKit: il binding è late, per (tipo, stanza),
/// fatto dal mapper contro le capability live.
struct ContextualCondition: Equatable {
    let sensorTypeRaw: String
    /// "above" | "below" — gli stessi valori che AutomationProposalMapper.sensorSelection si aspetta.
    let direction: String
    let threshold: Double
    /// Stanza della condizione. "" = stanza dell'effetto (formato legacy).
    /// Nome ORIGINALE HomeKit, non normalizzato: serve al matching del mapper.
    let roomName: String

    init(sensorTypeRaw: String, direction: String, threshold: Double, roomName: String = "") {
        self.sensorTypeRaw = sensorTypeRaw
        self.direction = direction
        self.threshold = threshold
        self.roomName = roomName
    }

    static let signaturePrefix = "context:"

    /// Caratteri con significato strutturale nella signature, da escapare nel nome stanza.
    private static let reservedCharacters = CharacterSet(charactersIn: "@:+%")

    /// True se la condizione può diventare un predicato HomeKit (i tipi WeatherKit
    /// come outdoorTemperature hanno hmCharacteristicType vuoto e non sono convertibili).
    var isHomeKitBacked: Bool {
        guard let type = SensorServiceType(rawValue: sensorTypeRaw) else { return true }
        return !type.hmCharacteristicType.isEmpty
    }

    private var element: String {
        let typePart: String
        if roomName.isEmpty {
            typePart = sensorTypeRaw
        } else {
            let escaped = roomName.addingPercentEncoding(
                withAllowedCharacters: Self.reservedCharacters.inverted
            ) ?? roomName
            typePart = "\(sensorTypeRaw)@\(escaped)"
        }
        return "\(typePart):\(direction):\(threshold)"
    }

    var signature: String { Self.signature(for: [self]) }

    /// Signature per una lista ordinata di condizioni (la prima è la primaria).
    /// Una condizione sola senza stanza produce il formato legacy, byte-identico a P2 v1.
    static func signature(for conditions: [ContextualCondition]) -> String {
        signaturePrefix + conditions.map(\.element).joined(separator: "+")
    }

    /// Parsa entrambi i formati. Nil se QUALSIASI elemento è malformato
    /// (una signature multi mezza-valida non deve degradare in silenzio).
    static func parseConditions(fromSignature signature: String) -> [ContextualCondition]? {
        guard signature.hasPrefix(signaturePrefix) else { return nil }
        let elements = signature
            .dropFirst(signaturePrefix.count)
            .split(separator: "+", omittingEmptySubsequences: false)
        guard !elements.isEmpty else { return nil }
        var result: [ContextualCondition] = []
        for element in elements {
            guard let condition = parseElement(element) else { return nil }
            result.append(condition)
        }
        return result
    }

    /// Condizione primaria della signature (compatibilità con i call-site P2 v1:
    /// decision key, opportunità, convertibilità leggono da qui).
    static func parse(fromSignature signature: String) -> ContextualCondition? {
        parseConditions(fromSignature: signature)?.first
    }

    private static func parseElement(_ element: Substring) -> ContextualCondition? {
        let parts = element.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty,
              parts[1] == "above" || parts[1] == "below",
              let threshold = Double(parts[2]) else {
            return nil
        }
        let typeField = parts[0]
        if let at = typeField.firstIndex(of: "@") {
            let type = String(typeField[..<at])
            let escapedRoom = String(typeField[typeField.index(after: at)...])
            guard !type.isEmpty,
                  let room = escapedRoom.removingPercentEncoding,
                  !room.isEmpty else { return nil }
            return ContextualCondition(
                sensorTypeRaw: type,
                direction: String(parts[1]),
                threshold: threshold,
                roomName: room
            )
        }
        return ContextualCondition(
            sensorTypeRaw: String(typeField),
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

        // — P2 v2: gate anti-overfitting per le coppie di condizioni (AND) —
        /// La coppia vince sulla migliore singola solo con questo margine di score:
        /// con poche osservazioni una "seconda condizione che migliora il fit" si
        /// trova quasi sempre per caso.
        var pairScoreMargin = 0.15
        /// Osservazioni con campione per ENTRAMBI i sensori.
        var pairMinimumObservations = 8
        var pairMinimumDistinctDays = 6
        /// Il baseRate congiunto deve stare sotto il minimo dei due singoli di almeno
        /// questo delta (misurato sugli stessi bucket): l'AND deve restringere davvero,
        /// altrimenti la seconda condizione è solo correlata alla prima (temp/umidità
        /// stessa stanza, temp stanza/outdoor) e non aggiunge informazione.
        var pairBaseRateImprovement = 0.05
        /// Griglia di allineamento della baseline appaiata (cadenza del SensorLogger).
        var pairAlignmentBucket: TimeInterval = 15 * 60
        /// Bucket comuni minimi perché la baseline congiunta sia significativa.
        var pairMinimumCommonBuckets = 16
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
    /// Tipi fisici della stanza outdoor promossi a condizioni globali (P2 v2):
    /// il lux del balcone è il segnale buio/luce migliore che abbiamo.
    private static let outdoorPromotedTypes: [SensorServiceType] = [
        .temperature, .humidity, .lightSensor
    ]

    /// Esito completo della valutazione di una condizione candidata: oltre a
    /// condizione e metriche porta ciò che serve alla valutazione congiunta.
    private struct Evaluation {
        let condition: ContextualCondition
        let hitRate: Double
        let baseRate: Double
        let score: Double
        /// Soddisfazione per ciascun evento, indice-allineata a `events`
        /// (nil = nessuna lettura entro la finestra).
        let eventSatisfaction: [Bool?]
        let series: [(t: Double, v: Double)]
    }

    private struct PairEvaluation {
        let first: Evaluation
        let second: Evaluation
        let hitRate: Double
        let baseRate: Double
        let score: Double
    }

    // MARK: - Entry point

    /// - Parameter outdoorRoomName: stanza che rappresenta l'esterno (AppStorage
    ///   "outdoorRoomName", letta dal chiamante: il motore resta puro). Se impostata,
    ///   i suoi sensori fisici diventano condizioni candidate GLOBALI per tutti i
    ///   gruppi — e sono convertibili in HomeKit, a differenza dei tipi WeatherKit,
    ///   che in quel caso vengono esclusi (fisico batte meteo).
    static func detect(
        candidates: [ContextualCandidate],
        accessoryEvents: [BehavioralEvent],
        readings: [SensorReading],
        outdoorRoomName: String = "",
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

            // Serie candidate: stanza dell'effetto (room = "" → formato legacy),
            // più i sensori fisici della stanza outdoor promossi a condizioni globali
            // (room esplicita → convertibili), più WeatherKit SOLO senza stanza outdoor.
            let outdoorKey = normalizedRoom(outdoorRoomName)
            var seriesForType: [(type: SensorServiceType, series: [(t: Double, v: Double)], conditionRoom: String)] = []
            for type in roomSensorTypes {
                if let series = roomSeries["\(roomKey)|\(type.rawValue)"], series.count >= 8 {
                    seriesForType.append((type, series, ""))
                }
            }
            if !outdoorKey.isEmpty, outdoorKey != roomKey {
                for type in outdoorPromotedTypes {
                    if let series = roomSeries["\(outdoorKey)|\(type.rawValue)"], series.count >= 8 {
                        seriesForType.append((type, series, outdoorRoomName))
                    }
                }
            }
            if outdoorKey.isEmpty {
                for type in outdoorSensorTypes {
                    if let series = outdoorSeries[type.rawValue], series.count >= 8 {
                        seriesForType.append((type, series, ""))
                    }
                }
            }

            // Valutazione singole: vince lo score massimo tra le accettate.
            var accepted: [Evaluation] = []
            for entry in seriesForType {
                guard let evaluation = evaluate(
                    events: events,
                    series: entry.series,
                    type: entry.type,
                    conditionRoomName: entry.conditionRoom,
                    configuration: configuration
                ) else { continue }

                let pass = evaluation.hitRate >= configuration.minimumHitRate
                    && evaluation.baseRate <= configuration.maximumBaseRate
                    && evaluation.score >= configuration.minimumScore
                lastOutcomes.append(CorrelationOutcome(
                    candidateLabel: label,
                    sensorTypeRaw: entry.conditionRoom.isEmpty
                        ? entry.type.rawValue
                        : "\(entry.type.rawValue)@\(entry.conditionRoom)",
                    hitRate: evaluation.hitRate,
                    baseRate: evaluation.baseRate,
                    score: evaluation.score,
                    accepted: pass
                ))
                if pass { accepted.append(evaluation) }
            }

            guard let bestSingle = accepted.max(by: { $0.score < $1.score }) else { continue }

            // P2 v2 — coppie (AND) tra condizioni GIÀ accettate singolarmente
            // (scelta conservativa: entrambe devono essere significative da sole).
            // La coppia vince solo con margine di score e con un baseRate congiunto
            // che restringe davvero — il margine è anche l'isteresi anti flip-flop.
            var bestPair: PairEvaluation?
            if events.count >= configuration.pairMinimumObservations,
               candidate.distinctDays >= configuration.pairMinimumDistinctDays,
               accepted.count >= 2 {
                for i in accepted.indices {
                    for j in accepted.indices where j > i {
                        guard let pair = evaluatePair(accepted[i], accepted[j], configuration: configuration) else { continue }
                        let wins = pair.score >= bestSingle.score + configuration.pairScoreMargin
                        lastOutcomes.append(CorrelationOutcome(
                            candidateLabel: label,
                            sensorTypeRaw: "\(pair.first.condition.sensorTypeRaw)+\(pair.second.condition.sensorTypeRaw)",
                            hitRate: pair.hitRate,
                            baseRate: pair.baseRate,
                            score: pair.score,
                            accepted: wins
                        ))
                        guard wins else { continue }
                        if pair.score > (bestPair?.score ?? 0) { bestPair = pair }
                    }
                }
            }

            let conditions: [ContextualCondition]
            if let bestPair {
                // Primaria = score singolo maggiore: finisce nei campi scalari
                // dell'opportunità e nella decision key.
                conditions = bestPair.first.score >= bestPair.second.score
                    ? [bestPair.first.condition, bestPair.second.condition]
                    : [bestPair.second.condition, bestPair.first.condition]
            } else {
                conditions = [bestSingle.condition]
            }
            results.append(makePattern(candidate: candidate, events: events, conditions: conditions))
        }

        return results
    }

    // MARK: - Valutazione di una singola condizione

    private static func evaluate(
        events: [BehavioralEvent],
        series: [(t: Double, v: Double)],
        type: SensorServiceType,
        conditionRoomName: String,
        configuration: Configuration
    ) -> Evaluation? {
        // Campione al momento di ogni evento: lettura più vicina entro la finestra.
        // perEventValue resta indice-allineato a `events` per la valutazione congiunta.
        var eventSamples: [Double] = []
        var perEventValue: [Double?] = []
        for event in events {
            let t = event.timestamp.timeIntervalSinceReferenceDate
            let value = nearestValue(in: series, at: t, window: configuration.sampleWindow)
            perEventValue.append(value)
            if let value { eventSamples.append(value) }
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

        return Evaluation(
            condition: ContextualCondition(
                sensorTypeRaw: type.rawValue,
                direction: direction,
                threshold: threshold,
                roomName: conditionRoomName
            ),
            hitRate: hitRate,
            baseRate: baseRate,
            score: score,
            eventSatisfaction: perEventValue.map { $0.map(satisfies) },
            series: series
        )
    }

    // MARK: - Valutazione congiunta (P2 v2)

    /// Valuta la coppia A AND B. Il hitRate congiunto usa solo gli eventi campionati
    /// da ENTRAMBI i sensori; il baseRate congiunto usa una baseline APPAIATA —
    /// le due serie riallineate su bucket comuni — così i tassi sono confrontabili
    /// sugli stessi istanti e una secondaria correlata alla primaria viene smascherata.
    private static func evaluatePair(
        _ a: Evaluation,
        _ b: Evaluation,
        configuration: Configuration
    ) -> PairEvaluation? {
        var jointHits = 0
        var sampledBoth = 0
        for (sa, sb) in zip(a.eventSatisfaction, b.eventSatisfaction) {
            guard let sa, let sb else { continue }
            sampledBoth += 1
            if sa && sb { jointHits += 1 }
        }
        guard sampledBoth >= configuration.pairMinimumObservations else { return nil }
        let hitRate = Double(jointHits) / Double(sampledBoth)
        guard hitRate >= configuration.minimumHitRate else { return nil }

        let bucketsA = bucketize(a.series, bucket: configuration.pairAlignmentBucket)
        let bucketsB = bucketize(b.series, bucket: configuration.pairAlignmentBucket)
        let common = Set(bucketsA.keys).intersection(bucketsB.keys)
        guard common.count >= configuration.pairMinimumCommonBuckets else { return nil }

        let satisfiesA = satisfier(for: a.condition)
        let satisfiesB = satisfier(for: b.condition)
        var jointBase = 0, singleBaseA = 0, singleBaseB = 0
        for key in common {
            guard let va = bucketsA[key], let vb = bucketsB[key] else { continue }
            let okA = satisfiesA(va)
            let okB = satisfiesB(vb)
            if okA { singleBaseA += 1 }
            if okB { singleBaseB += 1 }
            if okA && okB { jointBase += 1 }
        }
        let total = Double(common.count)
        let baseRate = Double(jointBase) / total
        let minSingleBase = min(Double(singleBaseA) / total, Double(singleBaseB) / total)
        // L'AND deve restringere davvero rispetto alla migliore delle due da sola.
        guard baseRate <= minSingleBase - configuration.pairBaseRateImprovement else { return nil }

        return PairEvaluation(
            first: a,
            second: b,
            hitRate: hitRate,
            baseRate: baseRate,
            score: hitRate * (1 - baseRate)
        )
    }

    private static func satisfier(for condition: ContextualCondition) -> (Double) -> Bool {
        condition.direction == "above"
            ? { $0 >= condition.threshold }
            : { $0 <= condition.threshold }
    }

    /// Media dei campioni per bucket temporale: riallinea serie campionate in
    /// istanti diversi su una griglia comune confrontabile.
    private static func bucketize(
        _ series: [(t: Double, v: Double)],
        bucket: TimeInterval
    ) -> [Int: Double] {
        guard bucket > 0 else { return [:] }
        var sums: [Int: (sum: Double, count: Int)] = [:]
        for sample in series {
            let key = Int((sample.t / bucket).rounded(.down))
            let current = sums[key] ?? (0, 0)
            sums[key] = (current.sum + sample.v, current.count + 1)
        }
        return sums.mapValues { $0.sum / Double($0.count) }
    }

    // MARK: - Costruzione pattern

    private static func makePattern(
        candidate: ContextualCandidate,
        events: [BehavioralEvent],
        conditions: [ContextualCondition]
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
            causeSignature: ContextualCondition.signature(for: conditions),
            causeName: conditions.map(conditionLabel).joined(separator: " + "),
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
                conditions: conditions
            )
        )
    }

    // MARK: - Descrizioni

    private static func conditionLabel(_ condition: ContextualCondition) -> String {
        let typeName = SensorServiceType(rawValue: condition.sensorTypeRaw)?.displayName ?? condition.sensorTypeRaw
        let roomSuffix = condition.roomName.isEmpty ? "" : " (\(condition.roomName))"
        let comparison = condition.direction == "above" ? ">" : "<"
        return "\(typeName)\(roomSuffix) \(comparison) \(formattedThreshold(condition))"
    }

    /// Frase per una singola condizione: "<tipo>[ (stanza)] supera/scende sotto <val>".
    private static func conditionPhrase(_ condition: ContextualCondition, italian: Bool) -> String {
        let typeName = SensorServiceType(rawValue: condition.sensorTypeRaw)?.displayName ?? condition.sensorTypeRaw
        let roomSuffix = condition.roomName.isEmpty ? "" : " (\(condition.roomName))"
        let value = formattedThreshold(condition)
        let relation = italian
            ? (condition.direction == "above" ? "supera" : "scende sotto")
            : (condition.direction == "above" ? "rises above" : "drops below")
        return "\(typeName)\(roomSuffix) \(relation) \(value)"
    }

    private static func naturalDescription(
        accessoryName: String,
        roomName: String?,
        action: BehavioralAction,
        conditions: [ContextualCondition]
    ) -> String {
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
            let phrases = conditions.map { conditionPhrase($0, italian: true) }.joined(separator: " e ")
            return "\(verb) \(accessoryName)\(room) quando \(phrases)"
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
        let phrases = conditions.map { conditionPhrase($0, italian: false) }.joined(separator: " and ")
        return "\(verb) \(accessoryName)\(room) when \(phrases)"
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
