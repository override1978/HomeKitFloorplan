import Foundation
import SwiftData

// MARK: - EnergyUsageTracker

/// Computes per-accessory energy usage records from raw AccessoryEvent history.
///
/// Algorithm:
///   1. Fetch AccessoryEvents for the last 7 days.
///   2. Group events by accessoryID, sorted chronologically.
///   3. For each accessory, pair consecutive ON→OFF events into sessions.
///      An open ON event (no subsequent OFF) counts as an ongoing session ending now.
///   4. Compute overlap with the 24h and 7d windows using interval arithmetic.
///
/// Pure computation — no side effects, no stored state.
enum EnergyUsageTracker {

    private static let lookbackDays: Double = 7

    // MARK: - Public API

    /// Fetches AccessoryEvents from the model container and returns one record per accessory.
    /// Records are sorted by totalHoursToday descending (highest consumers first).
    static func analyze(modelContainer: ModelContainer) async -> [EnergyUsageRecord] {
        let context = ModelContext(modelContainer)
        let now     = Date()
        let cutoff  = now.addingTimeInterval(-lookbackDays * 24 * 3600)

        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        let events = (try? context.fetch(descriptor)) ?? []
        guard !events.isEmpty else { return [] }

        return buildRecords(from: events, now: now, weekStart: cutoff)
    }

    // MARK: - Private

    private static func buildRecords(
        from events: [AccessoryEvent],
        now: Date,
        weekStart: Date
    ) -> [EnergyUsageRecord] {

        let todayStart = now.addingTimeInterval(-24 * 3600)

        // Group events by accessory, preserving chronological order (already sorted from fetch)
        var grouped: [UUID: [AccessoryEvent]] = [:]
        for event in events {
            grouped[event.accessoryID, default: []].append(event)
        }

        var records: [EnergyUsageRecord] = []

        for (accID, accEvents) in grouped {
            guard let first = accEvents.first else { continue }
            let sorted = accEvents.sorted { $0.timestamp < $1.timestamp }

            // Build sessions: pair ON→OFF events
            var sessions: [(start: Date, end: Date)] = []
            var currentStart: Date? = nil

            for event in sorted {
                if event.state {
                    // ON: start (or restart) a session — discard any unmatched previous ON
                    currentStart = event.timestamp
                } else if let start = currentStart {
                    // OFF: close the open session
                    sessions.append((start: start, end: event.timestamp))
                    currentStart = nil
                }
            }

            // Determine if currently on, and record the open session start
            let isOn        = sorted.last?.state ?? false
            let openStart   = isOn ? currentStart : nil
            if let start = openStart {
                sessions.append((start: start, end: now))
            }

            // Compute overlapping hours in each window
            let hoursToday = hoursOverlapping(sessions, from: todayStart, to: now)
            let hoursWeek  = hoursOverlapping(sessions, from: weekStart, to: now)
            let longest    = sessions.map { $0.end.timeIntervalSince($0.start) / 3600 }.max() ?? 0

            let todayCount = sessions.filter { $0.start >= todayStart || $0.end > todayStart }.count

            records.append(EnergyUsageRecord(
                id:                  UUID(),
                accessoryID:         accID,
                accessoryName:       first.accessoryName,
                roomName:            first.roomName ?? "",
                eventType:           first.eventType,
                totalHoursToday:     hoursToday,
                totalHoursWeek:      hoursWeek,
                longestSessionHours: longest,
                sessionCountToday:   todayCount,
                isCurrentlyOn:       isOn,
                currentSessionStart: openStart
            ))
        }

        return records.sorted { $0.totalHoursToday > $1.totalHoursToday }
    }

    /// Computes total hours of overlap between `sessions` and the closed interval [from, to].
    private static func hoursOverlapping(
        _ sessions: [(start: Date, end: Date)],
        from windowStart: Date,
        to windowEnd: Date
    ) -> Double {
        sessions.reduce(0.0) { acc, session in
            let overlapStart = max(session.start, windowStart)
            let overlapEnd   = min(session.end,   windowEnd)
            return acc + max(0, overlapEnd.timeIntervalSince(overlapStart)) / 3600
        }
    }
}
