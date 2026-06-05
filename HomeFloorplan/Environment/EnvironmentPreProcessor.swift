import Foundation

// MARK: - RoomType

/// Classificazione semantica di una stanza per guidare le decisioni AI e il filtro degli intent.
enum RoomType: String, Codable, CaseIterable {
    case indoor  = "indoor"
    case outdoor = "outdoor"
    case utility = "utility"
    case transit = "transit"
}

// MARK: - RoomClassifier

/// Classifica una stanza per nome usando keyword italiane.
/// Stateless — tutti i metodi sono statici.
enum RoomClassifier {

    private static let outdoorKeywords: [String] = [
        "balcone", "terrazzo", "giardino", "garden", "patio",
        "cortile", "portico", "veranda"
    ]

    private static let utilityKeywords: [String] = [
        "lavanderia", "garage", "cantina", "ripostiglio", "soffitta"
    ]

    private static let transitKeywords: [String] = [
        "ingresso", "corridoio", "disimpegno", "scale", "pianerottolo"
    ]

    /// Classifica il nome della stanza in un RoomType.
    /// - Parameters:
    ///   - roomName: Nome della stanza da classificare.
    ///   - outdoorRoomName: Nome stanza outdoor impostato dall'utente (AppStorage "outdoorRoomName").
    ///                      Se corrisponde esattamente (case-insensitive) → `.outdoor` con precedenza massima.
    static func classify(roomName: String, outdoorRoomName: String = "") -> RoomType {
        let lower = roomName.lowercased()

        // Override esplicito dell'utente ha priorità assoluta
        if !outdoorRoomName.isEmpty,
           lower == outdoorRoomName.lowercased() {
            return .outdoor
        }

        if outdoorKeywords.contains(where: { lower.contains($0) }) { return .outdoor }
        if utilityKeywords.contains(where: { lower.contains($0) }) { return .utility }
        if transitKeywords.contains(where: { lower.contains($0) }) { return .transit }
        return .indoor
    }
}

// MARK: - SensorStatusEntry

/// Stato pre-valutato di un sensore, serializzabile direttamente nel payload LLM.
/// Sostituisce l'invio di valori grezzi + soglie al modello.
struct SensorStatusEntry: Codable {
    /// SensorServiceType.rawValue (es. "temperature", "humidity").
    let type: String
    /// Valore corrente del sensore.
    let value: Double
    /// Urgency deterministica: "normal" | "warning" | "danger".
    let urgency: String
    /// Deviazione dalla media storica in sigma. Nil se baseline insufficiente (< 5 letture).
    let deviationSigma: Double?
    /// True se |deviationSigma| > anomalyThreshold (1.5σ).
    let isAnomaly: Bool
    /// Direzione dell'anomalia statistica: "high" | "low" | "none".
    /// "high" = valore significativamente sopra la media storica.
    /// "low"  = valore significativamente sotto la media storica.
    /// "none" = deviazione nella norma (|σ| ≤ anomalyThreshold).
    let anomalyDirection: String
    /// True se l'anomalia è actionable, cioè richiede attenzione reale.
    /// Per anomalie "high": sempre true quando isAnomaly.
    /// Per anomalie "low": solo se il valore è anche sotto la soglia bassa di comfort
    ///   (es. humidity < 40%). Evita falsi positivi per valori statisticamente bassi
    ///   ma ancora nel range di comfort (es. 52% con baseline 61%).
    let actionableAnomaly: Bool
}

// MARK: - PreProcessorResult

/// Risultato del pre-processing deterministico di una stanza.
struct PreProcessorResult {
    /// Stato pre-valutato di ogni sensore nella stanza.
    let sensorStatuses: [SensorStatusEntry]
    /// Tipo di stanza classificato deterministicamente.
    let roomType: RoomType
    /// Gate AI: false = salta la chiamata API (tutto nella norma).
    let shouldCallAI: Bool
    /// Severità massima che l'LLM può assegnare (clamping post-parsing).
    let severityCeiling: InsightSeverity
}

// MARK: - EnvironmentPreProcessor

/// Pre-processore deterministico dell'ambiente.
/// Calcola stato sensori, tipo stanza, gate AI e severità ceiling
/// PRIMA di costruire il payload LLM.
///
/// Stateless — tutti i metodi sono statici.
enum EnvironmentPreProcessor {

    /// Soglia di anomalia statistica in sigma. Valori |σ| > 1.5 sono considerati anomali.
    static let anomalyThreshold: Double = 1.5

    // MARK: - Pre-Processing

