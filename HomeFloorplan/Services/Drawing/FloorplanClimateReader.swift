import SwiftUI
import HomeKit

// MARK: - FloorplanClimateReader

/// Se un accessorio scalda o raffredda, e che forma ha in casa.
///
/// ⚠️ **Non si passa da `ThermostatAdapter`**, per lo stesso motivo per cui le
/// lampade non passano da `DimmableLightAdapter`: il suo `init?` pretende le
/// caratteristiche HeaterCooler, e una valvola termostatica espone il servizio
/// `Thermostat` classico. Sarebbe sparita dal modello proprio la famiglia più
/// numerosa. Qui basta uno dei due servizi, e il resto è un di più.
enum FloorplanClimateReader {

    /// Cosa sta facendo **adesso**, che è l'unica cosa che il modello mostra: la
    /// temperatura di destinazione è una cosa da scheda, non da casa vista
    /// dall'alto.
    enum Activity: Equatable {
        case off, idle, heating, cooling

        var isWorking: Bool { self == .heating || self == .cooling }

        /// La freccia che finisce sulla bandierina accanto ai gradi.
        var arrow: String? {
            switch self {
            case .heating: "↑"
            case .cooling: "↓"
            case .off, .idle: nil
            }
        }

        /// Il colore del corpo: caldo se scalda, freddo se raffredda, bianco
        /// da fermo — un impianto che ha finito non ha niente da dire.
        var bodyTint: UIColor {
            switch self {
            case .heating:
                UIColor(red: 0.93, green: 0.63, blue: 0.42, alpha: 1)
            case .cooling:
                UIColor(red: 0.55, green: 0.76, blue: 0.92, alpha: 1)
            case .off, .idle:
                UIColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
            }
        }
    }

    /// Dove sta appeso, che decide la quota predefinita.
    enum Form: Equatable {
        /// Uno split: in alto su una parete.
        case split
        /// Una valvola termostatica: si disegna **il radiatore che comanda**,
        /// in basso. Il cilindretto della valvola e' un dettaglio da mano, non
        /// da stanza: cio' che l'occhio riconosce e' il termosifone.
        case radiator
        /// La centralina dell'antifurto: un pannello a muro, ad altezza mano.
        case securityPanel
        /// Uno schermo TV: pannello sottile a muro, sopra il mobile basso.
        case television

        var defaultHeight: Double {
            switch self {
            case .split:         2.10
            case .radiator:      0.40
            case .securityPanel: 1.40
            case .television:    1.15
            }
        }

        /// Larghezza, altezza e profondità in metri: bastano le proporzioni a
        /// far riconoscere gli oggetti senza modellarli.
        var size: SIMD3<Float> {
            switch self {
            case .split:         SIMD3(0.82, 0.27, 0.19)
            case .radiator:      SIMD3(0.78, 0.55, 0.09)
            case .securityPanel: SIMD3(0.22, 0.30, 0.05)
            case .television:    SIMD3(0.95, 0.55, 0.035)
            }
        }
    }

    struct Unit: Equatable {
        var activity: Activity
        var form: Form
        /// Il colore della **modalità** quando l'unità è accesa: «acceso in
        /// freddo» è un fatto anche quando la stanza è già in temperatura e il
        /// compressore riposa. Il corpo dice cosa fa, il pallino com'è
        /// impostata. `nil` = spenta.
        var modeTint: UIColor?
    }

    /// `nil` solo se **non è un accessorio di clima**.
    static func unit(for accessory: HMAccessory, homeKit: HomeKitService) -> Unit? {
        if let service = service(HMServiceTypeHeaterCooler, in: accessory) {
            let activity = heaterCoolerActivity(service, homeKit: homeKit)
            return Unit(activity: activity,
                        form: form(of: accessory, heaterCooler: service),
                        modeTint: heaterCoolerModeTint(service, activity: activity,
                                                       homeKit: homeKit))
        }
        if let service = service(HMServiceTypeThermostat, in: accessory) {
            let activity = thermostatActivity(service, homeKit: homeKit)
            return Unit(activity: activity,
                        form: form(of: accessory, heaterCooler: nil),
                        modeTint: thermostatModeTint(service, activity: activity,
                                                     homeKit: homeKit))
        }
        return nil
    }

