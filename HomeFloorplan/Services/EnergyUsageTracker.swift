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
    ///
    /// - Parameter currentStates: mappa opzionale `accessoryID → isCurrentlyOn` letta da HomeKit
    ///   in real-time. Usata per riconciliare la storia degli eventi con lo stato reale:
    ///   • HomeKit OFF ma storia ON → sessione aperta cappata a 24h (evento OFF perso)
    ///   • HomeKit ON ma storia OFF → sessione sintetica da "adesso" (evento ON perso)
    static func analyze(modelContainer: ModelContainer,
                        currentStates: [UUID: Bool] = [:]) async -> [EnergyUsageRecord] {
        let context = ModelContext(modelContainer)
        let now     = Date()
        let cutoff  = now.addingTimeInterval(-lookbackDays * 24 * 3600)

        let descriptor = FetchDescriptor<AccessoryEvent>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        let events = (try? context.fetch(descriptor)) ?? []
        guard !events.isEmpty else { return [] }

        return buildRecords(from: events, now: now, weekStart: cutoff, currentStates: currentStates)
    }

    // MARK: - Private

    /// Cap per sessioni aperte senza evento OFF: evita sessioni fantoma di giorni interi
    /// quando l'app perdeva gli eventi (era in background o l'accessorio non era osservato).
    private static let openSessionCap: TimeInterval = 24 * 3600

    private static func buildRecords(
        from events: [AccessoryEvent],
        now: Date,
        weekStart: Date,
        currentStates: [UUID: Bool] = [:]
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

            // Determina stato corrente dagli eventi storici
            let lastEventIsOn = sorted.last?.state ?? false
            var isOn          = lastEventIsOn
            var openStart: Date? = lastEventIsOn ? currentStart : nil

            // Riconcilia con lo stato real-time di HomeKit (se disponibile)
            if let realState = currentStates[accID] {
                if realState && !isOn {
                    // HomeKit: ON, eventi: OFF → evento ON perso — sessione sintetica da "adesso"
                    isOn      = true
                    openStart = now
                } else if !realState && isOn, let start = openStart {
                    // HomeKit: OFF, eventi: ON → evento OFF perso — cappa la sessione a 24h max
                    sessions.append((start: start, end: min(now, start.addingTimeInterval(openSessionCap))))
                    isOn      = false
                    openStart = nil
                }
            }

            // Aggiunge la sessione aperta (accessorio ancora acceso)
            if let start = openStart {
                sessions.append((start: start, end: now))
            }

            // Compute overlapping hours in each window
            let hoursToday = hoursOverlapping(sessions, from: todayStart, to: now)
            let hoursWeek  = hoursOverlapping(sessions, from: weekStart, to: now)
            let longest    = sessions.map { $0.end.timeIntervalSince($0.start) / 3600 }.max() ?? 0

            let todayCount  = sessions.filter { $0.start >= todayStart || $0.end > todayStart }.count
            let activeDays  = distinctActiveDays(sessions: sessions, windowStart: weekStart, windowEnd: now)

            records.append(EnergyUsageRecord(
                id:                  UUID(),
                accessoryID:         accID,
                accessoryName:       first.accessoryName,
                roomName:            first.roomName ?? "",
                eventType:           first.eventType,
                totalHoursToday:     hoursToday,
                totalHoursWeek:      hoursWeek,
                activeDaysInWindow:  activeDays,
                longestSessionHours: longest,
                sessionCountToday:   todayCount,
                isCurrentlyOn:       isOn,
                currentSessionStart: openStart
            ))

        }

        return records.sorted { $0.totalHoursToday > $1.totalHoursToday }
    }

    /// Returns the number of distinct calendar days (in the device's local timezone) touched by
    /// at least one session within [windowStart, windowEnd].
    private static func distinctActiveDays(
        sessions: [(start: Date, end: Date)],
        windowStart: Date,
        windowEnd: Date
    ) -> Int {
        let calendar = Calendar.current
        var daySet = Set<Int>()
        for session in sessions {
            let clampedStart = max(session.start, windowStart)
            let clampedEnd   = min(session.end,   windowEnd)
            guard clampedEnd > clampedStart else { continue }
            var cursor = clampedStart
            while cursor < clampedEnd {
                if let ord = calendar.ordinality(of: .day, in: .era, for: cursor) {
                    daySet.insert(ord)
                }
                guard let nextDay = calendar.nextDate(
                    after: cursor,
                    matching: DateComponents(hour: 0, minute: 0, second: 0),
                    matchingPolicy: .nextTime
                ) else { break }
                cursor = nextDay
            }
        }
        return daySet.count
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
