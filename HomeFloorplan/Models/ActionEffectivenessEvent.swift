import Foundation
import SwiftData

// MARK: - DismissalReason

/// Reason the user dismissed an AI insight without executing any suggested action.
/// Collected via a 3-option confirmation dialog (Sprint 24.C).
enum DismissalReason: String, CaseIterable {
    /// User already resolved the situation manually before reading the insight.
    case userActedManually = "userActedManually"
    /// The insight was not relevant to the user's current context.
    case irrelevant        = "irrelevant"
    /// Default — user closed without providing specific feedback.
    case unclear           = "unclear"

    var localizedLabel: String {
        switch self {
        case .userActedManually:
            return String(localized: "dismiss.reason.acted",    defaultValue: "Already resolved")
        case .irrelevant:
            return String(localized: "dismiss.reason.irrelevant", defaultValue: "Not relevant")
        case .unclear:
            return String(localized: "dismiss.reason.unclear",  defaultValue: "Close")
        }
    }
}

// MARK: - ActionEffectivenessEvent

/// Registra l'esito di un chip suggerito dall'AI in risposta a un insight ambientale.
///
/// Lifecycle di ogni chip:
///   1. `suggested` → creato da AmbientalAIService al momento dell'insight
///   2. `executed`  → utente ha tappato il chip (eseguito immediatamente)
///      oppure `dismissed` → utente ha dismesso l'insight senza agire
///      oppure `expired`   → insight scaduto (>2h) senza interazione
///
/// Questi dati alimentano ActionEffectivenessTracker per calcolare execution rate
/// per intent e categoria di accessorio.
@Model
final class ActionEffectivenessEvent {
    #Index<ActionEffectivenessEvent>([\.suggestedAt], [\.intentRaw], [\.measurementState])

    // MARK: - Identity

    var id: UUID

    // MARK: - Context

    /// `ActionIntent.rawValue` (es. "coolRoom", "reduceHumidity")
    var intentRaw: String
    /// Nome della stanza al momento del suggerimento.
    var roomName: String
    /// Categoria dell'accessorio selezionato dal resolver (es. "thermostat", "fan").
    /// nil se l'azione era un tip manuale senza accessorio.
    var resolvedCategory: String?
    /// UUID stringa dell'accessorio HomeKit associato.
    /// nil per i tip manuali.
    var accessoryID: String?
    /// Tipo di azione HomeKit (es. "on", "setMode", "tip").
    var accessoryActionType: String?

    // MARK: - Outcome

    /// "executed" | "dismissed" | "expired"
    var outcome: String
    /// DismissalReason.rawValue — nil for non-dismissed outcomes (Sprint 24.C).
    var dismissalReasonRaw: String?

    // MARK: - Timestamps

    /// Momento in cui l'insight è stato generato.
    var suggestedAt: Date
    /// Momento in cui l'utente ha interagito (tapped o dismissed).
    /// nil per outcome "expired".
    var interactedAt: Date?

    // MARK: - Severity

    /// `InsightSeverity.rawValue` al momento del suggerimento.
    var severityRaw: String

    // MARK: - Outcome Measurement (Sprint 5B)
    //
    // Questi campi sono tutti opzionali: nil per eventi precedenti allo Sprint 5B
    // e per azioni senza sensore corrispondente (tip manuali, respondToSmoke, ecc.).
    //
    // Lifecycle measurementState:
    //   nil        → evento pre-5B o senza sensore misurabile
    //   "pending"  → baseline catturata, follow-up non ancora disponibile
    //   "complete" → follow-up ricevuto, delta calcolato
    //   "unreliable" → lettura di follow-up fuori dalla finestra 3-90 min

    /// Tipo sensore monitorato (SensorServiceType.rawValue), es. "humidity", "temperature".
    var sensorTypeRaw: String?
    /// Valore baseline letto immediatamente prima dell'esecuzione HomeKit.
    var baselineValue: Double?
    /// Timestamp della lettura baseline.
    var baselineReadAt: Date?
    /// Valore letto al prossimo campionamento SensorLogger disponibile.
    var followUpValue: Double?
    /// Timestamp del campionamento di follow-up.
    var followUpReadAt: Date?
    /// followUpValue − baselineValue (positivo = aumento, negativo = diminuzione).
    var deltaValue: Double?
    /// Score 0–1: quanto efficacemente l'azione ha mosso il valore nella direzione attesa.
    /// 1.0 = δ ≥ target; 0.0 = nessun miglioramento o peggioramento.
    var effectivenessScore: Double?
    /// Stato della misurazione: nil | "pending" | "complete" | "unreliable"
    var measurementState: String?

    // MARK: - Init

    init(
        intentRaw: String,
        roomName: String,
        resolvedCategory: String? = nil,
        accessoryID: String? = nil,
        accessoryActionType: String? = nil,
        outcome: String,
        dismissalReasonRaw: String? = nil,
        suggestedAt: Date = Date(),
        interactedAt: Date? = nil,
        severityRaw: String,
        sensorTypeRaw: String? = nil,
        baselineValue: Double? = nil,
        baselineReadAt: Date? = nil
    ) {
        self.id = UUID()
        self.intentRaw = intentRaw
        self.roomName = roomName
        self.resolvedCategory = resolvedCategory
        self.accessoryID = accessoryID
        self.accessoryActionType = accessoryActionType
        self.outcome = outcome
        self.dismissalReasonRaw = dismissalReasonRaw
        self.suggestedAt = suggestedAt
        self.interactedAt = interactedAt
        self.severityRaw = severityRaw
        self.sensorTypeRaw = sensorTypeRaw
        self.baselineValue = baselineValue
        self.baselineReadAt = baselineReadAt
        // Follow-up fields start nil; populated by SensorLogger hook (Sprint 5B)
        self.followUpValue = nil
        self.followUpReadAt = nil
        self.deltaValue = nil
        self.effectivenessScore = nil
        self.measurementState = sensorTypeRaw != nil ? "pending" : nil
    }
}
