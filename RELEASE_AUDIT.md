# Home Floorplan Release Audit

Status legend:
- OK: ready or low risk.
- Verify: needs a targeted check before TestFlight/App Store.
- Blocking: should be fixed before external TestFlight or App Store review.

Last audit pass: 2026-06-21

## Executive Summary

Current status: not ready for App Store submission.

Internal TestFlight is possible after a clean Archive and a short release smoke test, but external TestFlight/App Store should wait until privacy, permissions, release/debug exposure, and localization are tightened.

## Build And Project Settings

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| Debug build | OK | Xcode build completed successfully. | Keep building after each release-readiness patch. |
| Release archive | Verify | Normal build is not enough for TestFlight. | Run an Xcode Archive using the Release configuration. |
| Bundle identifier | OK | `com.override1978.Homefloorplan`/project value should be verified in App Store Connect. | Confirm exact bundle ID and capitalization in Apple Developer/App Store Connect. |
| Version/build | Verify | `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`. | Increment build number for each TestFlight upload. |
| Deployment target | Verify | Project currently shows iOS `26.2`. | Confirm this is intentional and compatible with target devices/App Store plan. |
| iPad-only target | OK/Verify | `TARGETED_DEVICE_FAMILY = 2`. | Confirm product is intentionally iPad-only for first release. |
| Info.plist generation | Verify | Project build settings contain generated Info.plist keys plus `HomeFloorplan/Info.plist`. | Inspect archived product Info.plist to ensure usage descriptions are correct. |

## Privacy And App Store Disclosures

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| Privacy manifest | Blocking | `PrivacyInfo.xcprivacy` currently declares generic `OtherDataTypes`. App handles home, sensor, location, activity, AI, and environment data. | Replace generic declaration with accurate data categories and purposes. |
| App Privacy labels | Blocking | App Store Connect labels must match actual collection/use. | Prepare answers for HomeKit/home data, precise/coarse location, diagnostics, user content, identifiers if any. |
| AI data disclosure | Blocking | App may send home/sensor/user prompt context to Claude/OpenAI when enabled. | Add clear in-app disclosure and privacy policy language. |
| API keys | OK/Verify | API keys appear stored in Keychain. | Confirm keys are user-provided and never bundled. |
| Tracking | OK | Privacy manifest says no tracking. | Keep third-party analytics/ad SDKs out unless manifest and labels are updated. |

## Permissions

| Permission | Status | Notes | Action |
| --- | --- | --- | --- |
| HomeKit | OK/Verify | Required for core app behavior. | Confirm permission copy is clear in archived Info.plist. |
| Camera / RoomPlan | OK/Verify | Needed for scanning rooms. | Confirm camera copy references RoomPlan/floorplans. |
| Photo Library | OK | Needed to import floorplan images. | No immediate change. |
| Microphone | Verify | Used by voice assistant. | Ensure voice assistant is optional and request is user-triggered. |
| Speech Recognition | Verify | Used for voice-to-text. | Ensure request is user-triggered and copy is clear. |
| Location When In Use | Verify | Used for home location/geofence setup. | Confirm behavior and copy. |
| Always Location | Blocking/Verify | Sensitive permission. Used by `LocationPresenceService`. | Decide if first release truly needs Always. If yes, add strong UX explanation before prompt. |
| Notifications | Verify | Multiple notification categories. | Ensure notification requests are user-triggered from settings/onboarding. |
| WeatherKit | OK/Verify | Entitlement present. | Confirm WeatherKit is configured in Apple Developer portal. |

## Release/Debug Exposure

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| Debug views | Verify | `AITraceView` and `HabitsDiagnosticsView` are `#if DEBUG`; `HomeKitDebugView` appears reachable in normal UI. | Decide whether HomeKit diagnostics should be hidden in Release or renamed as support diagnostics. |
| Raw `print` calls | Verify | `RuleEngineService.swift` has raw `print(...)` calls. | Convert to `dprint(...)` or wrap in `#if DEBUG`. |
| `dprint` | OK | `DebugLog.swift` compiles `dprint` out in Release. | Keep using `dprint` for diagnostics. |
| Fatal errors | Verify | ModelContainer creation can `fatalError` after wipe failure. | Consider user-facing recovery or crash rationale before App Store. |

