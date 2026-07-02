# Home Intelligence Domain Audit

Date: 2026-07-02

## Goal

Create a single, convergent domain baseline for home intelligence features:

- `HomeSignalEvent`
- `HomeStateInterval`
- `HomeBaseline`
- `HomeInsight`

The immediate goal is not a large migration. The goal is to avoid losing existing behavior while new Anomaly Detector, Environment, Security, and Habits features move toward one shared model.

## Current Model Inventory

| Area | Current Type | Persistence | Role Today | Target Direction |
| --- | --- | --- | --- | --- |
| Accessory telemetry | `AccessoryEvent` | SwiftData | Point-in-time HomeKit accessory state events. Boolean state plus brightness. | Source adapter into `HomeSignalEvent`; later derive `HomeStateInterval`. |
| Activity log | `ActivityEvent` | SwiftData | UI/activity history for scene executions, writes, external changes. | Not primary telemetry. Can enrich `HomeSignalEvent` source/action metadata where useful. |
| Sensor telemetry | `SensorReading` | SwiftData | Raw environmental sensor readings. | Source adapter into `HomeSignalEvent`. |
| Sensor thresholds | `SensorAlertThreshold` | SwiftData + CloudKit | User/global room thresholds for environment alerts. | Watchdog/anomaly rule input, not insight output. |
| Sensor alert state | `SensorAlertEvent` | SwiftData | Threshold event with triggered/resolved times. | Candidate predecessor of `HomeInsight(type: anomaly/environment)` or `HomeStateInterval` for alert states. |
| Daily environment aggregate | `DailySensorSummary` | SwiftData | Permanent room + sensor daily aggregate. | Input for `HomeBaseline`. Keep. |
| Weekly accessory aggregate | `AccessoryUsageSummary` | SwiftData | Permanent weekly accessory aggregate. | Input for accessory usage `HomeBaseline`. Keep, may need duration fields later. |
| AI action feedback | `ActionEffectivenessEvent` | SwiftData | Outcome of suggested insight action; optional before/after sensor measurement. | Feedback/input for `HomeInsight` quality and future ranking. |
| AI feedback aggregate | `EffectivenessSummary` | SwiftData | Monthly aggregate of action effectiveness. | Input for `HomeBaseline`/ranking, not user-facing insight. |
| Legacy rule | `Rule` | SwiftData | Deprecated in-app/HomeKit rule record. | Keep until fully replaced by `AutomationProposal`/HomeKit builder. Do not build new model around it. |
| Automation proposal | `AutomationProposal` | Codable value | Structured builder input for HomeKit automations. | Remains an action payload referenced by `HomeInsight`. |
| Automation opportunity | `AutomationOpportunity` | SwiftData + CloudKit | Ranked habit/opportunity with trigger/effect/status. | Strong candidate to become `HomeInsight(type: opportunity)` or bridge into it. |
| Legacy AI habit | `HabitPattern` | SwiftData + CloudKit | Older AI habit record with JSON rule suggestion. | Migrate via wrapper, then retire. |
| Local behavioral pattern | `BehavioralPattern` | Codable via store | Structured local pattern with confidence, timing, status. | Source for `HomeBaseline` and `HomeInsight(type: habit/opportunity)`. |
| Persisted behavioral pattern | `PersistedBehavioralPattern` | SwiftData + CloudKit | SwiftData mirror of `BehavioralPattern`. | Temporary bridge; likely replaced by central baseline/insight records. |
| Environment AI insight | `PersistedInsight` | SwiftData + CloudKit | Persisted environmental AI insight and next actions. | Bridge into `HomeInsight(type: environment/anomaly/recommendation)`. |
| Proactive notification | `ProactiveNotification` | SwiftData | Delivery/notification state, dedupe key, status, score. | Delivery layer only. It should not be the primary domain source. |
| Security insight | `SecurityInsight` | Value type | Local computed security insight from current state. | Bridge into `HomeInsight(type: security)` if persisted/surfaced centrally. |
| Predictive env alert | `PredictiveEnvironmentAlert` | Value type | Predicted environmental exceedance. | Bridge into `HomeInsight(type: prediction/environment)`. |
| Floorplan markers | `PlacedAccessory` in `Floorplan` | SwiftData + CloudKit via JSON snapshot | Spatial placement, custom label, icon override. | Not part of intelligence baseline, but useful entity context. |
| Sync settings | `SyncableSettings` | SwiftData + CloudKit | AI/settings/master-device sync source. | Keep; gate AI/domain sync and master analysis ownership. |

## Current Detection And Builder Services

