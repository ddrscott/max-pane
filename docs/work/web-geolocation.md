# Geolocation in a web pane

## Problem
`navigator.geolocation` in a macOS `WKWebView` prompts through
`CoreLocation` only when the app has a location usage string and the process
has been granted access; today `grep geolocation` over the sources and
`Info.plist` finds nothing, so Maps, weather and store-locator pages fail with
a silent `PERMISSION_DENIED`.

## Acceptance Criteria
- `NSLocationUsageDescription` in `Info.plist`, worded for the user ("A web
  page asked where you are").
- A per-origin ask through the existing `AskOrigin` / `WebPaneAsks` sheet
  before the page ever reaches CoreLocation, remembered per origin per data
  store like camera and mic. WebKit on macOS has no public geolocation
  delegate; verify whether a granted TCC prompt is enough for WebKit to answer
  the page, or whether a page-world shim (like the notifications task) that
  reads `CLLocationManager` and answers `getCurrentPosition` /
  `watchPosition` is required. Record which in the code comment.
- Denied at the app level (System Settings) is reported to the page as
  `PERMISSION_DENIED` promptly, not as a timeout.
- Tests: the ask is raised once per origin and remembered; a real-WebKit test
  with a stubbed location source answers `getCurrentPosition` with the stubbed
  coordinates.

## Relevant Files
- `swift/MaxPane/Resources/Info.plist`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneAsks.swift`, `WebAsk*.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPopupDelegate.swift`

## Constraints
- Never grant without the per-origin ask, even when TCC is already granted.
- Hardened runtime and notarisation are in place (`scripts/make-dmg.sh`);
  a new entitlement must be added to the entitlements file the script signs
  with, and the release checked.
