import Foundation
import SwiftData

// MARK: - AnomalySignal

struct AnomalySignal {
    enum Kind {
        case oscillating  // high-frequency value swings
        case stuck        // identical value for an implausibly long period
        case outOfRange   // physically impossible reading
    }
    let kind:          Kind
    let sensorType:    SensorServiceType
    let roomName:      String
    let description:   String
    let semanticKey:   String
    let score:         IntelligenceScore
    /// The key numeric value driving this anomaly: stddev for oscillating,
    /// stuck reading for stuck, implausible reading for outOfRange.
    /// Stored so the display layer can reconstruct the body in any locale.
    let numericDetail: Double
}

// MARK: - SensorAnomalyDetector

/// Analyzes the most recent SensorReading records and returns anomaly signals.
/// Pure builder — no state, no side effects.
enum SensorAnomalyDetector {

    /// Relative std-dev threshold above which oscillation is flagged.
    private static let oscillationRelStddev: Double = 0.15
    /// Minimum absolute range to avoid flagging stable, low-range sensors as oscillating.
    private static let oscillationMinRange:  Double = 2.0
    /// Duration above which a completely stuck value is considered anomalous.
    private static let stuckDuration: TimeInterval = 30 * 60   // 30 min
    /// Lookback window for readings.
    private static let lookbackSeconds: Double = 2 * 3600      // 2 h

    // MARK: - Detection

    static func detect(modelContainer: ModelContainer) async -> [AnomalySignal] {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-lookbackSeconds)
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        let readings = (try? context.fetch(descriptor)) ?? []
        guard !readings.isEmpty else { return [] }

        // Group by (roomName, serviceTypeRaw)
        let groups = Dictionary(
            grouping: readings,
            by: { "\($0.roomName)|\($0.serviceTypeRaw)" }
        )

        var signals: [AnomalySignal] = []
        for (_, group) in groups {
            guard group.count >= 4 else { continue }
            guard let first = group.first,
                  let sensorType = SensorServiceType(rawValue: first.serviceTypeRaw)
            else { continue }
            // Boolean-alert sensors are not evaluated for statistical anomalies
            guard !sensorType.isBooleanAlert else { continue }

            let roomName = first.roomName
            let sorted   = group.sorted { $0.timestamp < $1.timestamp }
            let values   = sorted.map(\.value)
            let valMin   = values.min() ?? 0
            let valMax   = values.max() ?? 0
            let valRange = valMax - valMin
            let mean     = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            let stddev   = sqrt(variance)
            let base     = "anomaly|\(roomName)|\(sensorType.rawValue)"

            // — Oscillation check —
            let relStddev = valRange > 0 ? stddev / valRange : 0
            if relStddev > oscillationRelStddev && valRange > oscillationMinRange {
                let score = IntelligenceScore(
                    relevance:     0.75,
                    confidence:    min(1.0, Double(group.count) / 6.0),
                    urgency:       0.55,
                    actionability: 0.70,
                    novelty:       0.85
                )
                signals.append(AnomalySignal(
                    kind:          .oscillating,
                    sensorType:    sensorType,
                    roomName:      roomName,
                    description:   String(format:
                        String(localized: "anomaly.oscillating.detail",
                               defaultValue: "Unstable readings ±%.1f%@ in the last 2h. The sensor may be faulty."),
                        stddev, sensorType.unit),
                    semanticKey:   "\(base)|oscillating",
                    score:         score,
                    numericDetail: stddev
                ))
            }

            // — Stuck sensor check —
            if let first = sorted.first, let last = sorted.last,
               last.timestamp.timeIntervalSince(first.timestamp) >= stuckDuration {
                let allSame = values.allSatisfy { abs($0 - values[0]) < 0.01 }
                if allSame {
                    let score = IntelligenceScore(
                        relevance: 0.80, confidence: 0.90,
                        urgency: 0.50, actionability: 0.85, novelty: 0.90
                    )
                    signals.append(AnomalySignal(
                        kind:          .stuck,
                        sensorType:    sensorType,
                        roomName:      roomName,
                        description:   String(format:
                            String(localized: "anomaly.stuck.detail",
                                   defaultValue: "Value unchanged (%.1f%@) for over 30 minutes. The sensor may be stuck."),
                            values[0], sensorType.unit),
                        semanticKey:   "\(base)|stuck",
                        score:         score,
                        numericDetail: values[0]
                    ))
                }
            }

            // — Out-of-range check —
            if let implausible = implausibleValue(for: sensorType, in: values) {
                let score = IntelligenceScore(
                    relevance: 0.90, confidence: 0.95,
                    urgency: 0.70, actionability: 0.90, novelty: 0.95
                )
                signals.append(AnomalySignal(
                    kind:          .outOfRange,
                    sensorType:    sensorType,
                    roomName:      roomName,
                    description:   String(format:
                        String(localized: "anomaly.outofrange.detail",
                               defaultValue: "Anomalous value detected (%.1f%@) — impossible under normal conditions."),
                        implausible, sensorType.unit),
                    semanticKey:   "\(base)|outofrange",
                    score:         score,
                    numericDetail: implausible
                ))
            }
        }
        return signals
    }

    // MARK: - Helpers

    private static func implausibleValue(for type: SensorServiceType, in values: [Double]) -> Double? {
        let range: ClosedRange<Double>? = {
            switch type {
            case .temperature:    return -20.0...60.0
            case .humidity:       return 0.0...100.0
            case .carbonDioxide:  return 300.0...10000.0
            case .carbonMonoxide: return 0.0...1000.0
            case .vocDensity:     return 0.0...10000.0
            default:              return nil
            }
        }()
        guard let r = range else { return nil }
        return values.first { !r.contains($0) }
    }
}
