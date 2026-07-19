import Foundation

/// Pivot del motore Abitudini: "da giudice a testimone".
///
/// Invece di decidere statisticamente cosa è un'abitudine (gate di confidenza
/// che con dati domestici sparsi non promuovevano mai nulla), questo builder
/// estrae EVIDENZE d'uso leggibili — "acceso tra 19:15 e 20:00, nei feriali,
/// 11 volte in 14 giorni" — e lascia il giudizio all'utente, che con un tap
/// crea l'automazione via `AutomationProposalMapper`.
///
/// Puro e deterministico: nessuna dipendenza da SwiftData/HomeKit.
enum UsageEvidenceBuilder {

    /// Campione evento disaccoppiato da SwiftData.
    struct EventSample {
        let accessoryID: UUID
        let accessoryName: String
        let roomName: String?
        let eventType: String
        let state: Bool
        let timestamp: Date

        init(accessoryID: UUID, accessoryName: String, roomName: String?,
             eventType: String, state: Bool, timestamp: Date) {
            self.accessoryID = accessoryID
            self.accessoryName = accessoryName
            self.roomName = roomName
            self.eventType = eventType
            self.state = state
            self.timestamp = timestamp
        }
    }

    enum WeekdayPattern: Equatable {
        case everyDay
        case weekdays      // lun–ven
        case weekend       // sab–dom
        case days(Set<Int>) // weekday Calendar (1=dom ... 7=sab)
    }

    struct Evidence: Identifiable, Equatable {
        let id: String                 // stabile: accessorio+tipo+finestra
        let accessoryID: UUID
        let accessoryName: String
        let roomName: String?
        let eventType: String
        /// Minuti da mezzanotte (inizio/fine finestra).
        let windowStartMinute: Int
        let windowEndMinute: Int
        let weekdayPattern: WeekdayPattern
        /// Eventi totali caduti nella finestra.
        let occurrences: Int
        /// Giorni DISTINTI con almeno un evento — la vera forza dell'evidenza.
        let distinctDays: Int
        /// Giorni coperti dal periodo osservato.
        let observedSpanDays: Int
    }

    struct Configuration {
        /// Ampiezza della finestra oraria (minuti).
        var windowMinutes: Int = 60
        /// Passo di scorrimento della finestra (minuti).
        var stepMinutes: Int = 15
        /// Giorni distinti minimi perché l'evidenza sia mostrabile.
        var minDistinctDays: Int = 4
        /// Quota per classificare feriali/weekend (es. 0.9 = 90%).
        var weekdayDominance: Double = 0.9
        /// Solo accessori AZIONABILI: un'evidenza "accendi" su un sensore
        /// contatto/movimento non è automatizzabile (feedback device: finestre
        /// proposte nel builder senza accessorio da controllare).
        var allowedEventTypes: Set<String> = [
            "light", "switch", "outlet", "fan", "thermostat", "airPurifier", "humidifier"
        ]
        /// Eventi di almeno N accessori DISTINTI nello stesso minuto = attività
        /// sincronizzata (scena/automazione/sistema), non abitudine umana:
        /// quei timestamp vengono esclusi (feedback device: tutte le evidenze
        /// identiche alle 23:00 per 6 accessori diversi).
        var bulkAccessoryThreshold: Int = 4

        init() {}
    }