| Service | Inputs | Outputs | Notes |
| --- | --- | --- | --- |
| `AccessoryEventStore` | HomeKit accessory changes | `AccessoryEvent` | Main raw source for device state. |
| `SensorLogger` | HomeKit environmental sensors | `SensorReading`, alert measurement follow-up | Main raw source for environment. |
| `DataLifecycleService` | Raw events/readings | `DailySensorSummary`, `AccessoryUsageSummary`, `EffectivenessSummary`, pruning | Already a good aggregation boundary. |
| `BaselineProvider` | `DailySensorSummary` | `BaselineResult` | Environment baseline exists but is not a central model. |
| `EnvironmentalAlertBuilder` | Recent `SensorReading` | `EnvironmentalSignal` | Threshold/duration based. Can feed `HomeInsight`. |
| `SensorAnomalyDetector` | Recent `SensorReading` | `AnomalySignal` | Already detects oscillating/stuck/out-of-range sensors. |
| `BehavioralDeviationDetector` | `BehavioralPattern`, recent signatures, context | `DeviationSignal` | Detects expected habit not performed. Uses UserDefaults miss counters. |
| `PatternDetectionEngine` | `BehavioralEvent` arrays | `BehavioralPattern` | Local temporal/scene/sequential detection. |
| `BehavioralAnalysisService` | SwiftData + local store | `BehavioralPattern`, `AutomationOpportunity` | Main habit/origin pipeline. |
| `AmbientalAIService` | Environment room state | `AmbientalAIInsight` / `PersistedInsight` | AI naming/recommendation layer. |
| `SecurityScoreService` | HomeKit state | `SecurityInsight` | Local computed security output. |
| `ProactiveIntelligenceService` | Signals/opportunities/deviations | `ProactiveNotification` | Delivery/orchestration layer. |
| `ActionEffectivenessTracker` | Suggested actions and readings | `ActionEffectivenessEvent` | Feedback loop for insight quality. |

## Main Fragmentation Points

1. Event language is split:
   - accessory state: `AccessoryEvent`
   - environmental numeric telemetry: `SensorReading`
   - UI/action log: `ActivityEvent`
   - behavioral analysis input: `BehavioralEvent`

2. Insight language is split:
   - `PersistedInsight`
   - `AutomationOpportunity`
   - `ProactiveNotification`
   - `SecurityInsight`
   - `PredictiveEnvironmentAlert`
   - `EnvironmentalSignal`
   - `AnomalySignal`
   - `DeviationSignal`

3. Baseline is present but not centralized:
   - environment baseline is computed from `DailySensorSummary`
   - accessory usage summary lacks enough duration/state interval detail for robust "too long on/open" detection
   - behavioral confidence is embedded in `BehavioralPattern`

4. CloudKit already syncs several overlapping intelligence outputs:
   - `AutomationOpportunity`
   - `PersistedInsight`
   - `PersistedBehavioralPattern`
   - `HabitPattern`

5. Some state lives outside SwiftData:
   - deviation miss counters in UserDefaults
   - CloudKit sync tokens and caches in UserDefaults
   - runtime settings bridged from `SyncableSettings`

## Proposed Central Domain

### HomeSignalEvent

Purpose: normalized event/reading DTO.

Initial recommendation: start as a value type, not SwiftData. It wraps existing raw sources without changing schema.

Required fields:

| Field | Reason |
| --- | --- |
| `id` | Deduplication and traceability. |
| `sourceKind` | HomeKit, sensor, app, automation, scene, AI, manual. |
| `entityKind` | accessory, sensor, room, home, person, scene. |
| `entityID` | Stable local UUID/string where available. |
| `entityName` | Display/debug fallback. |
| `roomID` / `roomName` | Context and grouping. |
| `signalType` | power, contact, motion, temperature, humidity, lock, battery, reachability, sceneActivation, etc. |
| `value` | Typed payload: bool, double, string, enum. |
| `timestamp` | Event time. |
| `profileID` | Family/profile context where available. |
| `rawSourceID` | Link back to original model (`AccessoryEvent.id`, `SensorReading.id`, etc.). |

Source mappings:

| Source | Mapping |
| --- | --- |
| `AccessoryEvent` | bool/dimmer state event. |
| `SensorReading` | numeric sensor reading. |
| `ActivityEvent` | action/source metadata, not canonical sensor state. |
| `BehavioralEvent` | analysis-specific event, can be rebuilt from `HomeSignalEvent`. |

### HomeStateInterval

Purpose: derived continuous state windows.

Initial recommendation: make this SwiftData only when Anomaly Detector needs durable duration logic. Until then, build intervals in memory from recent `AccessoryEvent`.

Fields:

