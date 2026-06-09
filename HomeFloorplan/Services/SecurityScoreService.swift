import Foundation
import HomeKit

// MARK: - SecurityScoreService

/// Funzioni pure per calcolare il Security Score e gli insight di sicurezza.
/// Senza stato — chiamato direttamente dalle computed properties della view,
/// così il sistema @Observable di SwiftUI gestisce l'aggiornamento automatico.
enum SecurityScoreService {

    // MARK: - Score

    /// Calcola il Security Score (0–100) in base allo stato corrente dei sensori.
    static func computeScore(
        monitoredSensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        securitySystem: (accessory: HMAccessory, adapter: SecuritySystemAdapter)?
    ) -> Int {
        var penalty = 0

        // Sistema di allarme triggered: -40 punti
        if let sys = securitySystem, sys.adapter.isTriggered {
            penalty += 40
        }

        // Sensori in alarm: -15 ciascuno (max -60)
        let alarmCount = monitoredSensors.filter { $0.adapter.visualUrgency == .alarm }.count
        penalty += min(alarmCount * 15, 60)

        // Sensori in warning: -5 ciascuno (max -20)
        let warningCount = monitoredSensors.filter { $0.adapter.visualUrgency == .warning }.count
        penalty += min(warningCount * 5, 20)

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
    static func buildInsights(
        sensors: [(accessory: HMAccessory, adapter: any AccessoryAdapter)],
        system: (accessory: HMAccessory, adapter: SecuritySystemAdapter)?
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

        return ("Attenzione: \(name)\(roomSuffix)", nil, "exclamationmark.triangle.fill")
    }
}
