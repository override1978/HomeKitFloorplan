import Foundation

/// Azioni correttive one-tap serializzate in `HomeInsight.suggestedActionJSON`.
///
/// Le card del dashboard le decodificano come `AINextAction` e le eseguono via
/// `ActionExecutionService.executeRaw`. Condiviso tra HomeIncoherenceDetector
/// (clima+finestra, luci+lux) e HomeAnomalyDetector (anomalie operative).
enum InsightCorrectiveAction {

    /// JSON di un'azione "spegni accessorio" pronta per suggestedActionJSON.
    static func turnOffJSON(
        accessoryID: String,
        accessoryName: String,
        label: String
    ) -> String? {
        let action = AINextAction(
            label: label,
            actionType: "executeNow",
            accessoryID: accessoryID,
            accessoryActionType: "off",
            accessoryName: accessoryName
        )
        guard let data = try? JSONEncoder().encode(action) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
