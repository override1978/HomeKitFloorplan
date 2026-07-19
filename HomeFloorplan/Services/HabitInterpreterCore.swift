import Foundation

/// Core puro del livello B del pivot Abitudini: l'interprete LLM.
///
/// La statistica rigida non funziona sui dati domestici sfumati; qui i ruoli
/// si invertono — il codice PREPARA un riassunto compatto dell'uso reale
/// (istogrammi orari + sequenze accessorio→accessorio) e il modello lo LEGGE
/// proponendo routine, che l'utente giudica nel wizard esistente.
/// Questo file è deterministico e testabile: niente rete, niente SwiftData.
enum HabitInterpreterCore {

    /// Proposta di routine come la restituisce il modello (JSON).
    struct RoutineSuggestion: Codable, Equatable, Identifiable {
        var id: String { "\(targetAccessoryName)|\(triggerType)|\(triggerTime ?? triggerAccessoryName ?? "")" }
        let title: String
        let explanation: String
        /// "calendar" (orario) oppure "accessoryState" (sequenza A→B).
        let triggerType: String
        /// "HH:mm" — solo per triggerType == "calendar".
        let triggerTime: String?
        /// 1=dom ... 7=sab — solo per calendar; nil = tutti i giorni.
        let weekdays: [Int]?
        /// Nome dell'accessorio causa — solo per triggerType == "accessoryState".
        let triggerAccessoryName: String?
        let targetAccessoryName: String
        /// Altri accessori con lo stesso pattern (es. luci della stessa stanza):
        /// UNA proposta con più azioni invece di n proposte fotocopia.
        let additionalTargetNames: [String]?
        /// "on" | "off".
        let action: String
        /// "sunrise" | "sunset" | nil — per routine legate alla luce naturale
        /// (con triggerType "calendar"; ha precedenza sull'orario fisso).
        let scheduleKind: String?
    }

    // MARK: - Riassunto per il prompt

    /// Riassunto compatto e leggibile dell'uso: una riga per accessorio con
    /// istogramma orario delle accensioni, più le sequenze A→B frequenti.
    /// `preferExternal`: se esistono eventi flaggati "external", usa solo quelli.
    static func buildUsageSummary(events: [UsageEvidenceBuilder.EventSample],
                                  existingAutomations: [String],
                                  maxAccessories: Int = 25,
                                  calendar: Calendar = .current) -> String {
        let external = events.filter { $0.origin == "external" }
        let pool = external.isEmpty ? events : external

        // Igiene: solo accessori AZIONABILI (motion/contact = rumore).
        let actionableTypes: Set<String> = [
            "light", "switch", "outlet", "fan", "thermostat",
            "airPurifier", "humidifier", "blind"
        ]
        let onEvents = pool.filter { $0.state && actionableTypes.contains($0.eventType) }

        // GAP ANALYSIS: in una casa già automatizzata il segnale interessante
        // sono i GESTI MANUALI RESIDUI — i buchi del tessuto di automazioni.
        // L'attività di scena (≥4 accessori nello stesso minuto) non viene
        // scartata ma ETICHETTATA, così il modello sa cosa la casa fa già.
        var minuteAccessories: [Int: Set<UUID>] = [:]
        var minuteNames: [Int: Set<String>] = [:]
        for e in onEvents {
            let m = Int(e.timestamp.timeIntervalSince1970 / 60)
            minuteAccessories[m, default: []].insert(e.accessoryID)
            minuteNames[m, default: []].insert(e.accessoryName)
        }
        let bulkMinutes = Set(minuteAccessories.filter { $0.value.count >= 4 }.keys)
        let manualEvents = onEvents.filter {
            !bulkMinutes.contains(Int($0.timestamp.timeIntervalSince1970 / 60))
        }

        var lines: [String] = []
        lines.append("RESIDUAL MANUAL ACTIONS (the automation gaps):")

        // Istogrammi orari per accessorio + contesto post-scena.
        let byAccessory = Dictionary(grouping: manualEvents) { $0.accessoryID }
        let ranked = byAccessory.values
            .sorted { $0.count > $1.count }
            .prefix(maxAccessories)

        for group in ranked {
            guard let first = group.first else { continue }
            var hourCounts: [Int: Int] = [:]
            var afterGroup = 0
            for e in group {
                let h = calendar.component(.hour, from: e.timestamp)
                hourCounts[h, default: 0] += 1
                let m = Int(e.timestamp.timeIntervalSince1970 / 60)
                if (1...5).contains(where: { bulkMinutes.contains(m - $0) }) {
                    afterGroup += 1
                }
            }
            let histogram = hourCounts.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: " ")
            let room = first.roomName.map { " (\($0))" } ?? ""
            var line = "\(first.accessoryName)\(room) [\(first.eventType)] on×\(group.count) — h \(histogram)"
            if afterGroup > 0 {
                line += " — \(afterGroup) within 5min AFTER an automated group"
            }
            lines.append(line)
        }

