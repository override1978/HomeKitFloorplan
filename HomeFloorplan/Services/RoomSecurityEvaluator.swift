import SwiftUI
import HomeKit

// MARK: - RoomSecurityEvaluator

/// Lo stato di sicurezza di una stanza, calcolato **una volta sola** per tutta
/// l'app.
///
/// Era dentro `SecurityOverlayView` come metodo privato. Ricopiarlo nella vista
/// 3D avrebbe prodotto due letture della stessa casa destinate a divergere alla
/// prima soglia toccata — lo stesso errore già fatto e corretto sui filtri
/// ambientali.
enum RoomSecurityEvaluator {

    static func status(of accessories: [HMAccessory],
                       monitoredIDs: Set<String>,
                       homeKit: HomeKitService) -> RoomSecurityStatus {
        var hasLock = false
        var hasAlarm = false
        var hasContactSensor = false
        var hasOpenContact = false
        var isTriggered = false
        var isArmed = false
        var isLocked = false

        for accessory in accessories {
            for service in accessory.services {
                switch service.serviceType {
                case HMServiceTypeSecuritySystem:
                    hasAlarm = true
                    if let characteristic = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeCurrentSecuritySystemState
                    }) {
                        let raw = (homeKit.value(for: characteristic) ?? characteristic.value) as? Int ?? 3
                        if raw == 4 { isTriggered = true }
                        else if raw != 3 { isArmed = true }
                    }
                case HMServiceTypeLockMechanism:
                    hasLock = true
                    if let characteristic = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeCurrentLockMechanismState
                    }) {
                        let raw = (homeKit.value(for: characteristic) ?? characteristic.value) as? Int ?? 0
                        if raw == 1 { isLocked = true }
                    }
                case HMServiceTypeGarageDoorOpener, HMServiceTypeDoorbell:
                    hasLock = true
                case HMServiceTypeContactSensor:
                    guard monitoredIDs.contains(accessory.uniqueIdentifier.uuidString) else { break }
                    hasContactSensor = true
                    if let characteristic = service.characteristics.first(where: {
                        $0.characteristicType == HMCharacteristicTypeContactState
                    }) {
                        let raw = homeKit.value(for: characteristic) ?? characteristic.value
                        if let value = intValue(raw), value != 0 { hasOpenContact = true }
                    }
                default:
                    break
                }
            }
        }

        if isTriggered { return .alarmed }
        if isArmed { return .armed }
        if hasAlarm { return .disarmed }
        if hasOpenContact { return .unlocked }
        if isLocked { return .locked }
        if hasLock { return .unlocked }
        if hasContactSensor { return .protected }
        return .none
    }

    /// Gli accessori di una stanza, per nome.
    ///
    /// La 3D accoppia le stanze **per nome**, come già fa per l'ambiente: gli
    /// UUID delle stanze HomeKit non sono stabili fra device, e il disegno può
    /// averne di vecchi.
    static func accessories(inRoomNamed name: String, homeKit: HomeKitService) -> [HMAccessory] {
        let wanted = normalized(name)
        guard !wanted.isEmpty else { return [] }
        return homeKit.allAccessories.filter { normalized($0.room?.name ?? "") == wanted }
    }

    static func monitoredIDs(from raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? UInt8 { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? Bool { return value ? 1 : 0 }
        return nil
    }
}

// MARK: - Come si mostra uno stato

extension RoomSecurityStatus {

    /// Due parole per la bandierina. L'icona ce l'ha già, ma in 3D l'etichetta
    /// è testo disegnato su una texture e un simbolo non ci sta.
    var shortLabel: String {
        switch self {
        case .none:      String(localized: "security.status.none", defaultValue: "No devices")
        case .protected: String(localized: "security.status.protected", defaultValue: "Protected")
        case .locked:    String(localized: "security.status.locked", defaultValue: "Locked")
        case .unlocked:  String(localized: "security.status.unlocked", defaultValue: "Open")
        case .disarmed:  String(localized: "security.status.disarmed", defaultValue: "Disarmed")
        case .armed:     String(localized: "security.status.armed", defaultValue: "Armed")
        case .alarmed:   String(localized: "security.status.alarmed", defaultValue: "Alarm")
        }
    }

    var accentColor: UIColor {
        switch self {
        case .none:      UIColor(white: 0.6, alpha: 1)
        case .protected: .systemGreen
        case .locked:    .systemPurple
        case .unlocked:  .systemOrange
        case .disarmed:  UIColor(red: 0.62, green: 0.55, blue: 0.78, alpha: 1)
        case .armed:     .systemPurple
        case .alarmed:   .systemRed
        }
    }

    /// Solo questi accendono la stanza. Una casa in ordine deve restare bianca,
    /// o il colore smette di voler dire qualcosa.
    var needsAttention: Bool {
        switch self {
        case .alarmed, .unlocked: true
        case .none, .protected, .locked, .disarmed, .armed: false
        }
    }

    /// Le stanze senza dispositivi non prendono bandierina: dire «nessun
    /// dispositivo» su ogni stanza della casa è rumore, non informazione.
    var deservesFlag: Bool { self != .none }
}