| Field | Reason |
| --- | --- |
| `id` | Persistence identity. |
| `entityID` / `entityName` | Device/sensor identity. |
| `roomID` / `roomName` | Context. |
| `signalType` | power/contact/motion/lock/presence/etc. |
| `stateRaw` | on/off/open/closed/detected/clear/occupied/vacant. |
| `startedAt` | Duration start. |
| `endedAt` | Nil means active. |
| `durationSeconds` | Cached duration for closed intervals. |
| `sourceEventIDs` | Optional traceability. |
| `confidence` | Useful for reconstructed intervals after app downtime. |

Important gap:

`AccessoryUsageSummary` currently stores counts and average activation hour, but not average/P90/P95 duration. For learned "too long" checks, we need intervals or duration aggregates.

### HomeBaseline

Purpose: stable learned normal behavior/range snapshot.

Initial recommendation: value type first, backed by existing summaries; add SwiftData persistence only when baselines become user-visible or expensive to recompute.

Baseline dimensions:

| Baseline Type | Inputs | Needed For |
| --- | --- | --- |
| environmental range | `DailySensorSummary`, `SeasonalBaselineProvider` | high/low temp, humidity, air quality anomalies. |
| accessory usage frequency | `AccessoryUsageSummary`, `BehavioralPattern` | usage trend and habit context. |
| accessory state duration | future `HomeStateInterval` / enhanced weekly summary | "on/open too long". |
| habit timing | `BehavioralPattern` | missed routine/deviation. |
| action effectiveness | `EffectivenessSummary`, `ActionEffectivenessEvent` | rank suggested actions. |

Fields:

| Field | Reason |
| --- | --- |
| `id` | Stable key. |
| `entityID` / `roomName` | Scope. |
| `signalType` | What the baseline describes. |
| `baselineKind` | range, duration, frequency, timing, effectiveness. |
| `windowRaw` | 7d, 14d, 30d, weekly, monthly. |
| `mean` | Central tendency. |
| `stdDev` | Range confidence. |
| `p90` / `p95` | Smart threshold. |
| `sampleCount` | Confidence. |
| `firstSampleAt` / `lastSampleAt` | Freshness. |
| `confidence` | Whether feature should act on it. |
| `contextKey` | Optional weekday/hour/presence context. |

### HomeInsight

Purpose: one stable domain output for anything the app surfaces as intelligence.

Recommendation: this should become a SwiftData model eventually. During migration, create a wrapper/value representation first and bridge existing records into it. Once consumers move over, persist it and then retire overlapping old records.

Fields:

| Field | Reason |
| --- | --- |
| `id` | Stable identity and CloudKit key. |
| `kind` | anomaly, environment, security, habit, opportunity, prediction, maintenance, deviceHealth. |
| `category` | UI grouping: environment/security/habits/automation/etc. |
| `severity` | info/low/medium/high/critical. |
| `status` | active, resolved, dismissed, snoozed, accepted, executed, expired. |
| `title` / `message` | User-facing display. |
| `whyExplanation` | Explainability. |
| `sourceEntityID` / `sourceEntityName` | Primary device/sensor/room. |
| `roomName` | Grouping. |
| `createdAt` / `updatedAt` | Lifecycle. |
| `startedAt` / `resolvedAt` | Incident lifecycle. |
| `confidence` | Detection confidence. |
| `score` | Optional `IntelligenceScore` equivalent. |
| `dedupeKey` | Avoid duplicate surfacing. |
| `suggestedActionJSON` | Codable action/proposal payload. |
| `sourceRecordType` / `sourceRecordID` | Migration bridge to old model. |
| `syncPolicy` | localOnly / syncStatusOnly / syncFull. |

Bridge mappings:

| Existing Output | HomeInsight Mapping |
| --- | --- |
| `PersistedInsight` | `kind`: environment/anomaly/recommendation based on severity/intelligence level. |
| `AutomationOpportunity` | `kind`: opportunity. Trigger/effect becomes action payload. |
| `SecurityInsight` | `kind`: security. Usually computed; persist only if surfaced/acknowledged. |
| `PredictiveEnvironmentAlert` | `kind`: prediction, category environment. |
| `EnvironmentalSignal` | `kind`: anomaly/environment threshold. |
| `AnomalySignal` | `kind`: anomaly, category environment/deviceHealth. |
| `DeviationSignal` | `kind`: anomaly/habit deviation. |
| `ProactiveNotification` | Delivery record for an insight, not source of truth after migration. |

## CloudKit Direction

Do not sync every new central object by default.

