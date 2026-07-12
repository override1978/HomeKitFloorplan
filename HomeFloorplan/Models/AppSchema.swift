import Foundation
import SwiftData

/// Unica definizione dello schema SwiftData dell'app.
///
/// Usata da HomeFloorplanApp per il container reale e dai test per i container
/// in-memory. Computed, NON static let: riusare la stessa istanza di Schema per
/// più ModelContainer nello stesso processo fallisce con loadIssueModelContainer.
/// Aggiungere/rimuovere modelli SOLO in questa lista.
enum AppSchema {
    static var schema: Schema { Schema([
        Floorplan.self,
        PlacedAccessory.self,
        ActivityEvent.self,
        SensorReading.self,
        SensorAlertEvent.self,
        SensorAlertThreshold.self,
        AccessoryEvent.self,
        Rule.self,
        ActionEffectivenessEvent.self,
        PersistedInsight.self,
        RoomAnalysisState.self,
        DailySensorSummary.self,
        AccessoryUsageSummary.self,
        EffectivenessSummary.self,
        PersistedHomeInsight.self,
        ProactiveNotification.self,
        AutomationOpportunity.self,
        PersistedBehavioralPattern.self,
        HabitPattern.self,
        SyncableSettings.self,
    ]) }
}