    private static let heatTint = UIColor(red: 0.93, green: 0.63, blue: 0.42, alpha: 1)
    private static let coolTint = UIColor(red: 0.35, green: 0.62, blue: 0.90, alpha: 1)

    /// `Active` (B0) dice se e' accesa; `TargetHeaterCoolerState` (B2) come:
    /// 0 auto, 1 caldo, 2 freddo. In auto decide l'attivita' corrente.
    private static func heaterCoolerModeTint(_ service: HMService, activity: Activity,
                                             homeKit: HomeKitService) -> UIColor? {
        let activeUUID = "000000B0-0000-1000-8000-0026BB765291"
        let targetUUID = "000000B2-0000-1000-8000-0026BB765291"
        guard let active = number(characteristic(activeUUID, in: service), homeKit: homeKit),
              active == 1
        else { return nil }
        let target = number(characteristic(targetUUID, in: service), homeKit: homeKit)
        switch Int(target ?? 0) {
        case 1:  return heatTint
        case 2:  return coolTint
        default: return activity == .heating ? heatTint : coolTint
        }
    }

    /// `TargetHeatingCooling`: 0 spento, 1 caldo, 2 freddo, 3 auto.
    private static func thermostatModeTint(_ service: HMService, activity: Activity,
                                           homeKit: HomeKitService) -> UIColor? {
        let target = number(characteristic(HMCharacteristicTypeTargetHeatingCooling,
                                           in: service), homeKit: homeKit)
        switch Int(target ?? 0) {
        case 1:  return heatTint
        case 2:  return coolTint
        case 3:  return activity == .cooling ? coolTint : heatTint
        default: return nil
        }
    }

    static func isClimate(_ accessory: HMAccessory) -> Bool {
        service(HMServiceTypeHeaterCooler, in: accessory) != nil
            || service(HMServiceTypeThermostat, in: accessory) != nil
    }

    // MARK: - Lettura

    /// `CurrentHeaterCoolerState`: 0 inattivo, 1 in temperatura, 2 scalda, 3 raffredda.
    private static func heaterCoolerActivity(_ service: HMService,
                                             homeKit: HomeKitService) -> Activity {
        guard let raw = number(characteristic(HMCharacteristicTypeCurrentHeaterCoolerState,
                                              in: service), homeKit: homeKit)
        else { return .off }
        switch Int(raw) {
        case 2:  return .heating
        case 3:  return .cooling
        case 1:  return .idle
        default: return .off
        }
    }

    /// `CurrentHeatingCooling`: 0 spento, 1 scalda, 2 raffredda.
    private static func thermostatActivity(_ service: HMService,
                                           homeKit: HomeKitService) -> Activity {
        guard let raw = number(characteristic(HMCharacteristicTypeCurrentHeatingCooling,
                                              in: service), homeKit: homeKit)
        else { return .off }
        switch Int(raw) {
        case 1:  return .heating
        case 2:  return .cooling
        default: return .off
        }
    }

    /// ⚠️ Il servizio non basta: molte valvole termostatiche espongono
    /// `HeaterCooler` come gli split, e finivano appese a due metri. Il
    /// discriminante vero e' la **capacita' di raffreddare**: una valvola non
    /// ha la soglia di raffreddamento, uno split si'.
    private static func form(of accessory: HMAccessory, heaterCooler: HMService?) -> Form {
        if accessory.category.categoryType == HMAccessoryCategoryTypeAirConditioner { return .split }
        guard let heaterCooler else { return .radiator }
        let coolingThresholdUUID = "0000000D-0000-1000-8000-0026BB765291"
        let canCool = heaterCooler.characteristics.contains {
            $0.characteristicType == coolingThresholdUUID
        }
        return canCool ? .split : .radiator
    }

    private static func service(_ type: String, in accessory: HMAccessory) -> HMService? {
        accessory.services.first { $0.serviceType == type }
    }

    private static func characteristic(_ type: String, in service: HMService) -> HMCharacteristic? {
        service.characteristics.first { $0.characteristicType == type }
    }

    /// ⚠️ Si legge `HomeKitService.characteristicValues`, non `HMCharacteristic.value`:
    /// quest'ultimo resta `nil` finché nessuno ha fatto `readValue`.
    private static func number(_ characteristic: HMCharacteristic?,
                               homeKit: HomeKitService) -> Double? {
        guard let characteristic else { return nil }
        let raw = homeKit.value(for: characteristic) ?? characteristic.value
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
}
