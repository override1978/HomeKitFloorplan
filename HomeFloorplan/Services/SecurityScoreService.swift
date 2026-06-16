import Foundation
import HomeKit

// MARK: - SecurityScoreService

/// Funzioni pure per calcolare il Security Score e gli insight di sicurezza.
/// Senza stato — chiamato direttamente dalle computed properties della view,
/// così il sistema @Observable di SwiftUI gestisce l'aggiornamento automatico.
///
/// Sprint Security-2: context-aware scoring e insight elevation.
/// Quando la presenza è .away/.vacation, i warning valgono come alarm nello score
/// e gli insight .warning vengono promossi a .critical.
enum SecurityScoreService {

    // MARK: - Score

    /// Calcola il Security Score (0–100) in base allo stato corrente dei sensori.
    /// - Parameter context: ContextSnapshot opzionale. Se presenza è .away/.vacation,
    ///   i sensori in .warning pesano come .alarm nel calcolo del penalty.
    static func computeScore(
        monitoredSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        securitySystem: (accessory: HMAccessory, adapter: SecuritySystemAdapter)?,
        context: ContextSnapshot? = nil
    ) -> Int {
        var penalty = 0
        let isAway = context.map { $0.presenceState == .away || $0.presenceState == .vacation } ?? false

        // Sistema di allarme triggered: -40 punti
        if let sys = securitySystem, sys.adapter.isTriggered {
            penalty += 40
        }

        // Sensori in alarm: -15 ciascuno (max -60)
        let alarmCount = monitoredSensors.filter { $0.adapter.visualUrgency == .alarm }.count
        penalty += min(alarmCount * 15, 60)

        // Sensori in warning: -5 ciascuno in home, -15 (come alarm) quando away/vacation
        let warningCount = monitoredSensors.filter { $0.adapter.visualUrgency == .warning }.count
        let warningPenalty = isAway ? 15 : 5
        let warningCap    = isAway ? 60 : 20
        penalty += min(warningCount * warningPenalty, warningCap)

        // Sistema disarmato durante ore notturne (22:00–06:00): -10
        if let sys = securitySystem, sys.adapter.currentMode == .disarm {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 22 || hour < 6 {
                penalty += 10
            }
        }

        return max(0, 100 - penalty)
    }

    // MARK: - Insights

    /// Genera insight di sicurezza basati sullo stato corrente.
    /// - Parameter context: ContextSnapshot opzionale.
    ///   Quando presenza è .away/.vacation, ogni insight .warning viene promosso a .critical.
    static func buildInsights(
        sensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        system: (accessory: HMAccessory, adapter: SecuritySystemAdapter)?,
        context: ContextSnapshot? = nil
    ) -> [SecurityInsight] {
        var result: [SecurityInsight] = []

        // Insight: sistema di allarme triggered
        if let sys = system, sys.adapter.isTriggered {
            result.append(SecurityInsight(
                priority: .critical,
                room: nil,
                message: String(localized: "security.insight.alarmTriggered",
                                defaultValue: "Alarm system triggered"),
                suggestedAction: String(localized: "security.insight.action.disarm",
                                        defaultValue: "Disarm the system"),
                sfSymbol: "exclamationmark.shield.fill",
                accessoryID: sys.accessory.uniqueIdentifier
            ))
        }

        // Insight per ogni sensore in alarm o warning
        for item in sensors {
            let urgency = item.adapter.visualUrgency
            guard urgency == .alarm || urgency == .warning else { continue }

            let roomName = item.accessory.room?.name
            let name = item.accessory.name

            if urgency == .alarm {
                let (message, action, symbol) = alarmInsight(adapter: item.adapter, name: name, room: roomName)
                result.append(SecurityInsight(
                    priority: .critical,
                    room: roomName,
                    message: message,
                    suggestedAction: action,
                    sfSymbol: symbol,
                    accessoryID: item.accessory.uniqueIdentifier
                ))
            } else {
                let (message, action, symbol) = warningInsight(adapter: item.adapter, name: name, room: roomName)
                result.append(SecurityInsight(
                    priority: .warning,
                    room: roomName,
                    message: message,
                    suggestedAction: action,
                    sfSymbol: symbol,
                    accessoryID: item.accessory.uniqueIdentifier
                ))
            }
        }

        // Insight informativo: sistema disarmato di notte
        if let sys = system, sys.adapter.currentMode == .disarm {
            let hour = Calendar.current.component(.hour, from: Date())
            if hour >= 22 || hour < 6 {
                result.append(SecurityInsight(
                    priority: .info,
                    room: nil,
                    message: String(localized: "security.insight.disarmedAtNight",
                                    defaultValue: "The alarm is disarmed during night hours"),
                    suggestedAction: String(localized: "security.insight.action.armNight",
                                            defaultValue: "Enable Night Mode"),
                    sfSymbol: "moon.stars.fill",
                    accessoryID: sys.accessory.uniqueIdentifier
                ))
            }
        }

        // Context elevation: away/vacation → promuovi ogni .warning a .critical.
        // La logica è: una porta aperta o un garage aperto quando nessuno è in casa
        // è un rischio reale, non una semplice attenzione.
        if let ctx = context, ctx.presenceState == .away || ctx.presenceState == .vacation {
            result = result.map { insight in
                guard insight.priority == .warning else { return insight }
                return SecurityInsight(
                    id: insight.id,
                    priority: .critical,
                    room: insight.room,
                    message: insight.message,
                    suggestedAction: insight.suggestedAction,
                    sfSymbol: insight.sfSymbol,
                    timestamp: insight.timestamp,
                    accessoryID: insight.accessoryID
                )
            }
        }

        return result
    }

