import Foundation

// MARK: - EnergyFormat

/// I formati dei numeri energia, in un posto solo: monitor e analisi devono
/// scrivere «12,4 kWh» nello stesso identico modo.
enum EnergyFormat {

    static func kilowattHours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(value < 10 ? 2 : 1))) + " kWh"
    }

    static func watts(_ watts: Double) -> String {
        watts.formatted(.number.precision(.fractionLength(watts < 10 ? 1 : 0))) + " W"
    }

    /// `nil` a tariffa zero: i costi compaiono solo se l'utente li ha chiesti.
    static func cost(_ kilowattHours: Double, tariffPerKWh: Double) -> String? {
        guard tariffPerKWh > 0 else { return nil }
        return (kilowattHours * tariffPerKWh)
            .formatted(.currency(code: Locale.current.currency?.identifier ?? "EUR")
                .precision(.fractionLength(2)))
    }
}
