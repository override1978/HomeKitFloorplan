# Home Floorplan App Store Metadata Draft

This is working copy. Do not paste blindly until the final feature set and privacy policy are confirmed.

## App Name

Home Floorplan

## Subtitle Options

Option A:
Smart Home, Visually Organized

Option B:
Your HomeKit Home, Mapped

Option C:
Floorplans for Apple Home

## Short Promotional Text

Control HomeKit accessories from an interactive floorplan, organize rooms visually, and review smart home suggestions based on your environment and routines.

## Description Draft

Home Floorplan gives your Apple Home setup a visual control layer.

Place accessories on a floorplan, open room details, control lights, climate devices, sensors, covers, locks, and scenes, then build automations with a focused editor designed for real homes.

The app can help you understand environmental trends, review smart home habits, and generate optional AI-assisted suggestions when you choose to configure an AI provider. Your home remains under your control: HomeKit permissions are required for accessory access, and AI features are optional.

Key features:
- Interactive floorplan for HomeKit accessories
- Room-based accessory overview
- Scene and automation creation tools
- Environmental dashboard for compatible sensors
- Smart suggestions for comfort, air quality, and routines
- Optional AI assistant for reviewing home context and actions
- Local-first saved floorplan and app preferences

Home Floorplan is designed for people who want a clearer, more spatial way to manage a HomeKit home.

Some features require compatible HomeKit accessories, sensors, Apple Home permissions, and optional provider configuration for AI features.

## Keywords Draft

homekit,smart home,home automation,floorplan,apple home,lights,sensors,scenes,automation,home control

## What's New Draft

Initial TestFlight and App Store release candidate.

## Review Notes Draft

Home Floorplan requires Apple Home/HomeKit permission to show and control real accessories. No account is required.

Suggested review flow:
1. Launch the app.
2. Grant Home access when prompted.
3. Select an available Home.
4. Open Accessories to inspect grouped HomeKit accessories.
5. Open Floorplan to add or import a floorplan and place accessory markers.
6. Open Scenes or Automations to create or edit HomeKit actions.
7. Open Environment if the Home contains compatible temperature, humidity, air quality, or occupancy sensors.

AI features are optional. If no AI provider/API key is configured, the app should show unavailable or setup states while core HomeKit and floorplan features continue to work.

The app does not require login credentials.

For homes without compatible sensors or accessories, some screens may show empty or limited states.

## External TestFlight Test Details

Please test Home Floorplan with a real Apple Home setup.

Focus areas:
- HomeKit permission and home selection
- Accessory list and room details
- Floorplan marker placement and accessory control
- Scene creation/editing
- Automation Builder flows
- Environmental dashboard with compatible sensors
- Optional AI suggestions if you configure a provider/API key

Please report:
- Crashes or freezes
- Incorrect accessory states
- Automations saved incorrectly
- Confusing labels or missing explanations
- Any case where Home Floorplan behaves differently from Apple Home for the same accessory

Known notes:
- First beta is English-only.
- Some AI and habit suggestions improve after the app has observed recent local activity and sensor context.
- HomeKit automations saved to Apple Home continue through Apple Home; live dashboards and AI context are best tested while the app is open.

## Screenshot Set Plan

Capture final screenshots only after UI text is stable.

Recommended iPad screenshots:
- Floorplan with placed markers.
- Accessories by room.
- Automation Builder.
- Environment dashboard.
- Scene/accessory action editor.

Avoid screenshots showing:
- Debug tools.
- Personal home address/location.
- Real private room names if not intended.
- API keys or provider settings.

---

## App Review Notes (paste into App Store Connect → App Review Information → Notes)

Thank you for reviewing Home Floorplan. Some context that may help:

**WHAT THE APP IS**
Home Floorplan is a HomeKit companion for iPad: users draw the floorplan of their home and see and control their existing Apple Home accessories directly on it (live markers, environment/security overlays). It is designed for iPads used as a wall-mounted home dashboard.

**HOMEKIT DEPENDENCY**
The app requires an Apple Home with accessories to show its full value. Without one:
- First launch shows onboarding and requests HomeKit permission through the system prompt.
- With no home or accessories configured, the app presents guided empty states — it does not crash or appear broken.
- A demo video showing the full experience on a real home is attached to this submission.
Any HomeKit-compatible accessory (including simulated accessories from the HomeKit Accessory Simulator) added to an Apple Home will appear in the app for interactive testing.

**OPTIONAL AI FEATURES**
AI features (environmental suggestions, assistant) are OFF by default and require both (1) the user's explicit in-app consent and (2) the user's own API key for a third-party provider (e.g. Anthropic or OpenAI), stored in the device Keychain. No key ships with the app and no Home Floorplan server exists. All core floorplan and HomeKit features work fully without AI — reviewers do not need an API key.

**DATA & PRIVACY**
- Home data is processed on device; detailed history is kept locally for ~30 days.
- Optional multi-device sync uses the user's private iCloud database (CloudKit). The developer runs no server and cannot access user data.
- Weather comes from Apple WeatherKit, with Apple Weather attribution shown in-app. The optional home/away presence feature uses a single on-device geofence; coordinates are never transmitted.
- Privacy policy: https://gethomefloorplan.app/privacy.html

**OTHER NOTES**
- There is no account or login, so no demo credentials are provided.
- An experimental "Habits (beta)" section is off by default and can be enabled under Settings → Home Intelligence. It is labeled as beta and fully optional.
- If the device is not signed into iCloud, first launch briefly checks for existing data (a few seconds) and then continues locally — this is expected behavior.

Contact for review questions: hello@gethomefloorplan.app
