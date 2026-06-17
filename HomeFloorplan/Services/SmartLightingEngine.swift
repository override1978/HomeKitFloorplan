import Foundation
import HomeKit
import Observation

// MARK: - SmartLightingEngine
//
// Valuta periodicamente le condizioni di luce per ogni stanza configurata e
// attiva la scena HomeKit appropriata in base a:
//   1. Luminosità ambientale (lux sensor, se disponibile)
//   2. Fase del giorno relativa a sunrise/sunset (WeatherKit)
//   3. Override manuale e cooldown per-fase
//
// Viene chiamato dal foreground loop (~5 min) e dal BGTask di valutazione regole.
// Il cooldown interno di 20 min per fase evita ridondanza.

@Observable
@MainActor
final class SmartLightingEngine {

    // MARK: - State

    var profiles: [LightingProfile] = []
    var lastEvaluationAt: Date?
    var lastEvaluationLog: String = "Mai valutato"

    /// Traccia quando il motore ha attivato una scena per profilo (in-memory, reset al rilancio).
    /// Usato per spegnere le luci quando il lux risale sopra soglia dopo il cooldown.
    private var engineActivatedAt: [UUID: Date] = [:]

    var isGloballyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "smartLighting.globalEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "smartLighting.globalEnabled") }
    }

    // MARK: - Dependencies

    private let homeKit: HomeKitService
    private let weatherKit: WeatherKitService
    private let scenesService: HomeKitScenesService

    // MARK: - Init

    init(homeKit: HomeKitService, weatherKit: WeatherKitService, scenesService: HomeKitScenesService) {
        self.homeKit       = homeKit
        self.weatherKit    = weatherKit
        self.scenesService = scenesService
        loadProfiles()
    }

    // MARK: - Evaluate

    /// Punto di ingresso principale. Chiamato periodicamente dal foreground loop e dal BGTask.
    func evaluate() async {
        guard isGloballyEnabled else {
            let n = profiles.filter(\.isEnabled).count
            lastEvaluationLog = n > 0
                ? "Smart Lighting disabilitato — \(n) stanz\(n == 1 ? "a" : "e") configurata\(n == 1 ? "" : "e") in attesa"
                : "Smart Lighting disabilitato globalmente"
            return
        }
        guard let home = homeKit.currentHome else {
            lastEvaluationLog = "Casa HomeKit non disponibile"
            return
        }

        let now = Date()
        let globalPhase = currentPhase(at: now)
        var log: [String] = ["[\(timeString(now))] Fase globale: \(globalPhase.displayName)"]
        if let sr = weatherKit.todaySunrise, let ss = weatherKit.todaySunset {
            log.append("  Sunrise \(timeString(sr)) · Sunset \(timeString(ss))")
        }

        scenesService.refresh()
        let availableScenes = scenesService.scenes

        for i in 0..<profiles.count where profiles[i].isEnabled {
            let profile = profiles[i]

            // Override manuale: l'utente ha disabilitato questa stanza temporaneamente
            if let overrideUntil = profile.manualOverrideUntil, now < overrideUntil {
                log.append("• \(profile.roomName): override manuale attivo fino alle \(timeString(overrideUntil))")
                continue
            }

            // Wake hour: nessuna scena (incluse alba/mattino) prima dell'ora di risveglio
            if let wakeH = profile.wakeHour {
                let h = Calendar.current.component(.hour, from: now)
                if h < wakeH {
                    log.append("• \(profile.roomName): wake hour (\(String(format: "%02d", wakeH)):00) — engine silenzioso")
                    continue
                }
            }

            // Lux bypass: se c'è ancora abbastanza luce naturale, non fare nulla.
            // Se il motore aveva acceso le luci e il cooldown (20 min) è scaduto,
            // attiva la scena off configurata (se presente).
            if profile.luxBypassThreshold > 0 {
                if let lux = readLux(for: profile, in: home) {
                    if lux > profile.luxBypassThreshold {
                        if let activatedAt = engineActivatedAt[profile.id],
                           now.timeIntervalSince(activatedAt) >= 20 * 60 {
                            let offName = profile.luxOffSceneName ?? ""
                            if !offName.isEmpty,
                               let offScene = availableScenes.first(where: {
                                   $0.name.lowercased() == offName.lowercased()
                               }) {
                                try? await scenesService.run(offScene)
                                log.append("• \(profile.roomName): \(Int(lux)) lx > soglia — '\(offName)' attivata (luce rientrata)")
                            } else {
                                log.append("• \(profile.roomName): \(Int(lux)) lx > soglia — luce rientrata, nessuna scena off configurata")
                            }
                            engineActivatedAt.removeValue(forKey: profile.id)
                            markDeactivated(profileID: profile.id, at: now)
                        } else {
                            log.append("• \(profile.roomName): \(Int(lux)) lx > soglia — luce naturale sufficiente, skip")
                        }
                        continue
                    }
                    log.append("• \(profile.roomName): \(Int(lux)) lx (sotto soglia, procedo)")
                }
            }

            // Fase effettiva per questo profilo (sera → notte in base a nightHour)
            let phase = effectivePhase(globalPhase, for: profile, at: now)

            // Sleep hour: durante la Notte, dopo quest'ora l'engine tace senza toccare le luci.
            if phase == .night, let sleepH = profile.sleepHour {
                let h = Calendar.current.component(.hour, from: now)
                // Se sleepH < nightHour il boundary attraversa mezzanotte (es. 1 < 23):
                // il silenzio scatta quando siamo nelle ore mattutine tra sleepH e nightHour.
                let isSleepTime = sleepH < profile.nightHour
                    ? (h >= sleepH && h < profile.nightHour)
                    : (h >= sleepH)
                if isSleepTime {
                    log.append("• \(profile.roomName): sleep hour (\(sleepH):00) — engine silenzioso")
                    continue
                }
            }

            guard let sceneName = profile.sceneName(for: phase), !sceneName.isEmpty else {
                log.append("• \(profile.roomName): nessuna scena configurata per \(phase.displayName)")
                continue
            }

            // Dedup: cooldown 20 min per stessa fase/scena
            if profile.lastAppliedPhase == phase.rawValue,
               let last = profile.lastAppliedAt,
               now.timeIntervalSince(last) < 20 * 60 {
                log.append("• \(profile.roomName): '\(sceneName)' già attiva (cooldown)")
                continue
            }

            // Trova la scena in HomeKit (match case-insensitive)
            guard let scene = availableScenes.first(where: {
                $0.name.lowercased() == sceneName.lowercased()
            }) else {
                log.append("• \(profile.roomName): scena '\(sceneName)' non trovata in HomeKit")
                continue
            }

            do {
                try await scenesService.run(scene)
                markApplied(profileID: profile.id, phase: phase, at: now)
                engineActivatedAt[profile.id] = now
                log.append("• \(profile.roomName): ✅ '\(sceneName)' attivata (\(phase.displayName))")
            } catch {
                log.append("• \(profile.roomName): ❌ \(error.localizedDescription)")
            }
        }

        lastEvaluationAt = now
        lastEvaluationLog = log.joined(separator: "\n")
    }

    // MARK: - Phase Calculation

    private func currentPhase(at now: Date) -> LightingPhase {
        let cal = Calendar.current

        if let sunrise = weatherKit.todaySunrise, let sunset = weatherKit.todaySunset {
            if now < sunrise.addingTimeInterval(-60 * 60)  { return .night }
            if now < sunrise.addingTimeInterval(90 * 60)   { return .dawn }
            if now < sunset.addingTimeInterval(-120 * 60)  { return .morning }
            if now < sunset.addingTimeInterval(-30 * 60)   { return .preSunset }
            if now < sunset.addingTimeInterval(45 * 60)    { return .sunset }
            return .evening  // sera/notte discriminate per-profilo
        }

        // Fallback approssimativo (nessun WeatherKit)
        let h = cal.component(.hour, from: now)
        switch h {
        case 0..<6:   return .night
        case 6..<8:   return .dawn
        case 8..<17:  return .morning
        case 17..<19: return .preSunset
        case 19..<21: return .sunset
        default:      return .evening
        }
    }

    /// Per la fase .evening, controlla se l'ora supera nightHour del profilo → .night.
    private func effectivePhase(_ phase: LightingPhase, for profile: LightingProfile, at now: Date) -> LightingPhase {
        guard phase == .evening else { return phase }
        let h = Calendar.current.component(.hour, from: now)
        return h >= profile.nightHour ? .night : .evening
    }

    // MARK: - Lux Reading

    private func readLux(for profile: LightingProfile, in home: HMHome) -> Double? {
        let luxUUID = "0000006b-0000-1000-8000-0026bb765291"
        let roomName = profile.luxSensorRoomName ?? profile.roomName
        let needle = roomName.lowercased()
        let accs = home.rooms
            .filter { $0.name.lowercased().contains(needle) }
            .flatMap { $0.accessories }
        for acc in accs {
            for svc in acc.services {
                for ch in svc.characteristics {
                    if ch.characteristicType.lowercased() == luxUUID,
                       let val = ch.value as? NSNumber {
                        return val.doubleValue
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Profile Management

    func addOrUpdateProfile(_ profile: LightingProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        saveProfiles()
    }

    func setManualOverride(roomName: String, hours: Double) {
        guard let idx = profiles.firstIndex(where: {
            $0.roomName.lowercased().contains(roomName.lowercased())
        }) else { return }
        profiles[idx].manualOverrideUntil = Date().addingTimeInterval(hours * 3600)
        saveProfiles()
    }

    func clearManualOverride(roomName: String) {
        guard let idx = profiles.firstIndex(where: {
            $0.roomName.lowercased().contains(roomName.lowercased())
        }) else { return }
        profiles[idx].manualOverrideUntil = nil
        saveProfiles()
    }

    // MARK: - Persistence

    private static let profilesKey = "smartLighting.profiles.v1"

    func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: Self.profilesKey),
              let decoded = try? JSONDecoder().decode([LightingProfile].self, from: data) else {
            profiles = []
            return
        }
        profiles = decoded
    }

    private func saveProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: Self.profilesKey)
    }

    private func markApplied(profileID: UUID, phase: LightingPhase, at date: Date) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].lastAppliedPhase = phase.rawValue
        profiles[idx].lastAppliedAt   = date
        saveProfiles()
    }

    /// Aggiorna lastAppliedAt senza cambiare la fase, così il cooldown di riattivazione
    /// riparte dal momento dello spegnimento e previene cicli rapidi accendi/spegni.
    private func markDeactivated(profileID: UUID, at date: Date) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[idx].lastAppliedAt = date
        saveProfiles()
    }

    // MARK: - Status Summary (for AI tool)

    var statusSummary: String {
        guard isGloballyEnabled else { return "Smart Lighting disabilitato." }
        let phase = currentPhase(at: Date())
        var lines: [String] = ["Fase attuale: \(phase.displayName)"]
        if let sr = weatherKit.todaySunrise, let ss = weatherKit.todaySunset {
            lines.append("Sunrise: \(timeString(sr)) · Sunset: \(timeString(ss))")
        }
        if profiles.isEmpty {
            lines.append("Nessuna stanza configurata.")
        } else {
            for p in profiles {
                let state = p.isEnabled ? "abilitato" : "disabilitato"
                let phase = p.lastAppliedPhase.flatMap { LightingPhase(rawValue: $0) }?.displayName ?? "—"
                lines.append("• \(p.roomName) [\(state)] — ultima fase: \(phase)")
            }
        }
        if let last = lastEvaluationAt {
            lines.append("Ultima valutazione: \(timeString(last))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }
}
