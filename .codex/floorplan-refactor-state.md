# Floorplan Refactor State

Last updated: 2026-07-17

## Scope

Large refactor of `FloorplanEditorView` to reduce size and isolate fragile floorplan behavior without changing the user-facing workflow.

Current size checkpoint:
- `HomeFloorplan/Views/FloorplanEditorView.swift`: about 1093 lines
- `HomeFloorplan/Views/FloorplanMarkerLayer.swift`: about 71 lines

## Extracted Areas

The refactor already split out:
- floorplan viewport control
- accessory observation
- floorplan image cache loading
- edit room layer
- chrome/help auto-hide lifecycle
- editor presentations
- runtime context
- top bar
- secondary controls layer
- drawing update coordinator
- room tap resolution
- marker collision resolution

Relevant commits:
- `9550ba6` Extract floorplan viewport controller
- `1a9f961` Extract floorplan accessory observation
- `8606fc8` Extract floorplan image cache loader
- `4eb9b1d` Extract floorplan edit room layer
- `3a52412` Extract floorplan chrome lifecycle
- `1d7c146` Extract floorplan editor presentations
- `5a70131` Extract floorplan runtime context
- `568190e` Extract floorplan top bar
- `0375df6` Extract floorplan secondary controls layer
- `b3c1cab` Extract floorplan drawing update coordinator
- `0bcec3f` Extract floorplan room tap resolution
- `d49207e` Fix floorplan sync preflight and marker collisions

## Sync Fixes

CloudKit floorplan sync had recurring `Server Record Changed` / `record to insert already exists` failures.

Current fix:
- Floorplan pending saves preflight the server record.
- If the server record exists, local fields are applied onto the fetched record so the save carries CloudKit's current `recordChangeTag`.
- If the preflight returns `Record not found`, the code falls back to insert, which is expected for a new floorplan.
- Conflicted record names are also persisted for retry across app relaunches.

Healthy observed logs after the fix:
- `Server etag preflight fetch failed ... Record not found`
- followed by `Sent 1 record(s), deleted 0`

This is considered normal for new records.

## Current Decision

Do not move overlay/accessory logic further right now.

Reason:
- The big risky areas have already been isolated.
- Floorplan behavior now appears stable in manual testing.
- Additional extraction of overlay/accessory logic would be mostly structural cleanup and could introduce regressions in gestures, picker state, room filters, edit mode, or sync.

Revisit only if one of these becomes concrete:
- duplicated overlay/accessory behavior
- bugs caused by shared gesture or state interactions
- `FloorplanEditorView` grows materially again
- overlay/accessory policy needs direct unit testing outside SwiftUI
- a new UX change touches overlay behavior substantially

## Known Watch Items

- Picker should open with the correct room filter when tapping outside the image or using `+` in the pill controls.
- `TopBarHeightKey` multiple-update warning was mitigated with a minimum height delta guard.
- UIKit keyboard, RunningBoard, and PointerUI console messages seen during testing are currently treated as system noise unless tied to a reproducible app bug.

