# Two WebKit one-liners: pinch zoom and HTTPS upgrade

## Problem
Both are unset on every web view the app builds:

- `allowsMagnification` is false, so a trackpad pinch does nothing in a page.
  Every other Mac browser zooms on pinch.
- `WKWebViewConfiguration.upgradeKnownHostsToHTTPS` is false, so a bare
  `example.com` typed in the address bar stays on `http://` where Safari
  upgrades it. The amber `http://` warning then shows for sites that were
  never meant to be reached that way.

## Acceptance Criteria
- Pinch magnifies the focused web pane. Decide, and record in the code comment,
  how `magnification` relates to `pageZoom` (the ⌘= / ⌘- ladder in
  `PaneZoom`): either pinch drives the same persisted zoom value, stepping to
  the nearest rung on gesture end, or it is a transient view magnification that
  ⌘0 resets. The persisted route is preferred so a pinched zoom survives a
  restart like a ⌘= one does.
- `upgradeKnownHostsToHTTPS = true` on the configuration in `buildWebView`,
  and a test asserting it, in the style of the existing configuration tests.
- Popups inherit both (they copy the pane's configuration; pinch on the
  dialog's view should be set there too).
- README's web-lane section mentions pinch.

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` (`buildWebView`, `wire`, `setZoom`)
- `swift/MaxPane/Sources/MaxPaneKit/Views/WebPopupDialog.swift`
- `PaneZoom` and the zoom tests

## Constraints
- A pinch must not fight the lane's own gestures (two-finger horizontal scroll
  drives the carousel and back/forward). Verify in the running app that a pinch
  over a page does not page the strip.
- Motion rules apply: the zoom step on gesture end animates on `Motion.pane`.
