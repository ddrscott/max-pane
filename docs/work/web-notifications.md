# Web notifications from a pane

## Problem
macOS `WKWebView` does not implement the Notification API at all, so Slack,
Gmail, Linear, GitHub and every chat app in a pane can neither ask for
permission nor notify. `grep UNUserNotification` over the sources finds nothing.
This is the second biggest daily-driver gap after blocking, because the sites
Scott keeps open all day are the ones that notify.

## Acceptance Criteria
- A page-world user script (in every frame, `atDocumentStart`, following the
  `PaneFullscreen` / `LinkHoverProbe` pattern) defines `window.Notification`
  with `permission`, `requestPermission()`, the constructor, `close()`, and the
  `click` / `show` / `close` / `error` events, forwarding to the pane over a
  `WKScriptMessageHandler`. `Notification.permission` must read the stored
  per-origin answer synchronously, so the answer is injected into the script
  source (or into a `WKUserScript` per data store) rather than fetched.
- `requestPermission()` goes through the existing per-origin ask
  (`AskOrigin`, `WebPaneAsks`, the same sheet camera/mic use), remembered per
  origin per data store like media capture is.
- A granted notification posts through `UNUserNotificationCenter` with the
  site's title, body and icon (fetched, cached, and dropped if it does not
  arrive in time). Clicking it focuses the app, the lane and the pane that
  posted it, and fires the page's `click` event; a pane that has since closed
  is a no-op with a `Log.debug`.
- The app asks macOS for notification permission the first time a site is
  granted, not at launch.
- A pane that is evicted (ADR-0006) still receives notifications only if its
  page is alive; document this limit in the README rather than pretend
  otherwise. Service-worker `showNotification` is out of scope; say so in the
  README.
- Tests in real WebKit (loopback server, as `WebPopupDialogTests` does):
  permission default → `denied` after a refused ask → `granted` after an
  accepted one, surviving a reload; a `new Notification()` reaches a recorded
  `UNUserNotificationCenter` stand-in with the right title and body; the click
  round-trips to the page's handler.

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneAsks.swift`, `WebAsk.swift`, `WebAskCenter.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Web/PaneFullscreen.swift` (the script pattern to copy)
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPopupDelegate.swift` (a popup's page may ask too)
- `swift/MaxPane/Sources/MaxPane/AppDelegate.swift` (`UNUserNotificationCenterDelegate`)
- `swift/MaxPane/Resources/Info.plist` if an entitlement or usage string is needed

## Constraints
- `Notification` on the page must be spec-shaped enough that Slack's and Gmail's
  feature detection passes (`"Notification" in window`,
  `Notification.permission`, `Notification.requestPermission` returning a
  Promise and also taking a callback).
- Never post a notification for a pane that is focused and in the frontmost
  window; that is how Safari behaves and a duplicate is noise.
- The DONE/BLOCKED Dock bounce already exists; do not add a second bounce for
  web notifications.
