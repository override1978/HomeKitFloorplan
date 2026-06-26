import Foundation
import HomeKit
import Observation
import SwiftData

struct SmartLightingFloorplanStatus {
    enum State {
        case active
        case paused
        case disabled
        case needsAttention
    }

    var state: State
    var activeCount: Int
    var pausedRooms: [(roomName: String, until: Date)]
    var isUserPaused: Bool
    var issueCount: Int
    var nextResumeAt: Date?
}

struct SmartLightingDecisionRecord: Codable, Identifiable {
    enum Action: String, Codable {
        case applyScene
        case autoOff
        case keep
        case skip
        case error
    }

    var id: UUID = UUID()
    var roomName: String
    var action: Action
    var phaseRaw: String?
    var sceneName: String?
    var reason: String
    var luxValue: Double?
    var luxSource: String?
    var evaluatedAt: Date
}

private struct SmartLightingLuxSample {
    enum Source: String {
        case history
        case homeKit
    }

    let value: Double
    let timestamp: Date
    let source: Source
}

private struct SmartLightingWeatherContext {
    let naturalLightScore: Double
    let reason: String

    var isBrightEnoughForDaytimeFallback: Bool {
        naturalLightScore >= 0.70
    }
}

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
    var lastEvaluationLog: String = String(localized: "smartlighting.log.neverEvaluated",
                                           defaultValue: "Never evaluated")
    private(set) var recentDecisions: [SmartLightingDecisionRecord] = []

    /// Traccia quando il motore ha attivato una scena per profilo (in-memory, reset al rilancio).
    /// Usato per spegnere le luci quando il lux risale sopra soglia dopo il cooldown.
    private var engineActivatedAt: [UUID: Date] = [:]
    private var engineMutationSuppressionUntilByRoom: [String: Date] = [:]
    private var lastEngineSceneRunAtByRoom: [String: Date] = [:]
    private var firstVacantSeenAtByRoom: [String: Date] = [:]
    private var lastVacancyDiagnosticAtByRoom: [String: Date] = [:]

    /// Guardrail anti-oscillazione: Smart Lighting non deve alternare scene sulla stessa stanza
    /// a distanza di pochi secondi, anche se arrivano valutazioni concorrenti o profili duplicati.
    private static let minimumRoomSceneInterval: TimeInterval = 2 * 60
    private static let luxHysteresisRatio = 0.20
    private static let minimumLuxActivationThreshold = 80.0
    private static let minimumLuxDeactivationThreshold = 120.0
    private static let maximumLuxSampleAge: TimeInterval = 12 * 60
    private static let minimumAutoOffDelay: TimeInterval = 45 * 60
    private static let naturalLightStabilityWindow: TimeInterval = 20 * 60
    private static let minimumNaturalLightStableDuration: TimeInterval = 10 * 60
    private static let vacantRoomDiagnosticDelay: TimeInterval = 30 * 60
    private static let vacantRoomDiagnosticRepeatInterval: TimeInterval = 60 * 60
    private static let maximumDecisionHistoryCount = 50

    var isGloballyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "smartLighting.globalEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "smartLighting.globalEnabled") }
    }

    var isUserPaused: Bool {
        get { UserDefaults.standard.bool(forKey: "smartLighting.userPaused") }
        set {
            UserDefaults.standard.set(newValue, forKey: "smartLighting.userPaused")
            lastEvaluationLog = newValue
                ? String(localized: "smartlighting.log.pausedFromFloorplan",
                         defaultValue: "Smart Lighting paused from the floorplan.")
                : String(localized: "smartlighting.log.resumedFromFloorplan",
                         defaultValue: "Smart Lighting resumed from the floorplan.")
        }
    }

    // MARK: - Dependencies

    private let homeKit: HomeKitService
    private let weatherKit: WeatherKitService
    private let scenesService: HomeKitScenesService
    weak var modelContainer: ModelContainer?

    // MARK: - Init

    init(homeKit: HomeKitService, weatherKit: WeatherKitService, scenesService: HomeKitScenesService) {
        self.homeKit       = homeKit
        self.weatherKit    = weatherKit
        self.scenesService = scenesService
        loadProfiles()
        loadDecisionHistory()
    }

    // MARK: - Evaluate

    /// Punto di ingresso principale. Chiamato periodicamente dal foreground loop e dal BGTask.
    func evaluate() async {
        guard isGloballyEnabled else {
            let n = profiles.filter(\.isEnabled).count
            lastEvaluationLog = n > 0
                ? String(format: String(localized: "smartlighting.log.disabledWithProfiles",
                                        defaultValue: "Smart Lighting disabled — %d configured room(s) waiting"),
                         n)
                : String(localized: "smartlighting.log.disabledGlobal",
                         defaultValue: "Smart Lighting disabled globally")
            return
        }
        guard !isUserPaused else {
            lastEvaluationLog = String(localized: "smartlighting.log.pausedByUser",
                                       defaultValue: "Smart Lighting paused by user from the floorplan.")
            return
        }
        guard let home = homeKit.currentHome else {
            lastEvaluationLog = String(localized: "smartlighting.log.homeUnavailable",
                                       defaultValue: "HomeKit home unavailable")
            return
        }

        let now = Date()
        let globalPhase = currentPhase(at: now)
        var log: [String] = [
            String(format: String(localized: "smartlighting.log.globalPhase",
                                  defaultValue: "[%@] Global phase: %@"),
                   timeString(now),
                   globalPhase.displayName)
        ]
        if let (sr, ss) = validSunTimes(at: now) {
            log.append(String(format: String(localized: "smartlighting.log.sunTimes",
                                             defaultValue: "  Sunrise %@ · Sunset %@"),
                              timeString(sr),
                              timeString(ss)))
            let solarPhase = solarPhase(at: now, sunrise: sr, sunset: ss)
            if solarPhase == .night, isLocalDaytime(now) {
                log.append(String(localized: "smartlighting.log.daytimePhaseGuard",
                                  defaultValue: "  Daytime guard corrected an inconsistent Night phase"))
            }
        } else if weatherKit.todaySunrise != nil || weatherKit.todaySunset != nil {
            log.append(String(localized: "smartlighting.log.sunTimesIgnored",
                              defaultValue: "  Sunrise/sunset ignored because they are not valid for today"))
        }

        scenesService.refresh()
        let availableScenes = scenesService.scenes
        var actedRoomKeys: Set<String> = []

        for i in 0..<profiles.count where profiles[i].isEnabled {
            let profile = profiles[i]
            let roomKey = normalizedRoomName(profile.roomName)

            if actedRoomKeys.contains(roomKey) {
                log.append(String(format: String(localized: "smartlighting.log.roomAlreadyHandled",
                                                 defaultValue: "• %@: skipped — this room was already handled in this evaluation"),
                                  profile.roomName))
                continue
            }

            // Override manuale: l'utente ha disabilitato questa stanza temporaneamente
            if let overrideUntil = profile.manualOverrideUntil, now < overrideUntil {
                log.append(String(format: String(localized: "smartlighting.log.manualOverride",
                                                 defaultValue: "• %@: manual override active until %@"),
                                  profile.roomName,
                                  timeString(overrideUntil)))
                continue
            }

            appendVacancyDiagnosticIfNeeded(for: profile, in: home, roomKey: roomKey, at: now, log: &log)

            // Wake hour: nessuna scena (incluse alba/mattino) prima dell'ora di risveglio
            if let wakeH = profile.wakeHour {
                let nowMinutes = minutesSinceMidnight(now)
                let wakeMinutes = minutesSinceMidnight(hour: wakeH, minute: profile.wakeMinute ?? 0)
                if nowMinutes < wakeMinutes {
                    log.append(String(format: String(localized: "smartlighting.log.wakeHourSilent",
                                                     defaultValue: "• %@: wake hour (%@) — engine silent"),
                                      profile.roomName,
                                      timeString(hour: wakeH, minute: profile.wakeMinute ?? 0)))
                    continue
                }
            }

            // Lux bypass con isteresi: evita accendi/spegni quando il sensore oscilla
            // vicino alla soglia configurata.
            // Se il motore aveva acceso le luci e il cooldown (20 min) è scaduto,
            // attiva la scena off configurata solo sopra la soglia alta.
            var latestLuxSample: SmartLightingLuxSample?
            if profile.luxBypassThreshold > 0 {
                if let luxSample = readTrustedLux(for: profile, in: home, at: now) {
                    latestLuxSample = luxSample
                    let lux = luxSample.value
                    let activationThreshold = luxActivationThreshold(for: profile)
                    let deactivationThreshold = luxDeactivationThreshold(for: profile)
                    let activatedAt = engineActivatedAt[profile.id]

                    if activatedAt == nil, lux > activationThreshold {
                        log.append(String(format: String(localized: "smartlighting.log.luxNaturalBandSkip",
                                                         defaultValue: "• %@: %d lx in natural-light band (%d–%d lx) — skipped"),
                                          profile.roomName,
                                          Int(lux),
                                          Int(activationThreshold),
                                          Int(deactivationThreshold)))
                        continue
                    }

                    if lux > deactivationThreshold {
                        if let activatedAt = engineActivatedAt[profile.id],
                           now.timeIntervalSince(activatedAt) >= Self.minimumAutoOffDelay {
                            let offName = profile.luxOffSceneName ?? ""
                            if !usesIndependentLuxSensor(for: profile) {
                                log.append(String(format: String(localized: "smartlighting.log.luxAutoOffSameRoomSkipped",
                                                                 defaultValue: "• %@: %d lx > high threshold — auto-off skipped: the lux sensor is in the same room and may read artificial light"),
                                                  profile.roomName,
                                                  Int(lux)))
                                recordDecision(
                                    roomName: profile.roomName,
                                    action: .keep,
                                    phase: nil,
                                    sceneName: nil,
                                    reason: "Auto-off skipped: same-room lux sensor",
                                    luxSample: luxSample,
                                    at: now
                                )
                            } else if luxSample.source != .history {
                                log.append(String(format: String(localized: "smartlighting.log.luxAutoOffNeedsHistory",
                                                                 defaultValue: "• %@: %d lx > high threshold — auto-off skipped: no recent trusted lux history"),
                                                  profile.roomName,
                                                  Int(lux)))
                                recordDecision(
                                    roomName: profile.roomName,
                                    action: .keep,
                                    phase: nil,
                                    sceneName: nil,
                                    reason: "Auto-off skipped: missing recent lux history",
                                    luxSample: luxSample,
                                    at: now
                                )
                            } else if !hasStableNaturalLight(for: profile, threshold: deactivationThreshold, at: now) {
                                log.append(String(format: String(localized: "smartlighting.log.luxAutoOffUnstable",
                                                                 defaultValue: "• %@: %d lx > high threshold — auto-off skipped: natural light is not stable yet"),
                                                  profile.roomName,
                                                  Int(lux)))
                                recordDecision(
                                    roomName: profile.roomName,
                                    action: .keep,
                                    phase: nil,
                                    sceneName: nil,
                                    reason: "Auto-off skipped: natural light not stable",
                                    luxSample: luxSample,
                                    at: now
                                )
                            } else if let presenceSensorName = activePresenceSensorName(for: profile, in: home) {
                                log.append(String(format: String(localized: "smartlighting.log.luxAutoOffPresenceSkipped",
                                                                 defaultValue: "• %@: %d lx > high threshold — auto-off skipped: presence detected by %@"),
                                                  profile.roomName,
                                                  Int(lux),
                                                  presenceSensorName))
                                recordDecision(
                                    roomName: profile.roomName,
                                    action: .keep,
                                    phase: nil,
                                    sceneName: nil,
                                    reason: "Auto-off skipped: active presence sensor \(presenceSensorName)",
                                    luxSample: luxSample,
                                    at: now
                                )
                            } else if !offName.isEmpty,
                               let offScene = availableScenes.first(where: {
                                   $0.name.lowercased() == offName.lowercased()
                               }) {
                                guard canRunScene(forRoomKey: roomKey, at: now) else {
                                    log.append(String(format: String(localized: "smartlighting.log.sceneAntiLoopSkipped",
                                                                     defaultValue: "• %@: '%@' skipped — anti-loop guard active"),
                                                      profile.roomName,
                                                      offName))
                                    continue
                                }
                                suppressManualPause(for: profile.roomName)
                                try? await scenesService.run(offScene)
                                markSceneRun(forRoomKey: roomKey, at: now)
                                actedRoomKeys.insert(roomKey)
                                recordDecision(
                                    roomName: profile.roomName,
                                    action: .autoOff,
                                    phase: nil,
                                    sceneName: offName,
                                    reason: "Natural light stable above threshold",
                                    luxSample: luxSample,
                                    at: now
                                )
                                log.append(String(format: String(localized: "smartlighting.log.luxOffSceneActivated",
                                                                 defaultValue: "• %@: %d lx > high threshold — '%@' activated (natural light returned)"),
                                                  profile.roomName,
                                                  Int(lux),
                                                  offName))
                            } else {
                                log.append(String(format: String(localized: "smartlighting.log.luxNoOffScene",
                                                                 defaultValue: "• %@: %d lx > high threshold — natural light returned, no off scene configured"),
                                                  profile.roomName,
                                                  Int(lux)))
                                recordDecision(
                                    roomName: profile.roomName,
                                    action: .keep,
                                    phase: nil,
                                    sceneName: nil,
                                    reason: "Natural light returned, no off scene configured",
                                    luxSample: luxSample,
                                    at: now
                                )
                            }
                            engineActivatedAt.removeValue(forKey: profile.id)
                            markDeactivated(profileID: profile.id, at: now)
                        } else {
                            log.append(String(format: String(localized: "smartlighting.log.luxHighSkip",
                                                             defaultValue: "• %@: %d lx > high threshold — natural light sufficient, skipped"),
                                              profile.roomName,
                                              Int(lux)))
                            recordDecision(
                                roomName: profile.roomName,
                                action: .keep,
                                phase: nil,
                                sceneName: nil,
                                reason: "Natural light sufficient",
                                luxSample: luxSample,
                                at: now
                            )
                        }
                        continue
                    }

                    if lux > activationThreshold {
                        log.append(String(format: String(localized: "smartlighting.log.luxHysteresisHold",
                                                         defaultValue: "• %@: %d lx in hysteresis band — keeping state"),
                                          profile.roomName,
                                          Int(lux)))
                    } else {
                        log.append(String(format: String(localized: "smartlighting.log.luxLowProceed",
                                                         defaultValue: "• %@: %d lx < low threshold — proceeding"),
                                          profile.roomName,
                                          Int(lux)))
                    }
                } else {
                    log.append(String(format: String(localized: "smartlighting.log.luxUnavailable",
                                                     defaultValue: "• %@: no recent lux reading — proceeding conservatively"),
                                      profile.roomName))
                }
            }

            // Fase effettiva per questo profilo (sera → notte in base a nightHour)
            let phase = effectivePhase(globalPhase, for: profile, at: now)

            // Sleep hour: durante la Notte, dopo quest'ora l'engine tace senza toccare le luci.
            if phase == .night, let sleepH = profile.sleepHour {
                let nowMinutes = minutesSinceMidnight(now)
                let sleepMinutes = minutesSinceMidnight(hour: sleepH, minute: profile.sleepMinute ?? 0)
                let nightMinutes = minutesSinceMidnight(hour: profile.nightHour, minute: 0)
                // Se sleep < nightHour il boundary attraversa mezzanotte (es. 01:30 < 23:00):
                // il silenzio scatta nelle ore mattutine tra sleep e night.
                let isSleepTime = sleepMinutes < nightMinutes
                    ? (nowMinutes >= sleepMinutes && nowMinutes < nightMinutes)
                    : (nowMinutes >= sleepMinutes)
                if isSleepTime {
                    log.append(String(format: String(localized: "smartlighting.log.sleepHourSilent",
                                                     defaultValue: "• %@: sleep hour (%@) — engine silent"),
                                      profile.roomName,
                                      timeString(hour: sleepH, minute: profile.sleepMinute ?? 0)))
                    continue
                }
            }

            if latestLuxSample == nil,
               shouldSkipForWeatherFallback(phase: phase) {
                if let weatherContext = weatherContext(at: now) {
                    if weatherContext.isBrightEnoughForDaytimeFallback {
                        log.append(String(format: String(localized: "smartlighting.log.weatherBrightSkip",
                                                         defaultValue: "• %@: weather suggests enough natural light (%@) — skipped"),
                                          profile.roomName,
                                          weatherContext.reason))
                        recordDecision(
                            roomName: profile.roomName,
                            action: .keep,
                            phase: phase,
                            sceneName: nil,
                            reason: "Weather fallback skipped lighting: \(weatherContext.reason)",
                            luxSample: nil,
                            at: now
                        )
                        continue
                    } else {
                        log.append(String(format: String(localized: "smartlighting.log.weatherLowLightProceed",
                                                         defaultValue: "• %@: weather does not confirm enough natural light (%@) — proceeding"),
                                          profile.roomName,
                                          weatherContext.reason))
                    }
                } else {
                    log.append(String(format: String(localized: "smartlighting.log.weatherUnavailable",
                                                     defaultValue: "• %@: weather fallback unavailable — proceeding"),
                                      profile.roomName))
                }
            }

            guard let sceneName = profile.sceneName(for: phase), !sceneName.isEmpty else {
                log.append(String(format: String(localized: "smartlighting.log.noSceneForPhase",
                                                 defaultValue: "• %@: no scene configured for %@"),
                                  profile.roomName,
                                  phase.displayName))
                continue
            }

            // Dedup: cooldown 20 min per stessa fase/scena
            if profile.lastAppliedPhase == phase.rawValue,
               let last = profile.lastAppliedAt,
               now.timeIntervalSince(last) < 20 * 60 {
                log.append(String(format: String(localized: "smartlighting.log.sceneCooldown",
                                                 defaultValue: "• %@: '%@' already active (cooldown)"),
                                  profile.roomName,
                                  sceneName))
                continue
            }

            // Trova la scena in HomeKit (match case-insensitive)
            guard let scene = availableScenes.first(where: {
                $0.name.lowercased() == sceneName.lowercased()
            }) else {
                log.append(String(format: String(localized: "smartlighting.log.sceneNotFound",
                                                 defaultValue: "• %@: scene '%@' not found in HomeKit"),
                                  profile.roomName,
                                  sceneName))
                continue
            }

            let warnings = sceneValidationWarnings(for: scene, targetRoomName: profile.roomName)
            for warning in warnings {
                log.append(String(format: String(localized: "smartlighting.log.sceneWarning",
                                                 defaultValue: "  ⚠️ %@"),
                                  warning))
            }

            guard canRunScene(forRoomKey: roomKey, at: now) else {
                log.append(String(format: String(localized: "smartlighting.log.sceneAntiLoopSkipped",
                                                 defaultValue: "• %@: '%@' skipped — anti-loop guard active"),
                                  profile.roomName,
                                  sceneName))
                continue
            }

            do {
                suppressManualPause(for: profile.roomName)
                try await scenesService.run(scene)
                markSceneRun(forRoomKey: roomKey, at: now)
                actedRoomKeys.insert(roomKey)
                markApplied(profileID: profile.id, phase: phase, at: now)
                engineActivatedAt[profile.id] = now
                recordDecision(
                    roomName: profile.roomName,
                    action: .applyScene,
                    phase: phase,
                    sceneName: sceneName,
                    reason: warnings.isEmpty ? "Scene applied for phase" : "Scene applied with warnings: \(warnings.joined(separator: "; "))",
                    luxSample: nil,
                    at: now
                )
                log.append(String(format: String(localized: "smartlighting.log.sceneActivated",
                                                 defaultValue: "• %@: ✅ '%@' activated (%@)"),
                                  profile.roomName,
                                  sceneName,
                                   phase.displayName))
            } catch {
                log.append("• \(profile.roomName): ❌ \(error.localizedDescription)")
                recordDecision(
                    roomName: profile.roomName,
                    action: .error,
                    phase: phase,
                    sceneName: sceneName,
                    reason: error.localizedDescription,
                    luxSample: nil,
                    at: now
                )
            }
        }

        lastEvaluationAt = now
        lastEvaluationLog = log.joined(separator: "\n")
    }

    // MARK: - Phase Calculation

    private func currentPhase(at now: Date) -> LightingPhase {
        if let (sunrise, sunset) = validSunTimes(at: now) {
            let solarPhase = solarPhase(at: now, sunrise: sunrise, sunset: sunset)

            if solarPhase == .night, isLocalDaytime(now) {
                return fallbackPhase(at: now)
            }

            return solarPhase
        }

        return fallbackPhase(at: now)
    }

    private func solarPhase(at now: Date, sunrise: Date, sunset: Date) -> LightingPhase {
        if now < sunrise.addingTimeInterval(-60 * 60) { return .night }
        if now < sunrise.addingTimeInterval(90 * 60) { return .dawn }
        if now < sunset.addingTimeInterval(-120 * 60) { return .morning }
        if now < sunset.addingTimeInterval(-30 * 60) { return .preSunset }
        if now < sunset.addingTimeInterval(45 * 60) { return .sunset }
        return .evening
    }

    private func fallbackPhase(at now: Date) -> LightingPhase {
        let h = Calendar.current.component(.hour, from: now)
        switch h {
        case 0..<6:   return .night
        case 6..<8:   return .dawn
        case 8..<17:  return .morning
        case 17..<19: return .preSunset
        case 19..<21: return .sunset
        default:      return .evening
        }
    }

    private func isLocalDaytime(_ date: Date) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        return (8..<17).contains(h)
    }

    private func validSunTimes(at now: Date) -> (sunrise: Date, sunset: Date)? {
        guard let sunrise = weatherKit.todaySunrise,
              let sunset = weatherKit.todaySunset,
              sunrise < sunset else {
            return nil
        }

        let calendar = Calendar.current
        guard calendar.isDate(sunrise, inSameDayAs: now),
              calendar.isDate(sunset, inSameDayAs: now) else {
            return nil
        }

        return (sunrise, sunset)
    }

    /// Per la fase .evening, controlla se l'ora supera nightHour del profilo → .night.
    private func effectivePhase(_ phase: LightingPhase, for profile: LightingProfile, at now: Date) -> LightingPhase {
        guard phase == .evening else { return phase }
        let h = Calendar.current.component(.hour, from: now)
        return h >= profile.nightHour ? .night : .evening
    }

    // MARK: - Weather Fallback

    private func shouldSkipForWeatherFallback(phase: LightingPhase) -> Bool {
        switch phase {
        case .morning, .preSunset:
            return true
        case .dawn, .sunset, .evening, .night:
            return false
        }
    }

    private func weatherContext(at now: Date) -> SmartLightingWeatherContext? {
        guard let snapshot = weatherKit.currentWeather else { return nil }
        if let updated = weatherKit.lastUpdated,
           now.timeIntervalSince(updated) > 2 * 60 * 60 {
            return nil
        }

        var score = 0.45
        var notes: [String] = []
        let condition = snapshot.condition.lowercased()
        let symbol = snapshot.symbolName.lowercased()

        if condition.contains("clear") || symbol.contains("sun.max") {
            score += 0.30
            notes.append(String(localized: "smartlighting.weather.clear",
                                defaultValue: "clear sky"))
        } else if condition.contains("mostlyclear") || condition.contains("partlycloudy") || symbol.contains("cloud.sun") {
            score += 0.18
            notes.append(String(localized: "smartlighting.weather.partialCloud",
                                defaultValue: "partial cloud"))
        } else if condition.contains("cloud") || condition.contains("overcast") {
            score -= 0.22
            notes.append(String(localized: "smartlighting.weather.cloudy",
                                defaultValue: "cloudy"))
        }

        if condition.contains("rain") ||
            condition.contains("drizzle") ||
            condition.contains("thunder") ||
            condition.contains("snow") ||
            condition.contains("sleet") ||
            condition.contains("fog") ||
            symbol.contains("rain") ||
            symbol.contains("snow") ||
            symbol.contains("fog") {
            score -= 0.30
            notes.append(String(localized: "smartlighting.weather.lowVisibility",
                                defaultValue: "low visibility"))
        }

        switch snapshot.uvIndex {
        case 6...:
            score += 0.22
            notes.append(String(format: String(localized: "smartlighting.weather.uvHigh",
                                               defaultValue: "UV %d"),
                                snapshot.uvIndex))
        case 3...5:
            score += 0.10
            notes.append(String(format: String(localized: "smartlighting.weather.uvMedium",
                                               defaultValue: "UV %d"),
                                snapshot.uvIndex))
        default:
            score -= 0.12
            notes.append(String(format: String(localized: "smartlighting.weather.uvLow",
                                               defaultValue: "UV %d"),
                                snapshot.uvIndex))
        }

        if let (_, sunset) = validSunTimes(at: now),
           now > sunset.addingTimeInterval(-90 * 60) {
            score -= 0.18
            notes.append(String(localized: "smartlighting.weather.nearSunset",
                                defaultValue: "near sunset"))
        }

        let boundedScore = min(1.0, max(0.0, score))
        let reason = notes.isEmpty
            ? String(format: String(localized: "smartlighting.weather.score",
                                    defaultValue: "score %.0f%%"),
                     boundedScore * 100)
            : notes.joined(separator: ", ")
        return SmartLightingWeatherContext(naturalLightScore: boundedScore, reason: reason)
    }

    // MARK: - Lux Reading

    private func readTrustedLux(for profile: LightingProfile, in home: HMHome, at now: Date) -> SmartLightingLuxSample? {
        if let historical = latestHistoricalLux(for: profile, at: now) {
            return historical
        }

        guard let lux = readLux(for: profile, in: home) else { return nil }
        return SmartLightingLuxSample(value: lux, timestamp: now, source: .homeKit)
    }

    private func latestHistoricalLux(for profile: LightingProfile, at now: Date) -> SmartLightingLuxSample? {
        guard let modelContainer else { return nil }
        let roomName = profile.luxSensorRoomName ?? profile.roomName
        let roomKey = normalizedRoomName(roomName)
        let cutoff = now.addingTimeInterval(-Self.maximumLuxSampleAge)
        let typeRaw = SensorServiceType.lightSensor.rawValue
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { reading in
                reading.serviceTypeRaw == typeRaw && reading.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let readings = (try? context.fetch(descriptor)) ?? []
        guard let latest = readings.first(where: { normalizedRoomName($0.roomName) == roomKey }) else {
            return nil
        }
        return SmartLightingLuxSample(value: latest.value, timestamp: latest.timestamp, source: .history)
    }

    private func hasStableNaturalLight(for profile: LightingProfile, threshold: Double, at now: Date) -> Bool {
        guard let modelContainer else { return false }
        let roomName = profile.luxSensorRoomName ?? profile.roomName
        let roomKey = normalizedRoomName(roomName)
        let cutoff = now.addingTimeInterval(-Self.naturalLightStabilityWindow)
        let typeRaw = SensorServiceType.lightSensor.rawValue
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: #Predicate { reading in
                reading.serviceTypeRaw == typeRaw && reading.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let readings = ((try? context.fetch(descriptor)) ?? [])
            .filter { normalizedRoomName($0.roomName) == roomKey }
        guard readings.count >= 2,
              let first = readings.first,
              let last = readings.last,
              last.timestamp.timeIntervalSince(first.timestamp) >= Self.minimumNaturalLightStableDuration else {
            return false
        }
        return readings.allSatisfy { $0.value >= threshold }
    }

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

    private func activePresenceSensorName(for profile: LightingProfile, in home: HMHome) -> String? {
        let sensorTypes = Set([
            HMCharacteristicTypeMotionDetected.lowercased(),
            HMCharacteristicTypeOccupancyDetected.lowercased()
        ])
        let roomKey = normalizedRoomName(profile.roomName)
        let accessories = home.rooms
            .filter { normalizedRoomName($0.name) == roomKey || normalizedRoomName($0.name).contains(roomKey) }
            .flatMap { $0.accessories }

        for accessory in accessories {
            for service in accessory.services {
                for characteristic in service.characteristics
                where sensorTypes.contains(characteristic.characteristicType.lowercased()) {
                    let rawValue = homeKit.value(for: characteristic) ?? characteristic.value
                    if boolValue(rawValue) == true || intValue(rawValue) == 1 {
                        return accessory.name
                    }
                }
            }
        }
        return nil
    }

    private struct PresenceSnapshot {
        let hasSensors: Bool
        let activeSensorName: String?

        var isVacant: Bool {
            hasSensors && activeSensorName == nil
        }
    }

    private func appendVacancyDiagnosticIfNeeded(
        for profile: LightingProfile,
        in home: HMHome,
        roomKey: String,
        at now: Date,
        log: inout [String]
    ) {
        let presence = presenceSnapshot(for: profile, in: home)
        guard presence.hasSensors else {
            firstVacantSeenAtByRoom.removeValue(forKey: roomKey)
            return
        }

        if let activeSensorName = presence.activeSensorName {
            firstVacantSeenAtByRoom.removeValue(forKey: roomKey)
            log.append(String(format: String(localized: "smartlighting.log.presenceActive",
                                             defaultValue: "• %@: presence detected by %@ — vacancy diagnostic reset"),
                              profile.roomName,
                              activeSensorName))
            return
        }

        let firstVacantAt = firstVacantSeenAtByRoom[roomKey] ?? now
        firstVacantSeenAtByRoom[roomKey] = firstVacantAt

        guard now.timeIntervalSince(firstVacantAt) >= Self.vacantRoomDiagnosticDelay,
              roomHasAnyLightOn(profile, in: home) else {
            return
        }

        if let lastDiagnosticAt = lastVacancyDiagnosticAtByRoom[roomKey],
           now.timeIntervalSince(lastDiagnosticAt) < Self.vacantRoomDiagnosticRepeatInterval {
            return
        }

        lastVacancyDiagnosticAtByRoom[roomKey] = now
        let minutes = Int(now.timeIntervalSince(firstVacantAt) / 60)
        log.append(String(format: String(localized: "smartlighting.log.vacantLightsOn",
                                         defaultValue: "• %@: no presence for %d min and lights appear on — diagnostic only, no auto-off"),
                          profile.roomName,
                          minutes))
        recordDecision(
            roomName: profile.roomName,
            action: .keep,
            phase: nil,
            sceneName: nil,
            reason: "Vacancy diagnostic: no presence for \(minutes) min while lights appear on",
            luxSample: nil,
            at: now
        )
    }

    private func presenceSnapshot(for profile: LightingProfile, in home: HMHome) -> PresenceSnapshot {
        let sensorTypes = Set([
            HMCharacteristicTypeMotionDetected.lowercased(),
            HMCharacteristicTypeOccupancyDetected.lowercased()
        ])
        var hasSensors = false

        for accessory in roomAccessories(for: profile, in: home) {
            for service in accessory.services {
                for characteristic in service.characteristics
                where sensorTypes.contains(characteristic.characteristicType.lowercased()) {
                    hasSensors = true
                    let rawValue = homeKit.value(for: characteristic) ?? characteristic.value
                    if boolValue(rawValue) == true || intValue(rawValue) == 1 {
                        return PresenceSnapshot(hasSensors: true, activeSensorName: accessory.name)
                    }
                }
            }
        }

        return PresenceSnapshot(hasSensors: hasSensors, activeSensorName: nil)
    }

    private func roomHasAnyLightOn(_ profile: LightingProfile, in home: HMHome) -> Bool {
        for accessory in roomAccessories(for: profile, in: home) {
            let isLightAccessory = accessory.category.categoryType == HMAccessoryCategoryTypeLightbulb
            for service in accessory.services where isLightAccessory || service.serviceType == HMServiceTypeLightbulb {
                if service.characteristics.contains(where: isLightOnCharacteristic) {
                    return true
                }
            }
        }
        return false
    }

    private func isLightOnCharacteristic(_ characteristic: HMCharacteristic) -> Bool {
        let rawValue = homeKit.value(for: characteristic) ?? characteristic.value
        switch characteristic.characteristicType {
        case HMCharacteristicTypePowerState:
            return boolValue(rawValue) == true || intValue(rawValue) == 1
        case HMCharacteristicTypeBrightness:
            return (intValue(rawValue) ?? 0) > 0
        default:
            return false
        }
    }

    private func roomAccessories(for profile: LightingProfile, in home: HMHome) -> [HMAccessory] {
        let roomKey = normalizedRoomName(profile.roomName)
        return home.rooms
            .filter { normalizedRoomName($0.name) == roomKey || normalizedRoomName($0.name).contains(roomKey) }
            .flatMap(\.accessories)
    }

    private func usesIndependentLuxSensor(for profile: LightingProfile) -> Bool {
        guard let luxSensorRoomName = profile.luxSensorRoomName,
              !luxSensorRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return normalizedRoomName(luxSensorRoomName) != normalizedRoomName(profile.roomName)
    }

    private func luxActivationThreshold(for profile: LightingProfile) -> Double {
        max(Self.minimumLuxActivationThreshold, profile.luxBypassThreshold * (1 - Self.luxHysteresisRatio))
    }

    private func luxDeactivationThreshold(for profile: LightingProfile) -> Double {
        max(Self.minimumLuxDeactivationThreshold, profile.luxBypassThreshold * (1 + Self.luxHysteresisRatio))
    }

    private func canRunScene(forRoomKey roomKey: String, at now: Date) -> Bool {
        guard let last = lastEngineSceneRunAtByRoom[roomKey] else { return true }
        return now.timeIntervalSince(last) >= Self.minimumRoomSceneInterval
    }

    private func markSceneRun(forRoomKey roomKey: String, at now: Date) {
        lastEngineSceneRunAtByRoom[roomKey] = now
    }

    private func sceneValidationWarnings(for scene: SceneItem, targetRoomName: String) -> [String] {
        let targetKey = normalizedRoomName(targetRoomName)
        let roomNames = Set(scene.actionSet.actions.compactMap { action -> String? in
            guard let write = action.homeFloorplanCharacteristicWrite,
                  let roomName = write.characteristic.service?.accessory?.room?.name else {
                return nil
            }
            return roomName
        })
        var warnings: [String] = []
        let outsideRooms = roomNames
            .filter { normalizedRoomName($0) != targetKey }
            .sorted()
        if !outsideRooms.isEmpty {
            warnings.append(String(format: String(localized: "smartlighting.warning.sceneOutsideRooms",
                                                  defaultValue: "Scene also affects: %@"),
                                   outsideRooms.joined(separator: ", ")))
        }
        if sceneContainsOffWrites(scene) {
            warnings.append(String(localized: "smartlighting.warning.sceneContainsOff",
                                   defaultValue: "Scene contains off commands"))
        }
        if roomNames.count > 2 {
            warnings.append(String(format: String(localized: "smartlighting.warning.sceneManyRooms",
                                                  defaultValue: "Scene spans %d rooms"),
                                   roomNames.count))
        }
        return warnings
    }

    private func sceneContainsOffWrites(_ scene: SceneItem) -> Bool {
        scene.actionSet.actions.contains { action in
            guard let write = action.homeFloorplanCharacteristicWrite else { return false }
            let type = write.characteristic.characteristicType
            guard type == HMCharacteristicTypePowerState || type == HMCharacteristicTypeActive else {
                return false
            }
            return boolValue(write.targetValue) == false || intValue(write.targetValue) == 0
        }
    }

    private func boolValue(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let i = raw as? Int { return i != 0 }
        return nil
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let i = raw as? Int { return i }
        if let n = raw as? NSNumber { return n.intValue }
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

    func clearAllManualOverrides() {
        var changed = false
        for idx in profiles.indices where profiles[idx].manualOverrideUntil != nil {
            profiles[idx].manualOverrideUntil = nil
            changed = true
        }
        if changed {
            saveProfiles()
            lastEvaluationLog = String(localized: "smartlighting.log.resumedAllRooms",
                                       defaultValue: "Smart Lighting resumed for all rooms.")
        }
    }

    func pauseFromFloorplan() {
        isUserPaused = true
    }

    func resumeFromFloorplan() {
        isUserPaused = false
        clearAllManualOverrides()
    }

    var floorplanStatus: SmartLightingFloorplanStatus? {
        let enabledProfiles = profiles.filter(\.isEnabled)
        guard !enabledProfiles.isEmpty else { return nil }

        let now = Date()
        let pausedRooms = enabledProfiles
            .compactMap { profile -> (roomName: String, until: Date)? in
                guard let until = profile.manualOverrideUntil, until > now else { return nil }
                return (profile.roomName, until)
            }
            .sorted { $0.until < $1.until }

        let issueCount = missingSceneCount(in: enabledProfiles)
        let state: SmartLightingFloorplanStatus.State
        if issueCount > 0 {
            state = .needsAttention
        } else if !isGloballyEnabled {
            state = .disabled
        } else if isUserPaused {
            state = .paused
        } else if !pausedRooms.isEmpty {
            state = .paused
        } else {
            state = .active
        }

        return SmartLightingFloorplanStatus(
            state: state,
            activeCount: enabledProfiles.count,
            pausedRooms: pausedRooms,
            isUserPaused: isUserPaused,
            issueCount: issueCount,
            nextResumeAt: pausedRooms.first?.until
        )
    }

    func isProfilePaused(_ profile: LightingProfile, at now: Date = Date()) -> Bool {
        guard let until = profile.manualOverrideUntil else { return false }
        return until > now
    }

    // MARK: - Persistence

    private static let profilesKey = "smartLighting.profiles.v1"
    private static let decisionsKey = "smartLighting.decisions.v1"

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

    private func loadDecisionHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.decisionsKey),
              let decoded = try? JSONDecoder().decode([SmartLightingDecisionRecord].self, from: data) else {
            recentDecisions = []
            return
        }
        recentDecisions = Array(decoded.prefix(Self.maximumDecisionHistoryCount))
    }

    private func saveDecisionHistory() {
        guard let data = try? JSONEncoder().encode(recentDecisions) else { return }
        UserDefaults.standard.set(data, forKey: Self.decisionsKey)
    }

    private func recordDecision(
        roomName: String,
        action: SmartLightingDecisionRecord.Action,
        phase: LightingPhase?,
        sceneName: String?,
        reason: String,
        luxSample: SmartLightingLuxSample?,
        at date: Date
    ) {
        let record = SmartLightingDecisionRecord(
            roomName: roomName,
            action: action,
            phaseRaw: phase?.rawValue,
            sceneName: sceneName,
            reason: reason,
            luxValue: luxSample?.value,
            luxSource: luxSample?.source.rawValue,
            evaluatedAt: date
        )
        recentDecisions.insert(record, at: 0)
        if recentDecisions.count > Self.maximumDecisionHistoryCount {
            recentDecisions.removeLast(recentDecisions.count - Self.maximumDecisionHistoryCount)
        }
        saveDecisionHistory()
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

    private func missingSceneCount(in enabledProfiles: [LightingProfile]) -> Int {
        let availableSceneNames = Set(scenesService.scenes.map { $0.name.lowercased() })
        var count = 0
        for profile in enabledProfiles {
            for phase in LightingPhase.allCases {
                guard let sceneName = profile.sceneName(for: phase), !sceneName.isEmpty else { continue }
                if !availableSceneNames.contains(sceneName.lowercased()) {
                    count += 1
                }
            }
            if let offScene = profile.luxOffSceneName, !offScene.isEmpty,
               !availableSceneNames.contains(offScene.lowercased()) {
                count += 1
            }
        }
        return count
    }

    private func suppressManualPause(for roomName: String, seconds: TimeInterval = 20) {
        engineMutationSuppressionUntilByRoom[normalizedRoomName(roomName)] = Date().addingTimeInterval(seconds)
    }

    private func isSuppressingManualPause(for roomName: String) -> Bool {
        let key = normalizedRoomName(roomName)
        guard let until = engineMutationSuppressionUntilByRoom[key] else { return false }
        if until > Date() {
            return true
        }
        engineMutationSuppressionUntilByRoom.removeValue(forKey: key)
        return false
    }

    private func normalizedRoomName(_ roomName: String) -> String {
        roomName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - Status Summary (for AI tool)

    var statusSummary: String {
        guard isGloballyEnabled else {
            return String(localized: "smartlighting.status.disabled",
                          defaultValue: "Smart Lighting disabled.")
        }
        guard !isUserPaused else {
            return String(localized: "smartlighting.status.paused",
                          defaultValue: "Smart Lighting paused manually from the floorplan.")
        }
        let phase = currentPhase(at: Date())
        var lines: [String] = [
            String(format: String(localized: "smartlighting.status.currentPhase",
                                  defaultValue: "Current phase: %@"),
                   phase.displayName)
        ]
        if let sr = weatherKit.todaySunrise, let ss = weatherKit.todaySunset {
            lines.append("Sunrise: \(timeString(sr)) · Sunset: \(timeString(ss))")
        }
        if profiles.isEmpty {
            lines.append(String(localized: "smartlighting.status.noRooms",
                                defaultValue: "No rooms configured."))
        } else {
            for p in profiles {
                let state = p.isEnabled
                    ? String(localized: "smartlighting.status.enabled", defaultValue: "enabled")
                    : String(localized: "smartlighting.status.roomDisabled", defaultValue: "disabled")
                let phase = p.lastAppliedPhase.flatMap { LightingPhase(rawValue: $0) }?.displayName ?? "—"
                lines.append(String(format: String(localized: "smartlighting.status.roomLine",
                                                   defaultValue: "• %@ [%@] — last phase: %@"),
                                    p.roomName,
                                    state,
                                    phase))
            }
        }
        if let last = lastEvaluationAt {
            lines.append(String(format: String(localized: "smartlighting.status.lastEvaluation",
                                               defaultValue: "Last evaluation: %@"),
                                timeString(last)))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }

    private func timeString(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private func minutesSinceMidnight(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return minutesSinceMidnight(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    private func minutesSinceMidnight(hour: Int, minute: Int) -> Int {
        hour * 60 + minute
    }
}
