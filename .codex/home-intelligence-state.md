# Home Intelligence State

Updated: 2026-07-04

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
- `bd69501 Add home incoherence insights`
- `a5439df Redesign intelligence dashboard`

Commits up to `a5439df` were created locally; the user said the previous push was done.

## Current Known Working State

Last verified:

- Xcode diagnostics clean on recently touched dashboard/anomaly files
- Full project build succeeded after the dashboard redesign and domain-detail sheet work
- Only recurring untracked item is local Xcode state:
  `HomeFloorplan.xcodeproj/xcuserdata/m.cinti.xcuserdatad/xcdebugger/`

Current uncommitted work after `a5439df`:

- `HomeFloorplan/Views/HomeIntelligenceDashboardView.swift`
- `HomeFloorplan/Services/HomeAnomalyDetector.swift`
- `HomeFloorplan/Localizable.xcstrings`

Do not include the local `xcdebugger/` folder in commits.

Validation already run for this uncommitted work:

- `Localizable.xcstrings` is valid JSON
- Xcode diagnostics clean for `HomeIntelligenceDashboardView.swift`
- Full Xcode build succeeded

Last build log:

`/var/folders/kg/2588s80n1dl6cvylq_ypgbkc0000gn/T/ActionArtifacts/67AAEB48-08F1-4346-9CE8-40F934A17ECE/BuildProject/BuildProject-Log-20260704-013651.txt`

## Dashboard Redesign State

The current intended order in `HomeIntelligenceDashboardView` is:

1. Profile row, if present
2. Hero summary
3. Domain counters / `Anomalie per dominio`
4. Active incoherences
5. Today's anomalies
6. Trend overview
7. Collapsed diary disclosure

The user was very explicit about this order: domain counters must be directly below the hero, then active incoherences, then today's anomalies.

Domain counters are now tappable. Tapping `Aria`, `Clima`, `Luci`, `Carichi`, `Sicurezza`, or `Routine` opens a sheet filtered to that domain. The sheet reuses existing cards:

- `IncoherenceConflictCard` for `kind == .incoherence`
- `IntelligenceEvidenceCard` for anomaly/evidence records
- Empty state when the domain has no active records

Dashboard counters and domain sheets must show user-facing situations, not raw technical records. The current dashboard groups active records by:

- visual domain
- room/source entity
- issue token such as `air-quality`, `temperature`, `open-contact`, `light-on`, `load-on`

When multiple technical sources converge, the card shows a small source-count badge. This keeps debug visibility without showing duplicate/triple anomalies to the user.

This grouping is now owned by `HomeSituationResolver`, not by the dashboard. Consumers should use:

`PersistedHomeInsight -> HomeSituationResolver -> HomeSituation`

The dashboard currently consumes `HomeSituation`. Push, Floorplan overlays, Ambiente, and Sicurezza should migrate to the same layer instead of reading raw `PersistedHomeInsight` directly.

The hero CTA expands/scrolls to the diary via `ScrollViewReader`.

## Home Incoherence State

`HomeIncoherenceDetector` currently produces deterministic cross-domain records into `PersistedHomeInsight` via `ProactiveIntelligenceService`.

Current incoherence rules:

- Climate active while a contact/window is open in the same room
- CO2 rising without ventilation evidence
- Cooling active while room temperature rises

These records use:

- `HomeInsightKind.incoherence`
- `relatedEntityID` / `relatedEntityName` for the second actor where available
- local-only sync policy
- auto-resolution through the central insight lifecycle

The user still wants Intelligence to be more than an Ambiente duplicate. The dashboard now surfaces non-environment operational anomalies, but the underlying detector coverage is still limited.

## Operational Anomaly Fixes

The latest uncommitted changes make operational anomalies visible and readable:

- `HomeIntelligenceDashboardView.activeAnomalyEvidences` now includes low-severity operational evidence for `Luci`, `Carichi`, and `Sicurezza`, not just medium+ anomalies.
- `HomeAnomalyDetector` now renders better titles/recommendations for interval anomalies:
  - Italian: `Luce accesa da molto`, `Presa attiva da molto`, `Dispositivo acceso da molto`, `Finestra o porta aperta`
  - English equivalents are also provided.
- Power interval anomalies are heuristically classified:
  - light-like names -> `.lighting`
  - outlet/load-like names -> `.deviceHealth`
  - generic power -> `.deviceHealth`

Important caveat: this is pragmatic and name-based because `HomeStateInterval` currently does not carry the original `AccessoryEvent.eventType`.

## Known Risk / Next Bug

There may be false positives for `power on for a long time` because old open intervals can survive even when the live HomeKit accessory is actually off.

Next stabilization step should be:

1. Before persisting/showing interval-based power/contact anomalies, validate the interval against current live HomeKit state when `homeKitService` is available.
2. Auto-resolve stale interval anomalies whose live accessory state is now off/closed.
3. Consider adding `eventType` or a `sourceAccessoryKind` to `HomeStateInterval` so lights/outlets/contacts do not need name heuristics.

This matters because stale operational anomalies are more damaging to trust than missing a low-severity item.

## Remaining Work

1. Commit the current uncommitted dashboard/anomaly/localization changes if the user confirms.
2. Validate interval anomalies against live HomeKit state to remove stale light/power/contact false positives.
3. Add first-class accessory kind metadata to `HomeStateInterval` instead of name heuristics.
4. Expand deterministic cross-domain detectors beyond Ambiente:
   - lights left on while nobody is present
   - exterior doors/windows open at night or while away
   - load/outlet active unusually long
   - security mode/contact contradictions
5. Add configurable operational policies for Luci/Prese/Sicurezza, analogous to Ambiente thresholds but not copied 1:1:
   - lights: long-on duration, away/night policies, ignored rooms/accessories
   - outlets/loads: long-active duration, ignored always-on loads, optional high-risk accessory list
   - contacts/security: open duration, night/away severity escalation
   - current implementation: `OperationalIntelligencePolicy` in UserDefaults and `OperationalIntelligencePolicySettingsView` reachable from Notification Settings -> Home Intelligence
6. Gradually migrate any remaining dashboard summary/attention cards from legacy projections to `PersistedHomeInsight`.
7. Decide whether `AmbientalAIService` should treat `PersistedHomeInsight` as the primary record and `PersistedInsight` as legacy/compat only.
8. Add lifecycle pruning and CloudKit/status-sync handling for `PersistedHomeInsight`.

## Architectural Rule

Keep producers small and pure where possible. Do not let dashboard/services independently generate user-facing intelligence if the same signal belongs in the proactive pipeline.

Preferred ownership:

- Detector/builders produce signal structs.
- `ProactiveIntelligenceService` decides persistence, notification, delivery, and lifecycle.
- `PersistedHomeInsight` is the shared base.
- Views read from the shared base.