## Localization

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| String catalog coverage | Blocking/Verify | `Localizable.xcstrings`: 2583 total, 2544 English, 1650 Italian, about 898 English strings without Italian. | Prioritize user-facing release surfaces; leave DEBUG-only diagnostics lower priority. |
| Automation Builder | OK/Verify | Main builder group was translated to Italian and dynamic placeholders corrected. | Smoke test schedule offsets, location summaries, trigger/condition/action flows in Italian. |
| Automations list/detail | OK/Verify | Main automations group translated to Italian. | Smoke test list, existing automation detail, delete/edit flows. |
| Debug diagnostics | Verify | Many untranslated strings are in DEBUG-only diagnostic views. | Keep out of Release or deprioritize translation. |
| Placeholder safety | Verify | One issue already found: lost `%d` in schedule offset translation. | Add a placeholder audit before every localization batch. |

## HomeKit And Automation Behavior

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| Scene creation/editing | Verify | Shared editor is actively changing. | Regression test scenes with lights, climate, humidifier, purifier, locks, garage. |
| Automation Builder | Verify | Builder is core release surface and has had recent changes. | Regression test time, sun offset, presence, location, sensor trigger/condition, multi-action. |
| Sensor trigger availability | Verify | CO2/PM/etc. depend on HomeKit event notification support at runtime. | Ensure UI/chatbot fail clearly when characteristic is condition-only. |
| Accessory grouping | Verify | Selected action editor now groups multiple services by accessory. | Verify no action selection/saving regression for multi-service accessories. |
| Existing automations | Verify | Unsupported HomeKit automations open in Apple Home. | Test read-only/unsupported paths. |

## AI, Chatbot, And Data Handling

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| AI consent | Verify | `AISettings` tracks data consent. | Confirm first-use flow clearly explains what may be sent to external providers. |
| Claude assistant | Verify | Chatbot tool-use depends on Claude. | Ensure unavailable state is clear when provider/API key missing. |
| OpenAI path | Verify | OpenAI exists for analysis, not full assistant tool-use. | Avoid promising unsupported assistant behavior. |
| Prompt traces | OK/Verify | AI trace logging appears DEBUG-only. | Confirm release build excludes trace UI/logs. |

## Data Persistence And Migration

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| SwiftData schema | Verify | Multiple models, migration wipe fallback exists. | Test upgrade from a previous installed build before TestFlight external. |
| Store wipe fallback | Verify | App wipes default store after migration failure and alerts. | Confirm user-facing alert appears and data-loss wording is acceptable. |
| Retention lifecycle | Verify | Data lifecycle pruning exists. | Confirm retention windows match privacy policy. |
| Cloud sync | OK | Not currently used. | Do not imply cross-device sync in App Store copy. |

## Background Work

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| BGTask identifiers | Verify | `sensorSample`, `ruleEvaluation`, `dataLifecycle` present in Info.plist. | Confirm all scheduled task IDs match permitted identifiers and Apple capabilities. |
| Background claims | Verify | iOS may limit execution. | Avoid App Store copy implying continuous automation/monitoring if not guaranteed. |

## App Store Copy And Review Notes

| Area | Status | Notes | Action |
| --- | --- | --- | --- |
| Privacy policy | Blocking | Required given AI, HomeKit, location, sensor/history data. | Prepare privacy policy before external TestFlight/App Store. |
| Review notes | Verify | Reviewers need HomeKit/RoomPlan/AI setup context. | Provide demo steps, test account/API behavior, and note iPad-only. |
| Screenshots | Verify | UI still has some English in Italian mode. | Capture only after localization pass. |
| App category/name | Verify | Project category utilities; display name varies between project/plist casing. | Confirm final display name and Siri pronunciation plan. |

## Recommended Order

1. Fix release/debug exposure: raw prints and HomeKit diagnostics visibility.
2. Review and correct `PrivacyInfo.xcprivacy`.
3. Decide on Always Location for first release.
4. Run Archive Release and inspect archived Info.plist/entitlements.
5. Localize only visible release surfaces, using small batches and placeholder checks.
6. Run HomeKit/Automation regression smoke test.
7. Upload internal TestFlight.
8. Prepare privacy policy, App Store privacy labels, screenshots, and review notes.

## Smoke Test Checklist

- Launch fresh install.
- Complete onboarding.
- Grant/deny HomeKit and verify both paths.
- Create/import floorplan image.
- Place and control a light.
- Create a scene with a multi-service accessory.
- Create automation with fixed time.
- Create automation with sunrise/sunset offset.
- Create automation with accessory trigger.
- Create automation with condition.
- Create automation with multiple accessory actions.
- Edit existing scene automation.
- Open unsupported automation in Apple Home.
- Enable/disable Smart Lighting.
- Use environment dashboard with WeatherKit location.
- Toggle notifications from settings.
- Test chatbot unavailable state with missing API key.
- Test chatbot proposal review when API key exists.
- Relaunch app and verify persisted state.
- Install over previous build and verify migration.
