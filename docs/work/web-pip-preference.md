# Picture-in-picture: turn on WebKit's macOS preference, then prove the window survives eviction

## Problem
Verified 2026-09-16 (`docs/acceptance.md`, "Passkeys and picture-in-picture"):
`video.webkitSupportsPresentationMode('picture-in-picture')` is `false` in every
web pane and `requestPictureInPicture()` rejects with `NotSupportedError`, so no
site can offer PiP. The cause is WebKit's page setting
`allowsPictureInPictureMediaPlayback`, whose default is `false` on macOS and
which `WKWebView` only copies from the configuration on iOS. WebKit's own macOS
MiniBrowser sets it through SPI:
`configuration.preferences._allowsPictureInPictureMediaPlayback = YES`.

## Acceptance Criteria
- `WebPaneController`'s configuration turns the preference on. The SPI is a
  property on `WKPreferences`, so from Swift it is KVC:
  `configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")`
  (KVC finds `_setAllowsPictureInPictureMediaPlayback:`). Match how the file
  already reaches other SPI, and comment why the public property is not used
  (`API_AVAILABLE(ios(9.0))`).
- A popup's configuration is copied from the pane's and inherits it; say so in
  the same comment as the other inherited settings.
- A real-WebKit test pins it: a `<video>` with a loaded source reports
  `webkitSupportsPresentationMode('picture-in-picture') === true`.
- Manual, in a throwaway instance, written up in `docs/acceptance.md`: the PiP
  glyph appears in the native controls and on YouTube and Vimeo; a PiP window
  keeps playing when the pane is evicted (ADR-0003) and when the lane is closed,
  with no crash either way; `PaneFullscreen` still fills the pane on the first
  fullscreen request while a PiP window is up.

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` (the
  `WKWebViewConfiguration` block around `isElementFullscreenEnabled`)
- `swift/MaxPane/Sources/MaxPaneKit/Web/PaneFullscreen.swift`
- `swift/MaxPane/Tests/` — the real-WebKit suites, run with
  `env -u MAXPANE_SOCKET MAXPANE_PROFILE=tests ./scripts/test.sh --skip WebPrintTests`
- `docs/acceptance.md`

## Constraints
- Private SPI: check the App Store is not a target before shipping (it is not,
  today — Developer ID and a DMG), and note the KVC key in the README's WebKit
  section so a future macOS rename is a one-line find.
- Never drive the owner's running instance; `MAXPANE_PROFILE=verify` and a
  separate `MAXPANE_APP` bundle.
