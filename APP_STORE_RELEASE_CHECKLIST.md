# Home Floorplan App Store Release Checklist

Last updated: 2026-06-22

Status legend:
- Done: completed and verified.
- Todo: needed before App Store submission.
- Risk: likely App Review or product risk.
- Later: can wait until after 1.0 if clearly not promised in App Store copy.

## Current Release Position

Current target: first public App Store release after external TestFlight feedback.

Current recommendation: do not submit to App Store until the external beta build has completed at least one real-home smoke test cycle and the privacy policy/App Privacy answers are final.

## Build And Distribution

| Item | Status | Notes |
| --- | --- | --- |
| Clean Debug build | Done | Xcode build succeeded after the latest local changes. |
| TestFlight upload | Done | First external beta build uploaded and distributed to App Store Connect. |
| External TestFlight public link | Done | Public link created; waiting/using Beta App Review flow as needed. |
| New build after local fixes | Todo | Curtain mapping, language lock, and floorplan help changes require a new archive/upload. |
| Version/build numbering | Todo | Increment build number for every TestFlight/App Store upload. |
| Release archive check | Todo | Archive, validate, upload, then confirm no new processing warnings. |
| App Store final build selection | Todo | Select the final stable build in the App Store version page. |

## Product Readiness

| Item | Status | Notes |
| --- | --- | --- |
| Language for 1.0 | Done | First release is locked to English to avoid partial localization regressions. |
| Automation Builder smoke test | Todo | Test time, sunrise/sunset offset, trigger, condition, multi-action, scene action. |
| Curtain open/close semantics | Todo | Verify per-accessory "Reverse open/close" on real devices, then upload a new build. |
| Floorplan first-use help | Todo | Verify first launch help appears once and info button reopens it. |
| Accessory multi-service actions | Todo | Verify diffuser/light/humidifier services are selectable and saved correctly. |
| AI suggestions and habits | Todo | Test with foreground usage and explain limitations in review notes/copy. |
| HomeKit unavailable path | Todo | Launch with no Home access or denied HomeKit permission and verify graceful UI. |
| Migration/install-over build | Todo | Install over TestFlight/local build and confirm local data survives. |
| Unsupported HomeKit automation path | Todo | Verify unsupported automations open in Apple Home or show a clear explanation. |

## App Store Connect Metadata

| Item | Status | Notes |
| --- | --- | --- |
| App name | Todo | Confirm final public display name and App Store name. |
| Subtitle | Todo | Draft available in `APP_STORE_METADATA_DRAFT.md`. |
| Description | Todo | Draft available in `APP_STORE_METADATA_DRAFT.md`. |
| Keywords | Todo | Draft available in `APP_STORE_METADATA_DRAFT.md`; keep under Apple limit. |
| Category | Todo | Suggested: Lifestyle or Utilities. Decide based on positioning. |
| Age rating | Todo | Complete App Store Connect questionnaire honestly; likely low age rating. |
| Support URL | Todo | Needs a live public URL. |
| Marketing URL | Later | Optional for 1.0. |
| Privacy Policy URL | Todo | Required for iOS App Store distribution. Publish `site/privacy.html` and use the public URL. |
| Copyright | Todo | Add owner/company legal name/year. |
| Screenshots | Todo | Capture after final UI copy and build are stable. |
| App Review notes | Todo | Draft available in `APP_STORE_METADATA_DRAFT.md`. |

## Privacy And Data

| Item | Status | Notes |
| --- | --- | --- |
| Privacy policy | Done/Todo | Submission-oriented policy text exists in `PRIVACY_POLICY_DRAFT.md` and `site/privacy.html`; publish a real URL before submission. |
| App Privacy labels | Todo | Use `APP_PRIVACY_CONNECT_GUIDE.md`; answers must match actual collection and third-party processing. |
| HomeKit/home data disclosure | Done/Verify | Policy covers home structure, accessories, rooms, scenes, automations, states, and sensor readings. Map to closest App Store Connect category. |
| Location disclosure | Done/Verify | Policy covers home location, weather/context, map setup, and geofence setup with When In Use location. |
| AI provider disclosure | Done/Verify | Policy covers optional AI prompts, HomeKit context, sensor summaries, insight/habit/action context sent to selected providers. |
| API key handling | Todo | Confirm keys are user-provided, stored in Keychain, and not bundled. |
| Tracking | Done/Risk | No tracking should be declared only if no analytics/ad SDK tracks users. Re-check before submission. |
| Data retention | Todo | Align policy with local history pruning and user deletion behavior. |
| Privacy manifest report | Todo | Generate archive privacy report and confirm third-party SDK manifests. |

## Permissions And Capabilities

| Item | Status | Notes |
| --- | --- | --- |
| HomeKit usage text | Todo | Confirm archived Info.plist copy is clear. |
| Location When In Use text | Todo | Confirm no Always permission is requested in first release. |
| Camera/RoomPlan text | Todo | Confirm only requested from user-triggered scan/import flows. |
| Photos text | Todo | Confirm copy matches floorplan import usage. |
| Microphone/Speech text | Todo | Confirm voice assistant is optional and user-triggered. |
| Notifications | Todo | Request only from a clear user action/settings flow. |
| WeatherKit capability | Todo | Confirm entitlement and Developer portal setup. |
| Background task identifiers | Risk | Verify IDs match scheduled tasks and avoid App Store copy implying continuous background AI. |

## Review Risk Controls

| Risk | Status | Mitigation |
| --- | --- | --- |
| Reviewer has no HomeKit home | Todo | Add review notes explaining HomeKit dependency and provide demo path if available. |
| AI feature needs external key/provider | Todo | Add review notes: AI is optional; core HomeKit/floorplan features work without it, or provide test setup. |
| App claims background intelligence | Risk | Avoid "continuous" claims. Say suggestions improve while the app is used and data is available. |
| Partial localization | Done for 1.0 | English locked for beta/1.0 until localization is complete. |
| Privacy mismatch | Risk | Do not submit until App Privacy labels and policy match actual data flow. |
| Debug tools exposed | Todo | Verify Release archive does not expose HomeKit Debug/diagnostic screens. |

## Final Pre-Submission Smoke Test

- Fresh install.
- Install over previous build.
- HomeKit permission allow and deny.
- Add/import floorplan.
- First-use floorplan help.
- Place marker and control accessory.
- Long-press marker detail.
- Accessory list and room detail.
- Window covering normal mapping.
- Window covering reversed mapping.
- Scene creation/edit.
- Automation with fixed time.
- Automation with sunrise/sunset offset.
- Automation with accessory trigger.
- Automation with condition.
- Automation with multiple actions.
- Environment dashboard with sensors.
- AI suggestion with provider configured.
- AI unavailable state with no provider/key.
- Notification settings.
- Relaunch persistence.
- Release archive install.

## Apple References

- Submitting apps: https://developer.apple.com/app-store/submitting/
- Submit an app: https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Manage app privacy: https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
