# A page's popup opens as a dialog over the window, never as a lane

The owner: *"browser popups should not open new panes. This happens a lot during
Oauth sign in and breaks the lanes flow and causes too many lanes to appear and
lose focus. I was trying to sign in to LinkedIn using Google account and didn't
see the lane and clicked sign in a bunch more times. There must be some way to
integrate these pop ups in a more streamlined way using the new shared dialog
component … this app needs to be a sufficient replacement for both iTerm and my
browser as a daily driver."*

## Problem

Detection is already right; placement is what breaks. `PopupPolicy`
(`Web/WebPopup.swift`) correctly tells a *conversation* (`window.open` with a size,
without chrome, or scripted — the OAuth popup) from a *destination*
(`target=_blank`, ⌘-click). For a conversation, `WebPaneController.openPopup`
(~`WebPaneController.swift` 1400–1450) builds a `ChromeWebView` from WebKit's own
configuration — which is what keeps `window.opener` and `postMessage` working —
stages it in `PopupHandoff`, and then **writes a new web lane** beside the opener
for a pane to adopt it. That is where every symptom comes from:

- the lane lands right of the opener, which may be scrolled away, docked, or under
  the gallery — so the sign-in form is somewhere he cannot see;
- focus jumps to it;
- each further click on "Sign in" writes another lane;
- a transient sign-in window becomes a durable, ledger-backed lane restored on the
  next launch;
- when it closes itself (`webViewDidClose` → `closePane`), the keyboard is not
  handed back to the page that opened it.

## Design

- **A `.popup` becomes a dialog, never a lane or a ledger row.** A new
  `WebPopupDialog` built on the shared `Popup` (`Views/Popup.swift`): square,
  centred over the main window whatever the opener's state (strip, gallery, dock,
  scrolled off), easing in and out. `.lane` — `target=_blank` and ⌘-click — is
  unchanged: those are pages he meant to read.
- **Same web view, same opener.** The dialog hosts the `ChromeWebView` WebKit's
  configuration built, so `window.opener`, `postMessage` and the shared cookie jar
  keep working. Keep the existing data-store check in `openPopup`.
- **Size from the page.** `WKWindowFeatures` width/height when given, clamped by
  `Popup.frame`'s margins; a sensible default (about 520 × 680) when not.
- **The real origin is always on screen.** A one-row bar: the security glyph and
  host from the same logic the chrome bar uses (`BrowserAddress.security`), so
  `accounts.google.com` is readable at a glance; the full URL on hover, ⌘C to copy;
  the load hairline; ✕. No editable address.
- **It closes the way a sign-in window should.** On Esc or ✕; when the page calls
  `window.close()`; when its opener pane closes or its opener navigates away. **Not
  on a click away** (`.explicitOnly`) — clicking back into the page must not throw
  away a half-finished sign-in.
- **One per opener.** While a dialog is open for a pane, another `window.open` from
  that pane replaces it (crossfade) instead of stacking or writing a lane — which
  is exactly the repeated "Sign in" clicks. A popup opened *from* the popup (an
  account chooser) stacks as a child dialog over it.
- **The keyboard goes home.** The dialog is key while open; when it closes, focus
  returns to the opener pane and its lane is revealed if it is not on screen.
- **Everything a page can ask still works inside it**, against the popup's own
  origin: `alert`/`confirm`/`prompt`, HTTP auth, file inputs, ⌥⌘L password fill,
  downloads. A `target=_blank` link inside the popup still opens a lane.
- **Transient by nature:** nothing about it is written to the ledger; a relaunch
  does not restore it.

## Acceptance Criteria

- Against real WebKit with local test pages on two ports (opener and "provider"):
  - `window.open(url, 'auth', 'width=500,height=600')` shows a dialog, and the
    strip's lane count does not change;
  - the provider page's `window.opener.postMessage(...)` reaches the opener;
  - the provider's `window.close()` closes the dialog and focus is back on the
    opener pane;
  - five `window.open` calls in a row leave exactly one dialog and zero new lanes;
  - a bare scripted `window.open(url)` follows `PopupPolicy` (dialog); a clicked
    `target=_blank` link still opens a lane.
- The opener lane being off-screen, docked, or under the gallery does not change
  where the dialog appears.
- `PopupHandoff`'s lane staging is removed or repurposed — no path that turns a
  popup into a lane remains, and no dead claim code.
- Render sheet of the dialog's bar (https lock + host, and an `http://` warning) in
  light and dark, looked at.
- README: the web-pane section's popup paragraph rewritten.
- LinkedIn → "Sign in with Google" cannot be driven with the owner's account from
  a test; say so, and document the local reproduction instead.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` —
  `createWebViewWith`, `openPopup`, `revealLane`, `webViewDidClose`.
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPopup.swift` — `PopupIntent`,
  `PopupPolicy` (keep), `PopupHandoff` (lane staging to retire), `LinkClick`.
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebContextMenu.swift` — refers to
  `PopupHandoff`.
- `swift/MaxPane/Sources/MaxPaneKit/Views/Popup.swift`, `ConfirmPopup.swift` — the
  dialog frame; `Views/WebChromeBar.swift`, `Web/BrowserAddress.swift` — security
  glyph and host display to reuse.
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneAsks.swift`, `Web/WebAsk*.swift`,
  `Web/WebDownloads.swift`, `Passwords/PasswordFill.swift` — asks, downloads and
  fill routed to the popup's web view.
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` — where a
  pane's controller claims a staged popup today.

## Constraints

- Never build the popup from a fresh configuration: that severs `window.opener`
  and is the bug round 2 already fixed once.
- `WebPaneAsks.swift` currently holds **another session's uncommitted edit** (the
  app-link policy). Do not overwrite, stage or revert it; if this task must change
  that file, commit only your own hunks and leave theirs in the working tree.
- Nothing may appear or disappear abruptly (`Motion`, Reduce Motion honoured).
- Square corners; colours from `Theme` only (a later task moves the accent to greens).
