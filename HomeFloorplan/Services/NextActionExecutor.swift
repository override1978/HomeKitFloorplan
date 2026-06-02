import Foundation
import HomeKit
import UIKit

// MARK: - NextActionExecutor

/// Esegue le Next Action generate dall'AI per un insight ambientale.
/// Supporta esecuzione immediata di accessori HomeKit.
@MainActor
final class NextActionExecutor {

    // HAP UUID costanti (allineate con AccessoryEventStore)
    private static let onUUID                  = "00000025-0000-1000-8000-0026bb765291"
    private static let activeUUID              = "000000b0-0000-1000-8000-0026bb765291"
    private static let brightnessUUID          = "00000008-0000-1000-8000-0026bb765291"
    private static let positionUUID            = "0000007c-0000-1000-8000-0026bb765291"
    private static let rotationSpeedUUID       = "00000029-0000-1000-8000-0026bb765291"
    private static let targetHeaterCoolerUUID  = "000000b2-0000-1000-8000-0026bb765291"
    private static let targetAirPurifierUUID   = "000000a8-0000-1000-8000-0026bb765291"
    private static let targetTempUUID          = "00000035-0000-1000-8000-0026bb765291"
    private static let heatingThresholdUUID    = "00000012-0000-1000-8000-0026bb765291"
    private static let coolingThresholdUUID    = "0000000d-0000-1000-8000-0026bb765291"

    // MARK: - Execute

    /// Esegue una Next Action di tipo `executeNow` nella casa fornita.
    /// Ritorna `true` se l'azione è stata eseguita con successo.
    func execute(_ action: AINextAction, in home: HMHome) async -> Bool {
        guard action.actionType == "executeNow",
              let accessoryIDStr = action.accessoryID,
              let accessoryUUID  = UUID(uuidString: accessoryIDStr),
              let actionType     = action.accessoryActionType
        else { return false }

        guard let accessory = home.accessories.first(where: {
            $0.uniqueIdentifier == accessoryUUID
        }) else { return false }

        guard let characteristic = characteristic(for: actionType, accessory: accessory)
        else { return false }

        let value = targetValue(for: actionType, accessoryValue: action.accessoryValue)

        do {
            try await characteristic.writeValue(value)

            // Se setMode ha una temperatura secondaria, scrivila subito dopo
            if actionType == "setMode", let temp = action.accessoryValue2 {
                let allChars = accessory.services.flatMap(\.characteristics)
                for char in allChars {
                    let t = char.characteristicType.lowercased()
                    if t == Self.heatingThresholdUUID || t == Self.coolingThresholdUUID {
                        try? await char.writeValue(temp)
                    }
                }
            }

            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private Helpers

    /// Restituisce la caratteristica HomeKit corretta per il tipo di azione.
    /// Per setMode e setSpeed sceglie dinamicamente la caratteristica giusta
    /// in base al tipo di servizio primario dell'accessorio.
    private func characteristic(for actionType: String, accessory: HMAccessory) -> HMCharacteristic? {
        let allChars = accessory.services.flatMap(\.characteristics)

        func find(_ uuid: String) -> HMCharacteristic? {
            allChars.first { $0.characteristicType.lowercased() == uuid }
        }

        switch actionType {
        case "on", "off":
            // Preferisci Active (purificatori, termostati) poi PowerState (luci/prese)
            return find(Self.activeUUID) ?? find(Self.onUUID)
        case "dim":
            return find(Self.brightnessUUID)
        case "open", "close":
            return find(Self.positionUUID)
        case "setSpeed":
            return find(Self.rotationSpeedUUID)
        case "setMode":
            // TargetHeaterCoolerState o TargetAirPurifierState a seconda del dispositivo
            return find(Self.targetHeaterCoolerUUID) ?? find(Self.targetAirPurifierUUID)
        case "setTemp":
            return find(Self.targetTempUUID)
        default:
            return nil
        }
    }

    /// Converte il tipo di azione + valore opzionale nel valore da scrivere su HomeKit.
    private func targetValue(for actionType: String, accessoryValue: Double?) -> Any {
        switch actionType {
        case "on":       return 1
        case "off":      return 0
        case "dim":      return Int((accessoryValue ?? 0.5) * 100)
        case "open":     return 100
        case "close":    return 0
        case "setSpeed": return Int((accessoryValue ?? 0.5) * 100)
        case "setMode":  return Int(accessoryValue ?? 0)   // intero modalità (0=Auto, 1=Caldo, 2=Freddo, ecc.)
        case "setTemp":  return accessoryValue ?? 22.0
        default:         return 1
        }
    }
}
