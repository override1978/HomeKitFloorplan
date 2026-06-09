import Foundation
import SwiftData
import Observation

// MARK: - MaintenanceSignal

struct MaintenanceSignal {
    enum Kind {
        case suddenDropInUsage   // historically active accessory went silent
        case highChurn           // abnormally frequent on/off cycling = wear
    }
    let kind:           Kind
    let accessoryName:  String
    let accessoryID:    UUID
    let roomName:       String
    let detail:         String
    let semanticKey:    String
    let score:          IntelligenceScore
}

// MARK: - MaintenancePredictionService

/// Analyzes AccessoryUsageSummary history to detect maintenance-relevant anomalies.
///
/// Detection heuristics:
///   1. Sudden drop in usage — accessory historically active but near-zero in recent 2 weeks.
///      May indicate hardware failure, disconnection, or changed habits.
///   2. High churn — accessory cycling on/off ≥ 100× in a week, suggesting unusual wear.
///
/// This service never acts — it produces signals for ProactiveIntelligenceService to surface.
@Observable
@MainActor
final class MaintenancePredictionService {

    // MARK: - State

    var signals:       [MaintenanceSignal] = []
    var lastAnalyzedAt: Date?

    // MARK: - Constants

    /// Minimum historical weekly on-count to be considered "active".
    private static let minHistoricalOnCount: Int = 8
    /// Maximum recent weekly on-count to trigger a dropout signal.
    private static let dropOutOnCountMax:   Int = 2
    /// Minimum weekly on/off cycles to trigger a high-churn signal.
    private static let highChurnCycles:     Int = 100
    /// Lookback window (12 weeks).
    private static let lookbackDays:        Int = 84

    // MARK: - Private

    private let modelContainer: ModelContainer

    // MARK: - Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    // MARK: - Analysis

    func analyze() async {
        let context = ModelContext(modelContainer)
        let cutoff  = Date().addingTimeInterval(-Double(Self.lookbackDays) * 24 * 3600)
        let descriptor = FetchDescriptor<AccessoryUsageSummary>(
            predicate: #Predicate { $0.weekStartDate >= cutoff },
            sortBy:    [SortDescriptor(\.weekStartDate)]
        )
        let summaries = (try? context.fetch(descriptor)) ?? []
        guard !summaries.isEmpty else { return }

        let grouped = Dictionary(grouping: summaries, by: \.accessoryID)
        var newSignals: [MaintenanceSignal] = []

        for (accID, weeks) in grouped {
            let sorted = weeks.sorted { $0.weekStartDate < $1.weekStartDate }
            guard sorted.count >= 4, let latest = sorted.last else { continue }

            let historical    = sorted.dropLast(2)
            let avgOnCount    = historical.map(\.onCount).reduce(0, +) / max(1, historical.count)
            let recentAvgOn   = sorted.suffix(2).map(\.onCount).reduce(0, +) / 2

            // Signal 1: Sudden dropout
            if avgOnCount >= Self.minHistoricalOnCount && recentAvgOn <= Self.dropOutOnCountMax {
                let confidence = min(1.0, Double(sorted.count) / 8.0)
                let score = IntelligenceScore(
                    relevance: 0.80, confidence: confidence,
                    urgency: 0.60, actionability: 0.90, novelty: 0.80
                )
                newSignals.append(MaintenanceSignal(
                    kind:          .suddenDropInUsage,
                    accessoryName: latest.accessoryName,
                    accessoryID:   accID,
                    roomName:      latest.roomName,
                    detail:        String(format:
                        String(localized: "maintenance.dropout.detail",
                               defaultValue: "Media storica: %d att./settimana. Ultime 2 settimane: ~%d att."),
                        avgOnCount, recentAvgOn),
                    semanticKey: "maintenance|dropout|\(accID.uuidString)",
                    score: score
                ))
            }

            // Signal 2: High churn (on + off events in most recent week)
            let latestCycles = min(latest.onCount, latest.offCount)
            if latestCycles >= Self.highChurnCycles {
                let score = IntelligenceScore(
                    relevance: 0.65, confidence: 0.80,
                    urgency: 0.45, actionability: 0.75, novelty: 0.70
                )
                newSignals.append(MaintenanceSignal(
                    kind:          .highChurn,
                    accessoryName: latest.accessoryName,
                    accessoryID:   accID,
                    roomName:      latest.roomName,
                    detail:        String(format:
                        String(localized: "maintenance.churn.detail",
                               defaultValue: "%d cicli on/off questa settimana — consumo elevato."),
                        latestCycles),
                    semanticKey: "maintenance|churn|\(accID.uuidString)",
                    score: score
                ))
            }
        }

        signals        = newSignals
        lastAnalyzedAt = Date()
    }
}
