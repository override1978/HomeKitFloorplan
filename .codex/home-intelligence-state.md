# Home Intelligence State

Updated: 2026-07-03

## Current Direction

The Home Intelligence pipeline is being consolidated around one central base:

`specialized producer -> ProactiveIntelligenceService -> PersistedHomeInsight -> UI/dashboard`

`ProactiveIntelligenceService` remains the runtime orchestrator. It is not a duplicate. It coordinates detection, persistence, notification creation, delivery throttling, status propagation, and auto-resolution.

`PersistedHomeInsight` is the unified SwiftData base for signals, anomalies, predictions, opportunities, and device-health items.

## Device/Master Policy

- Every device can collect local data.
- Every device can build local baselines and local anomalies.
- Local/slave devices may show medium+ local anomalies locally.
- Only the master should produce official automations/actions and full AI orchestration.
- If a device becomes master later, it should use its locally collected history rather than starting from zero.
- Do not sync raw telemetry. Future sync should be compact status/baseline/insight metadata only.

## Converged Producers

These now feed `PersistedHomeInsight` through `ProactiveIntelligenceService`:

- `HomeInsightAnomalyPipeline`
- `SensorAnomalyDetector`
- `EnvironmentalAlertBuilder`
- `PredictiveAlertBuilder`
- `AutomationOpportunity`
- `BehavioralDeviationDetector`
- `MaintenancePredictionService`
- `WeatherPredictionSignal`
- `LearningMilestoneSignal`

Each current runtime signal has matching auto-resolution in the central store where appropriate.

## Removed Duplication

The legacy predictive path was removed:

- Deleted `PredictiveAlertEngine.swift`
- Deleted `PredictiveEnvironmentAlert.swift`
- Removed `PredictiveEnvironmentAlert -> HomeInsight` mapper
- Removed `HomeKnowledgeService.predictiveAlerts`
- Dashboard predictive section now reads active prediction insights from `PersistedHomeInsight`

The remaining predictive path is:

`PredictiveAlertBuilder -> ProactiveIntelligenceService -> PersistedHomeInsight -> HomeIntelligenceDashboardView`

## Recent Commits

- `14f1e4d Persist environmental alerts as home insights`
- `7de8a27 Persist predictive and automation insights`
- `248fce3 Persist deviation and maintenance insights`
- `25b81c2 Remove legacy predictive alert engine`

All were pushed by the user.

## Current Known Working State

Last verified:

- Xcode diagnostics clean on touched files
- Full project build succeeded after removing the legacy predictive engine
- Only recurring untracked item is local Xcode state:
  `HomeFloorplan.xcodeproj/xcuserdata/m.cinti.xcuserdatad/xcdebugger/`

## Remaining Work

1. Gradually migrate dashboard summary/attention cards from legacy `PersistedInsight` projections to `PersistedHomeInsight`.
2. Decide how to migrate `AmbientalAIService` from writing only `PersistedInsight` to writing `PersistedHomeInsight` as the primary record.
3. Add lifecycle pruning and CloudKit/status-sync handling for `PersistedHomeInsight` equivalent to the useful parts of the legacy `PersistedInsight` path.
4. Consider a small repository/store abstraction around `PersistedHomeInsight` once more UI reads from it, to avoid repeating SwiftData queries in views.

## Latest Uncommitted Work

- `WeatherPredictionSignal` and `LearningMilestoneSignal` now map to `HomeInsight`.
- Weather suggestions are persisted as `HomeInsight(kind: .prediction, category: .weather)`.
- Learning milestones are persisted as `HomeInsight(kind: .habit, category: .habits, severity: .info)`.
- Environmental auto-resolve now ignores `homeInsight|...` notifications so central anomaly notifications are not resolved by the environmental builder.
- Xcode diagnostics passed for `ProactiveIntelligenceService.swift` and `HomeIntelligenceMappers.swift`.
- Full project build succeeded after this change.

## Architectural Rule

Keep producers small and pure where possible. Do not let dashboard/services independently generate user-facing intelligence if the same signal belongs in the proactive pipeline.

Preferred ownership:

- Detector/builders produce signal structs.
- `ProactiveIntelligenceService` decides persistence, notification, delivery, and lifecycle.
- `PersistedHomeInsight` is the shared base.
- Views read from the shared base.
