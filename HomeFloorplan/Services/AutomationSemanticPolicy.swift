import Foundation

@MainActor
enum AutomationSemanticPolicy {
    static func allowsPromotion(_ pattern: BehavioralPattern) -> Bool {
        switch pattern.patternType {
        case .temporal, .lighting, .scene, .sequential:
            return true
        case .contextual:
            return allowsContextualPromotion(pattern)
        }
    }

    static func reasonBlockingPromotion(_ pattern: BehavioralPattern) -> String? {
        guard pattern.patternType == .contextual,
              !allowsContextualPromotion(pattern) else {
            return nil
        }

        return String(
            localized: "automation.semantic.block.contextual",
            defaultValue: "This pattern was observed, but the sensor condition and target action are not coherent enough to create an automation."
        )
    }

    private static func allowsContextualPromotion(_ pattern: BehavioralPattern) -> Bool {
        guard let conditions = pattern.causeSignature.flatMap(ContextualCondition.parseConditions(fromSignature:)),
              let primary = conditions.first else {
            return false
        }

        // È la condizione PRIMARIA (quella che innesca l'azione) a dover essere
        // semanticamente coerente col target: le secondarie restringono soltanto
        // il contesto. Con l'OR su tutte, una coppia "umidità + lux → luci"
        // passerebbe grazie alla lux anche se a guidare fosse l'umidità.
        return allows(condition: primary, for: pattern)
    }

    private static func allows(condition: ContextualCondition, for pattern: BehavioralPattern) -> Bool {
        let action = pattern.action
        let target = TargetKind(pattern: pattern)

        switch SensorServiceType(rawValue: condition.sensorTypeRaw) {
        case .lightSensor:
            return target == .light && [.on, .off, .dim].contains(action)
                || target == .windowCovering && [.open, .close].contains(action)

        case .temperature, .outdoorTemperature:
            return [.climate, .airCare, .fan, .windowCovering].contains(target)
                || target == .switchLike && isLikelyNamed(pattern, keywords: climateKeywords)

        case .humidity, .outdoorHumidity:
            return [.airCare, .fan].contains(target)
                || target == .switchLike && isLikelyNamed(pattern, keywords: humidityKeywords)

        case .carbonDioxide, .airQuality, .vocDensity, .pm25, .pm10:
            return [.airCare, .fan].contains(target)
                || target == .switchLike && isLikelyNamed(pattern, keywords: airQualityKeywords)

        case .smoke, .carbonMonoxide:
            return [.airCare, .fan, .windowCovering].contains(target)

        case nil:
            return false
        }
    }

    private static func isLikelyNamed(_ pattern: BehavioralPattern, keywords: [String]) -> Bool {
        let haystack = [
            pattern.accessoryName,
            pattern.roomName,
            pattern.naturalLanguageDescription,
            pattern.causeName ?? ""
        ]
        .joined(separator: " ")
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()

        return keywords.contains { haystack.contains($0) }
    }

    private static let climateKeywords = [
        "clima", "climate", "conditioner", "condizionatore", "termostato", "thermostat",
        "riscaldamento", "heating", "cooling", "radiator", "valvola", "fan", "ventola"
    ]

    private static let humidityKeywords = [
        "humid", "umid", "dehumid", "deumid", "ventola", "fan", "bath", "bagno",
        "diffusore", "diffuser"
    ]

    private static let airQualityKeywords = [
        "air", "aria", "purifier", "purificatore", "ventola", "fan", "extractor",
        "co2", "voc", "pm2", "pm10"
    ]

    private enum TargetKind: Equatable {
        case light
        case climate
        case airCare
        case fan
        case windowCovering
        case security
        case switchLike
        case other

        init(pattern: BehavioralPattern) {
            let eventType = pattern.eventTypeRaw
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            let name = pattern.accessoryName
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()

            if eventType.contains("light") || name.contains("luce") || name.contains("light") {
                self = .light
            } else if eventType.contains("thermostat") || eventType.contains("airconditioner") || eventType.contains("climate") || name.contains("clima") || name.contains("termostato") || name.contains("conditioner") {
                self = .climate
            } else if eventType.contains("airpurifier") || eventType.contains("humidifier") || name.contains("purificatore") || name.contains("humid") || name.contains("umid") || name.contains("diffusore") {
                self = .airCare
            } else if eventType.contains("fan") || name.contains("ventola") || name.contains("fan") {
                self = .fan
            } else if eventType.contains("blind") || eventType.contains("windowcovering") || name.contains("tenda") || name.contains("blind") || name.contains("shutter") {
                self = .windowCovering
            } else if eventType.contains("lock") || eventType.contains("garage") || name.contains("serratura") || name.contains("lock") || name.contains("garage") {
                self = .security
            } else if eventType.contains("switch") || eventType.contains("outlet") || eventType.contains("plug") {
                self = .switchLike
            } else {
                self = .other
            }
        }
    }
}