| Type | Initial Sync Policy | Reason |
| --- | --- | --- |
| `HomeSignalEvent` | Do not sync | Raw telemetry is high churn and device-local. |
| `HomeStateInterval` | Do not sync initially | Derived from raw events; sync would create conflicts/churn. |
| `HomeBaseline` | Do not sync initially; maybe sync compact snapshots later | Can be recomputed by master device. |
| `HomeInsight` | Sync stable/user-visible records eventually | Cross-device UX needs same dismissed/resolved/accepted status. |
| Watchdog/rule config | Sync | User configuration must follow devices. |
| Insight status/feedback | Sync | Prevent repeat alerts and support learning. |

Important existing constraints:

- CloudKit is manually managed through `CloudKitSyncService`.
- AI-related sync is gated by `aiIsEnabled && aiHasDataConsent`.
- Master device role is stored in `SyncableSettings.masterDeviceID`.
- Existing synced intelligence records should remain until consumers migrate:
  - `PersistedInsight`
  - `AutomationOpportunity`
  - `PersistedBehavioralPattern`
  - `HabitPattern`

## Migration Plan

### Phase 1: Central Value Layer

No schema change if possible.

- Add value types/enums for `HomeSignalEvent`, `HomeStateInterval`, `HomeBaseline`, `HomeInsight`.
- Add adapters:
  - `AccessoryEvent -> HomeSignalEvent`
  - `SensorReading -> HomeSignalEvent`
  - `PersistedInsight -> HomeInsight`
  - `AutomationOpportunity -> HomeInsight`
  - `SecurityInsight -> HomeInsight`
  - `PredictiveEnvironmentAlert -> HomeInsight`
  - `EnvironmentalSignal -> HomeInsight`
  - `AnomalySignal -> HomeInsight`
  - `DeviationSignal -> HomeInsight`
- Keep old storage and UIs untouched.

### Phase 2: Anomaly Detector On Central Layer

- Build deterministic anomalies from `HomeSignalEvent` and in-memory/recent `HomeStateInterval`.
- Produce `HomeInsight` value objects.
- Render them in one controlled UI surface before writing new persisted records.
- Reuse existing `SensorAnomalyDetector`, `EnvironmentalAlertBuilder`, and `BehavioralDeviationDetector` as producers.

### Phase 3: Persist Stable HomeInsight

Schema change.

- Add `@Model HomeInsightRecord` or make `HomeInsight` the model if naming is clean.
- Persist only stable user-visible insights.
- Add dedupe/status lifecycle.
- Add CloudKit descriptor only after local lifecycle is stable.

### Phase 4: Feature Migration One By One

Order recommendation:

1. Environment: easiest because `PersistedInsight`, `SensorReading`, and `DailySensorSummary` already align.
2. Security: bridge `SecurityInsight` into central insight.
3. Habits: bridge `BehavioralPattern` and `AutomationOpportunity`.
4. Proactive notifications: make delivery reference `HomeInsight` instead of duplicating domain fields.

### Phase 5: Remove Temporary Bridges

Only after no consumer remains:

- retire `HabitPattern` legacy path;
- retire duplicate persisted insight fields or map them into `HomeInsight`;
- reduce `AutomationOpportunity` to an action/proposal payload or migrate it into `HomeInsight`;
- remove mapper code as each feature detaches from the old model.

## Do-Not-Lose Checklist

Keep these behaviors during migration:

- CloudKit floorplan marker sync with custom label and icon override.
- CloudKit deterministic fetch/token reset behavior.
- `SyncableSettings` master-device role and AI consent gating.
- Environment threshold settings and room-specific thresholds.
- Existing AI insight status: dismissed, expired, executed.
- Automation opportunity status: pending, snoozed, approved, dismissed, expired.
- Behavioral pattern status: active, dismissed, approved, decaying, dormant.
- Action effectiveness feedback and follow-up sensor measurement.
- Data lifecycle aggregation and pruning.
- Security monitored accessories setting.
- HomeKit automation builder compatibility; do not resurrect deprecated `Rule` as a primary path.

## Open Decisions

1. Should `HomeInsight` replace `PersistedInsight` immediately, or bridge first?
   Recommendation: bridge first.

2. Should `HomeStateInterval` be persisted in Phase 1?
   Recommendation: no. Build in memory first; persist when duration anomaly needs durable history.

3. Should `HomeBaseline` be synced?
   Recommendation: no initially. Let master compute; sync only user-visible conclusions and config.

4. Should `AutomationOpportunity` become a subtype of `HomeInsight`?
   Recommendation: yes conceptually, but migrate via wrapper first.

5. Should `ProactiveNotification` remain?
   Recommendation: yes, but as delivery/log state, not the canonical domain insight.

