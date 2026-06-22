# Home Floorplan App Privacy Connect Guide

Last updated: 2026-06-22

This guide is for filling App Store Connect App Privacy. It must match the final build, the published privacy policy, and the actual AI/provider behavior.

Apple's App Privacy form uses structured categories. The exact labels may differ by App Store Connect UI updates, so use this as the source of truth for intent and map it carefully in the form.

## Baseline Position

Home Floorplan is local-first and does not use advertising tracking.

Core HomeKit/floorplan data is primarily processed on device. Data may leave the device only when:

- Apple platform services process HomeKit, App Store, TestFlight, diagnostics, or crash-related data.
- The user configures and uses optional AI features.
- The user explicitly uses platform features such as speech recognition, if enabled.

Do not answer "No data collected" if optional AI features are included in the submitted build and can send prompts/home context to external providers.

## Tracking

Recommended answer for current release:

- Tracking: No

Reason:

- No advertising SDK.
- No cross-app or cross-website tracking for advertising or data broker purposes.

Re-check this if analytics, attribution, ads, or third-party SDKs are added.

## Data Types To Consider

### Location

Declare if the build requests location permission.

Use:

- App Functionality

Notes:

- Used for home location context, weather/environment context, map setup, and geofence setup where available.
- Not used for tracking.

### User Content

Declare if the build supports imported floorplans, user prompts, voice input, notes, scans, or user-created drafts.

Use:

- App Functionality

Examples:

- Floorplan image/file selected by the user.
- Floorplan scan output.
- Marker placement and room layout content.
- AI/chat prompts.
- Voice-transcribed input if voice features are used.

### Other Data / Home Data

App Store Connect may not expose a "HomeKit data" category exactly. Map HomeKit information to the closest available category shown in the form.

Use:

- App Functionality

Examples:

- Home names.
- Room names.
- Accessory names, services, states, and capabilities.
- Scenes and automations.
- Sensor readings and local summaries.
- Activity/event history.

Notes:

- If App Store Connect asks whether this is linked to the user, be conservative when data can be sent to AI providers. Locally stored only data is not collected by the developer, but AI-submitted context is processed externally.

### Usage Data

Declare only if the submitted build collects usage analytics or action-effectiveness data in a way that leaves the device or is collected by the developer/provider.

For current app behavior:

- Local action-effectiveness and activity history are app functionality data stored on device.
- If this data is sent to AI as context, include it under the AI-related data disclosure.
- If no analytics SDK exists, do not mark analytics use.

### Diagnostics

Apple crash and diagnostics may be available through Apple developer tools. If no separate third-party crash SDK is included, keep the answer limited to Apple's platform behavior.

If a third-party crash/analytics SDK is added later, update this section and the privacy policy.

### Identifiers

Do not declare advertising identifiers unless the app actually uses them.

If provider account identifiers, device identifiers, or user IDs are added later, update this guide and policy.

### Sensitive Information

Avoid collecting sensitive information unless absolutely required. Home names, room names, and smart-home context may be privacy-sensitive in practice, so treat policy language conservatively even if App Store Connect maps them under broader categories.

## Data Linked To The User

Suggested stance:

- Local-only data: not collected by the developer.
- AI-submitted data: may be linked or linkable depending on provider/API key/account and request metadata.

If the form requires a binary answer for data sent to an AI provider, prefer the conservative answer.

## Purposes

Recommended purposes for declared data:

- App Functionality
- Product Personalization, only if App Store Connect considers local/AI suggestions personalization and the data is sent/collected.

Avoid declaring:

- Third-Party Advertising
- Developer Advertising or Marketing
- Analytics, unless a real analytics collection path exists.

## Final Verification Before Submission

- Confirm Release build does not expose debug screens.
- Confirm no analytics/ad SDK is included.
- Confirm AI provider setup and consent copy match the policy.
- Confirm API keys are not bundled.
- Confirm HomeKit, location, camera, photos, microphone, speech, notifications permission texts match actual use.
- Confirm published `privacy.html` is reachable without login.
- Confirm App Privacy answers match this guide and published policy.