        // Sequenze manuali A→B: accensioni di B entro 120s da un'accensione di A.
        var pairCounts: [String: Int] = [:]
        let sorted = manualEvents.sorted { $0.timestamp < $1.timestamp }
        for (i, a) in sorted.enumerated() {
            var j = i + 1
            while j < sorted.count,
                  sorted[j].timestamp.timeIntervalSince(a.timestamp) <= 120 {
                let b = sorted[j]
                if b.accessoryID != a.accessoryID {
                    pairCounts["\(a.accessoryName) -> \(b.accessoryName)", default: 0] += 1
                }
                j += 1
            }
        }
        let topPairs = pairCounts.filter { $0.value >= 3 }
            .sorted { $0.value > $1.value }
            .prefix(12)
        if !topPairs.isEmpty {
            lines.append("SEQUENCES (B on within 2min of A):")
            for (pair, count) in topPairs {
                lines.append("\(pair) ×\(count)")
            }
        }

        // Gruppi automatizzati già attivi: contesto compresso per fascia oraria,
        // così il modello NON li ripropone e può agganciarci i gesti residui.
        if !bulkMinutes.isEmpty {
            lines.append("AUTOMATED GROUPS already firing (4+ accessories together — do NOT re-propose):")
            struct HourGroup { var days = Set<Date>(); var names = Set<String>() }
            var byHour: [Int: HourGroup] = [:]
            for m in bulkMinutes {
                let date = Date(timeIntervalSince1970: Double(m) * 60)
                let h = calendar.component(.hour, from: date)
                var g = byHour[h] ?? HourGroup()
                g.days.insert(calendar.startOfDay(for: date))
                g.names.formUnion(minuteNames[m] ?? [])
                byHour[h] = g
            }
            for (h, g) in byHour.sorted(by: { $0.value.days.count > $1.value.days.count }).prefix(8) {
                let names = g.names.sorted().prefix(5).joined(separator: ", ")
                let extra = g.names.count > 5 ? " +\(g.names.count - 5)" : ""
                lines.append("h\(h) ×\(g.days.count)days: \(names)\(extra)")
            }
        }

        if !existingAutomations.isEmpty {
            lines.append("EXISTING AUTOMATIONS (do not duplicate):")
            lines.append(contentsOf: existingAutomations.prefix(20))
        }

        return lines.joined(separator: "\n")
    }

    /// System prompt: contratto JSON stretto, poche proposte, solo evidenza forte.
    static var systemPrompt: String {
        """
        You analyze a smart home that is ALREADY heavily automated. The valuable signal is the \
        RESIDUAL MANUAL ACTIONS: what the user still does by hand marks the GAPS in their \
        automation fabric. Input: residual manual actions (hourly ON histograms, with a note when \
        they happen right after an automated group fires), manual A -> B sequences, the automated \
        groups already firing, and existing automations.
        Propose AT MOST 3 automations that CLOSE a gap: a device regularly switched on manually \
        right after an automated group should be triggered by one of that group's accessories \
        ("accessoryState") or by the same schedule; a recurring manual evening light suggests a \
        sunset trigger. NEVER re-propose what the automated groups or existing automations \
        already cover. Skip anything ambiguous.
        GROUP, never repeat: if several devices share the same pattern (typically same room, \
        same hours), emit ONE proposal — primary device in targetAccessoryName, the others in \
        additionalTargetNames. NEVER emit two proposals with the same trigger or overlapping targets.
        PREFER "accessoryState" (A turns on -> B) whenever a SEQUENCE or after-group note \
        supports it: sequence triggers survive schedule changes, fixed times do not. \
        Use "scheduleKind" sunset/sunrise for routines that track daylight (evening lights). \
        Reply ONLY with a JSON array (no prose, no code fences) of objects:
        {"title": string, "explanation": string (mention the observed evidence), \
        "triggerType": "calendar"|"accessoryState", "triggerTime": "HH:mm" or null, \
        "weekdays": [1-7] or null (1=Sunday), "triggerAccessoryName": string or null, \
        "targetAccessoryName": string, "additionalTargetNames": [string] or null, \
        "action": "on"|"off", "scheduleKind": "sunrise"|"sunset" or null}
        Empty array [] if nothing is clearly supported.
        """
    }

    // MARK: - Parsing risposta

    /// Parsing tollerante: estrae il primo array JSON anche se il modello
    /// aggiunge testo o code fence attorno.
    static func parseSuggestions(_ response: String) -> [RoutineSuggestion] {
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start < end else { return [] }
        let json = String(response[start...end])
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([RoutineSuggestion].self, from: data) else {
            return []
        }
        return parsed.filter { suggestion in
            (suggestion.action == "on" || suggestion.action == "off") &&
            (suggestion.triggerType == "calendar" || suggestion.triggerType == "accessoryState") &&
            !suggestion.targetAccessoryName.isEmpty
        }
    }
}