    // MARK: - Private helpers

    private static func alarmInsight(
        adapter: any AccessoryAdapter,
        name: String,
        room: String?
    ) -> (message: String, action: String?, symbol: String) {
        let roomSuffix = room.map { " (\($0))" } ?? ""

        if let sensor = adapter as? SensorAdapter {
            if sensor.smokeDetected == true {
                return (
                    "Fumo rilevato: \(name)\(roomSuffix)",
                    String(localized: "security.insight.action.checkArea", defaultValue: "Check the area"),
                    "smoke.fill"
                )
            }
            if sensor.carbonMonoxideDetected == true {
                return (
                    "CO rilevato: \(name)\(roomSuffix)",
                    String(localized: "security.insight.action.evacuate", defaultValue: "Ventilate and verify"),
                    "aqi.high"
                )
            }
            if sensor.leakDetected == true {
                return (
                    "Perdita d'acqua: \(name)\(roomSuffix)",
                    String(localized: "security.insight.action.checkPipes", defaultValue: "Check the plumbing"),
                    "drop.fill"
                )
            }
        }

        if adapter is DoorLockAdapter {
            return (
                "Serratura bloccata: \(name)\(roomSuffix)",
                String(localized: "security.insight.action.checkLock", defaultValue: "Check the lock"),
                "lock.trianglebadge.exclamationmark.fill"
            )
        }

        if adapter is GarageDoorAdapter {
            return (
                "Garage bloccato: \(name)\(roomSuffix)",
                String(localized: "security.insight.action.checkGarage", defaultValue: "Check the garage"),
                "exclamationmark.triangle.fill"
            )
        }

        if adapter is CameraAdapter {
            return (
                "Telecamera offline: \(name)\(roomSuffix)",
                String(localized: "security.insight.action.checkDevice", defaultValue: "Check the device"),
                "video.slash.fill"
            )
        }

        return ("Allarme: \(name)\(roomSuffix)", nil, "exclamationmark.triangle.fill")
    }

    private static func warningInsight(
        adapter: any AccessoryAdapter,
        name: String,
        room: String?
    ) -> (message: String, action: String?, symbol: String) {
        let roomSuffix = room.map { " · \($0)" } ?? ""

        if let sensor = adapter as? SensorAdapter {
            if sensor.contactDetected != nil {
                return (
                    "\(name)\(roomSuffix) è aperto",
                    String(localized: "security.insight.action.closeContact", defaultValue: "Check and close"),
                    "door.left.hand.open"
                )
            }
            if sensor.motionDetected != nil {
                return ("Movimento rilevato: \(name)\(roomSuffix)", nil, "figure.walk.motion")
            }
            if sensor.occupancyDetected != nil {
                return ("Presenza rilevata: \(name)\(roomSuffix)", nil, "person.fill")
            }
        }

        if adapter is DoorLockAdapter {
            return (
                "\(name)\(roomSuffix) è sbloccata",
                String(localized: "security.insight.action.lockDoor", defaultValue: "Lock the door"),
                "lock.open.fill"
            )
        }

        if adapter is GarageDoorAdapter {
            return (
                "\(name)\(roomSuffix) è aperto",
                String(localized: "security.insight.action.closeGarage", defaultValue: "Close the garage"),
                "door.garage.open"
            )
        }

        if adapter is CameraAdapter {
            return ("Movimento rilevato: \(name)\(roomSuffix)", nil, "video.fill")
        }

        return ("Attenzione: \(name)\(roomSuffix)", nil, "exclamationmark.triangle.fill")
    }
}