    /// Estrae le evidenze dalle accensioni (`state == true`), ordinate per forza.
    static func build(from events: [EventSample],
                      configuration: Configuration = Configuration(),
                      calendar: Calendar = .current) -> [Evidence] {
        var onEvents = events.filter { event in
            event.state &&
            (configuration.allowedEventTypes.isEmpty
                || configuration.allowedEventTypes.contains(event.eventType))
        }

        // Filtro anti-scena: minuti in cui scattano ≥ soglia accessori distinti
        // sono attività sincronizzata di sistema, non gesti umani.
        if configuration.bulkAccessoryThreshold > 0 {
            var accessoriesByMinute: [Int: Set<UUID>] = [:]
            for event in onEvents {
                let bucket = Int(event.timestamp.timeIntervalSince1970 / 60)
                accessoriesByMinute[bucket, default: []].insert(event.accessoryID)
            }
            let bulkMinutes = Set(accessoriesByMinute.filter {
                $0.value.count >= configuration.bulkAccessoryThreshold
            }.keys)
            if !bulkMinutes.isEmpty {
                onEvents.removeAll {
                    bulkMinutes.contains(Int($0.timestamp.timeIntervalSince1970 / 60))
                }
            }
        }

        guard !onEvents.isEmpty else { return [] }

        let grouped = Dictionary(grouping: onEvents) { "\($0.accessoryID.uuidString)|\($0.eventType)" }
        var results: [Evidence] = []

        for (_, group) in grouped {
            guard let sample = group.first else { continue }

            let stamps: [(minute: Int, day: Date, weekday: Int)] = group.map { e in
                let comps = calendar.dateComponents([.hour, .minute, .weekday], from: e.timestamp)
                return ((comps.hour ?? 0) * 60 + (comps.minute ?? 0),
                        calendar.startOfDay(for: e.timestamp),
                        comps.weekday ?? 1)
            }

            let spanDays = observedSpan(of: group.map(\.timestamp), calendar: calendar)

            // Finestra scorrevole sulle 24h (wrap oltre mezzanotte ignorato:
            // le routine notturne a cavallo sono rare e complicano la lettura).
            var best: Evidence?
            var start = 0
            while start + configuration.windowMinutes <= 24 * 60 {
                let end = start + configuration.windowMinutes
                let inWindow = stamps.filter { $0.minute >= start && $0.minute < end }
                let days = Set(inWindow.map(\.day))

                if days.count >= configuration.minDistinctDays,
                   days.count > (best?.distinctDays ?? 0) ||
                    (days.count == (best?.distinctDays ?? 0) && inWindow.count > (best?.occurrences ?? 0)) {
                    best = Evidence(
                        id: "\(sample.accessoryID.uuidString)|\(sample.eventType)|\(start)",
                        accessoryID: sample.accessoryID,
                        accessoryName: sample.accessoryName,
                        roomName: sample.roomName,
                        eventType: sample.eventType,
                        windowStartMinute: start,
                        windowEndMinute: end,
                        weekdayPattern: pattern(
                            weekdays: inWindow.map(\.weekday),
                            dominance: configuration.weekdayDominance
                        ),
                        occurrences: inWindow.count,
                        distinctDays: days.count,
                        observedSpanDays: spanDays
                    )
                }
                start += configuration.stepMinutes
            }

            if let best { results.append(best) }
        }

        return results.sorted {
            if $0.distinctDays != $1.distinctDays { return $0.distinctDays > $1.distinctDays }
            return $0.accessoryName < $1.accessoryName
        }
    }

    // MARK: - Private

    private static func observedSpan(of dates: [Date], calendar: Calendar) -> Int {
        guard let first = dates.min(), let last = dates.max() else { return 0 }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: first),
                                           to: calendar.startOfDay(for: last)).day ?? 0
        return days + 1
    }

    private static func pattern(weekdays: [Int], dominance: Double) -> WeekdayPattern {
        guard !weekdays.isEmpty else { return .everyDay }
        let total = Double(weekdays.count)
        let weekendSet: Set<Int> = [1, 7] // dom, sab (Calendar: 1=domenica)
        let weekendCount = Double(weekdays.filter { weekendSet.contains($0) }.count)
        let weekdayCount = total - weekendCount

        if weekdayCount / total >= dominance { return .weekdays }
        if weekendCount / total >= dominance { return .weekend }

        let distinct = Set(weekdays)
        if distinct.count <= 3 { return .days(distinct) }
        return .everyDay
    }
}