    /// Esegue il pre-processing completo per una stanza.
    /// - Parameters:
    ///   - room: Dati ambientali correnti della stanza.
    ///   - baselineByType: Baseline 7 giorni pre-calcolata: [serviceType.rawValue: (avg, stdDev)].
    ///   - outdoorRoomName: Nome stanza outdoor da UserDefaults (AppStorage "outdoorRoomName").
    static func preProcess(
        room: RoomEnvironmentData,
        baselineByType: [String: (avg: Double, stdDev: Double)],
        outdoorRoomName: String = ""
    ) -> PreProcessorResult {

        let roomType = RoomClassifier.classify(roomName: room.roomName, outdoorRoomName: outdoorRoomName)

        var sensorStatuses: [SensorStatusEntry] = []
        var worstUrgency: SensorUrgency = .normal

        for sensor in room.sensors {
            let urgency = sensor.urgency
            if urgency > worstUrgency { worstUrgency = urgency }

            // Calcola deviazione dalla baseline se disponibile
            var sigma: Double? = nil
            var isAnomaly = false
            var anomalyDirection = "none"
            var actionableAnomaly = false

            if let baseline = baselineByType[sensor.serviceType.rawValue],
               baseline.stdDev > 0 {
                let deviation = (sensor.currentValue - baseline.avg) / baseline.stdDev
                sigma = Double(round(deviation * 100) / 100)   // 2 decimali per il trace
                isAnomaly = abs(deviation) > anomalyThreshold

                if deviation > anomalyThreshold {
                    anomalyDirection = "high"
                    // Anomalia alta: actionable se c'è già urgency oppure il valore
                    // è sopra la soglia warning (duplice protezione per sensori senza urgency)
                    actionableAnomaly = true
                } else if deviation < -anomalyThreshold {
                    anomalyDirection = "low"
                    // Anomalia bassa: actionable SOLO se il valore è anche sotto
                    // la soglia bassa di comfort del tipo di sensore.
                    // Senza questo guard, valori come humidity=52% con baseline=61%
                    // aprirebbero il gate AI anche quando 52% è perfettamente accettabile.
                    if let lowWarn = sensor.serviceType.defaultLowWarning {
                        actionableAnomaly = sensor.currentValue < lowWarn
                    } else {
                        // Tipo senza soglia bassa (CO, fumo, VOC…): anomalia bassa non actionable
                        actionableAnomaly = false
                    }
                }
                // deviation in range [-threshold, +threshold]: anomalyDirection="none", actionableAnomaly=false
            }

            let entry = SensorStatusEntry(
                type: sensor.serviceType.rawValue,
                value: sensor.currentValue,
                urgency: urgencyString(urgency),
                deviationSigma: sigma,
                isAnomaly: isAnomaly,
                anomalyDirection: anomalyDirection,
                actionableAnomaly: actionableAnomaly
            )
            sensorStatuses.append(entry)
        }

        // AI Call Gate: chiama l'AI solo se urgency è elevata OPPURE c'è
        // un'anomalia actionable (cioè statisticamente anomala E fuori dal comfort range).
        // Questo previene le chiamate AI per valori statisticamente bassi ma ancora
        // nel range di comfort (es. humidity 52% con baseline 61%).
        let hasAbnormal = sensorStatuses.contains { $0.urgency != "normal" || $0.actionableAnomaly }
        let shouldCallAI = hasAbnormal

        let ceiling = severityCeiling(for: worstUrgency)

        return PreProcessorResult(
            sensorStatuses: sensorStatuses,
            roomType: roomType,
            shouldCallAI: shouldCallAI,
            severityCeiling: ceiling
        )
    }

    // MARK: - Severity Clamping

    /// Clamp la severity LLM al ceiling deterministico.
    /// Garantisce che il modello non possa assegnare severità più alta di quella giustificata dai dati.
    static func clampSeverity(
        _ llmSeverity: InsightSeverity,
        ceiling: InsightSeverity
    ) -> InsightSeverity {
        min(llmSeverity, ceiling)
    }

    // MARK: - Intent Filtering

    /// Filtra gli intent per tipo di stanza.
    /// - Intent HVAC/ventilazione rimossi per stanze outdoor (nonsensical).
    /// - Intent di sicurezza (smoke, CO) passano sempre.
    static func filterIntents(
        _ intents: [ActionIntent],
        for roomType: RoomType
    ) -> [ActionIntent] {
        guard roomType == .outdoor else { return intents }

        // coolRoom is NOT blocked outdoors — its fallbackTip produces "Attiva la tenda da sole"
        // heatRoom and ventilateRoom are suppressed (no HVAC/ventilation outdoors makes sense)
        let outdoorBlocked: Set<ActionIntent> = [.heatRoom, .ventilateRoom]
        return intents.filter { !outdoorBlocked.contains($0) }
    }

    // MARK: - Private Helpers

    private static func urgencyString(_ urgency: SensorUrgency) -> String {
        switch urgency {
        case .normal:  return "normal"
        case .warning: return "warning"
        case .danger:  return "danger"
        }
    }

    private static func severityCeiling(for worstUrgency: SensorUrgency) -> InsightSeverity {
        switch worstUrgency {
        case .normal:  return .info
        case .warning: return .warning
        case .danger:  return .anomaly
        }
    }
}
