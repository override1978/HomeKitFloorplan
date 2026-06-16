import Foundation

// MARK: - LightingPhase

enum LightingPhase: String, Codable, CaseIterable {
    case dawn       // alba:        sunrise-60' → sunrise+90'
    case morning    // mattino:     sunrise+90' → sunset-120'
    case preSunset  // pre-tramonto: sunset-120' → sunset-30'
    case sunset     // tramonto:    sunset-30'  → sunset+45'
    case evening    // sera:        sunset+45'  → nightHour
    case night      // notte:       nightHour   → sunrise-60'

    var displayName: String {
        switch self {
        case .dawn:      return "Alba"
        case .morning:   return "Mattino"
        case .preSunset: return "Pre-tramonto"
        case .sunset:    return "Tramonto"
        case .evening:   return "Sera"
        case .night:     return "Notte"
        }
    }
}

// MARK: - LightingProfile

/// Configurazione di Auto Lighting per una singola stanza HomeKit.
/// Persistito in UserDefaults come JSON — nessuna modifica allo schema SwiftData.
struct LightingProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var roomName: String                    // nome stanza HomeKit (corrisponde a HMRoom.name)
    var isEnabled: Bool = false

    // Lux bypass: se la luminosità ambientale supera questa soglia, l'engine non agisce.
    // 0 = bypass disabilitato (nessun sensore lux in stanza).
    var luxBypassThreshold: Double = 150.0
    var luxSensorRoomName: String?          // stanza del sensore lux, se diversa dalla target

    // Ora (0-23) in cui la fase "sera" diventa "notte" — per-profilo perché ogni stanza
    // può avere un orario di spegnimento diverso (es. camera 22, living 24).
    var nightHour: Int = 23

    // Ora (0-23) in cui l'engine tace del tutto per questa stanza durante la notte.
    // nil = nessun limite (l'engine resta attivo fino al sunrise).
    // Gestisce il crossing di mezzanotte: se sleepHour < nightHour (es. 1 < 23),
    // il silenzio scatta nelle prime ore del mattino (01:00-22:59).
    var sleepHour: Int? = nil

    // Ora (0-23) prima della quale l'engine non attiva alcuna scena (incluse alba/mattino).
    // nil = nessun vincolo (l'engine parte già dalla fase alba).
    // Evita che l'alba accenda le luci prima del risveglio dell'utente.
    var wakeHour: Int? = nil

    // Nomi delle scene HomeKit da attivare per ogni fase (nil = skip questa fase).
    var sceneDawn: String?
    var sceneMorning: String?
    var scenePreSunset: String?
    var sceneSunset: String?
    var sceneEvening: String?
    var sceneNight: String?

    // Override manuale: se impostato e ancora nel futuro, l'engine salta questa stanza.
    var manualOverrideUntil: Date?

    // Dedup interno: evita di riapplicare la stessa scena nel cooldown di 20 min.
    var lastAppliedPhase: String?
    var lastAppliedAt: Date?

    // MARK: - Helpers

    func sceneName(for phase: LightingPhase) -> String? {
        switch phase {
        case .dawn:      return sceneDawn
        case .morning:   return sceneMorning
        case .preSunset: return scenePreSunset
        case .sunset:    return sceneSunset
        case .evening:   return sceneEvening
        case .night:     return sceneNight
        }
    }

    /// Restituisce un riepilogo leggibile della configurazione per l'AI e la UI.
    var summary: String {
        var parts: [String] = ["Stanza: \(roomName)", "Abilitato: \(isEnabled ? "sì" : "no")"]
        if luxBypassThreshold > 0 { parts.append("Bypass lux: >\(Int(luxBypassThreshold)) lx") }
        parts.append("Orario notte: \(nightHour):00")
        if let sh = sleepHour { parts.append("Sleep hour: \(sh):00 (engine silenzioso dopo)") }
        if let wh = wakeHour  { parts.append("Wake hour: \(wh):00 (engine attivo da)") }
        for phase in LightingPhase.allCases {
            if let s = sceneName(for: phase) { parts.append("\(phase.displayName): \(s)") }
        }
        if let until = manualOverrideUntil, until > Date() {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            parts.append("Override manuale fino alle \(f.string(from: until))")
        }
        return parts.joined(separator: "\n")
    }
}
