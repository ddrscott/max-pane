# Verify in the running app: passkeys / WebAuthn and picture-in-picture

## Problem
Two capabilities could not be confirmed from the code on 2026-09-16 and only a
real instance answers them:

1. **Passkeys and WebAuthn.** `WKWebView` on macOS 14 supports the platform
   authenticator, but only when the app is signed with the
   `com.apple.developer.web-browser.public-key-credential` entitlement (or the
   older associated-domains route). Without it, "Sign in with a passkey" on
   GitHub, Google and Apple ID either shows nothing or a QR code only.
2. **Picture-in-picture.** WebKit's native video controls offer PiP, but
   `PaneFullscreen` intercepts the fullscreen API and `isElementFullscreenEnabled`
   is on. PiP should be unaffected; check that the button appears on YouTube
   and Vimeo and that a PiP window survives the pane being evicted or the lane
   being closed without a crash.

## Acceptance Criteria
- Drive both in a throwaway instance (`MAXPANE_LEDGER`, `MAXPANE_DATA_SALT`;
  never the owner's running app), using `webauthn.io` for the first, not a
  real account.
- For each: a paragraph in `docs/acceptance.md` with the result, and either
  "works, nothing to do" or a new queue item with the fix scoped (for passkeys,
  that is likely the entitlement in the file `scripts/make-dmg.sh` signs with,
  and whether it needs a provisioning profile from Apple).

## Relevant Files
- `scripts/make-dmg.sh`, the entitlements file it references
- `swift/MaxPane/Sources/MaxPaneKit/Web/PaneFullscreen.swift`
- `docs/acceptance.md`

## Constraints
- Report what happened, not what should have. A partial answer is fine if it
  says which half is unanswered.
