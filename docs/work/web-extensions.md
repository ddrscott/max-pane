# WebExtension support (spike first)

## Problem
No `WKWebExtension` anywhere. macOS 15.4 added a public WebExtension API to
WebKit (`WKWebExtension`, `WKWebExtensionController`, `WKWebExtensionContext`).
The two extensions most people cannot leave a browser without are a password
manager and a blocker; both are covered by in-app features (Passwords, and the
blocking task). What is left is the long tail: Vimium-style keyboard nav,
Refined GitHub, Dark Reader, Grammarly.

## Acceptance Criteria
This is a spike, not a feature. Deliver `docs/spikes/NN-webextensions.md`:
- Deployment target is macOS 14 (`Package.swift`). Measure what raising it to
  15.4 costs (the DMG/cask promise "macOS 14 or newer") and whether the API can
  be weak-linked behind `#available`.
- Load one real unpacked extension (Dark Reader or Refined GitHub, both MIT)
  into a throwaway instance (`MAXPANE_LEDGER` / `MAXPANE_DATA_SALT` overrides)
  and record: does its content script run on a pane, does its popup UI have
  anywhere to appear in a 656 pt lane, what permissions prompts WebKit raises,
  memory per extension per pane (ADR-0003: one WebContent process per pane).
- Recommend go / no-go with the reasons, and if go, the shape: an
  `extensions/` directory under the profile, a settings section listing them,
  and where a browser-action button lives in the address bar.

## Relevant Files
- `swift/MaxPane/Package.swift`, `scripts/make-dmg.sh` (the OS floor promise)
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift`
- `docs/spikes/` for the format

## Constraints
- Do not raise the deployment target in this task; measure only.
- No installer that fetches from the Chrome Web Store; WebKit loads unpacked
  or Safari-packaged extensions only.
