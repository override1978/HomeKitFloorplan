import SwiftUI
import HomeKit

// MARK: - FloorplanLampReader

/// Se un accessorio è una lampada e com'è accesa.
///
/// ⚠️ **Non si passa da `DimmableLightAdapter`**: il suo `init?` richiede la
/// caratteristica luminosità, quindi una lampadina semplice acceso/spento non
/// veniva riconosciuta affatto e restava spenta nel modello. Qui basta il
/// servizio Lightbulb, e la luminosità è un di più.
enum FloorplanLampReader {

    struct Lamp {
        var isOn: Bool
        /// 0…1. Vale 1 su una lampada che non regola la luminosità.
        var brightness: Double
        var colour: UIColor
    }

    /// `nil` solo se **non è una lampada**.
    ///
    /// Una lampada spenta va restituita lo stesso: se esistesse solo da accesa,
    /// non ci sarebbe niente da toccare per accenderla.
    static func lamp(for accessory: HMAccessory, homeKit: HomeKitService) -> Lamp? {
        guard isLight(accessory) else { return nil }

        // Senza `PowerState` ci si affida alla luminosità: alcune lampade
        // dichiarano solo quella, e zero vuol dire spenta.
        let power = characteristic(HMCharacteristicTypePowerState, in: accessory)
        let brightnessCharacteristic = characteristic(HMCharacteristicTypeBrightness, in: accessory)

        let brightness = brightnessCharacteristic
            .flatMap { number(homeKit.value(for: $0) ?? $0.value) }

        let isOn: Bool
        if let power, let raw = number(homeKit.value(for: power) ?? power.value) {
            isOn = raw != 0
        } else if let brightness {
            isOn = brightness > 0
        } else {
            // Nessuno dei due valori è arrivato: meglio spenta che inventata.
            isOn = false
        }

        let hue = characteristic(HMCharacteristicTypeHue, in: accessory)
            .flatMap { number(homeKit.value(for: $0) ?? $0.value) }
        let saturation = characteristic(HMCharacteristicTypeSaturation, in: accessory)
            .flatMap { number(homeKit.value(for: $0) ?? $0.value) }

        let colour: UIColor
        if let hue, let saturation, saturation > 2 {
            colour = UIColor(hue: CGFloat(hue / 360),
                             saturation: CGFloat(saturation / 100),
                             brightness: 1, alpha: 1)
        } else {
            // Bianco caldo: è quello che fa una lampadina da casa, e un bianco
            // puro in un modello già bianco non si distinguerebbe.
            //
            // ⚠️ Alzato da 0,86/0,68: quel beige, messo su una sfera piccola
            // sopra una parete chiara, si leggeva **marrone** invece che caldo.
            // Resta visibilmente caldo, ma dalla parte della luce.
            colour = UIColor(red: 1.0, green: 0.92, blue: 0.80, alpha: 1)
        }

        return Lamp(isOn: isOn,
                    brightness: max(0.15, (brightness ?? 100) / 100),
                    colour: colour)
    }

    static func isLight(_ accessory: HMAccessory) -> Bool {
        accessory.services.contains { $0.serviceType == HMServiceTypeLightbulb }
            || accessory.category.categoryType == HMAccessoryCategoryTypeLightbulb
    }

    private static func characteristic(_ type: String, in accessory: HMAccessory) -> HMCharacteristic? {
        for service in accessory.services {
            for characteristic in service.characteristics where characteristic.characteristicType == type {
                return characteristic
            }
        }
        return nil
    }

    private static func number(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Bool { return value ? 1 : 0 }
        if let value = raw as? NSNumber { return value.doubleValue }
        return nil
    }
}
