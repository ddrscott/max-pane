# Passkeys: request the web-browser public-key-credential capability and carry its profile

## Problem
Verified 2026-09-16 (`docs/acceptance.md`, "Passkeys and picture-in-picture"):
`isUserVerifyingPlatformAuthenticatorAvailable()` is `false` and every
`navigator.credentials.create()` / `get()` is refused with `NotAllowedError`,
on `localhost` and on `webauthn.io`, with no sheet and no QR code. Adding
`com.apple.developer.web-browser.public-key-credential` to the entitlements
file signs and verifies but the app is SIGKILLed at launch (exit 137), because
the key is a managed capability that has to arrive through a provisioning
profile Apple issues after approving the app as a web browser.

## Acceptance Criteria
- The Account Holder (Scott) files Apple's request form for the Web Browser
  Public Key Credential capability. Before filing, check the criteria Apple
  lists: HTTP/HTTPS in `CFBundleURLTypes`, a URL field on launch, direct
  navigation to the typed destination. Record the request date and outcome in
  `docs/decisions/` as an ADR, including "denied" if that is what comes back.
- Once granted: a Developer ID provisioning profile with the capability,
  embedded as `Contents/embedded.provisionprofile`, and the key in
  `MaxPane.entitlements`. `scripts/build-app.sh` and `scripts/make-dmg.sh` sign
  with it; an ad-hoc build must still launch without the profile (strip the key
  in that branch), because that is what a machine with no identity gets.
- Proof, in a throwaway instance and written into `docs/acceptance.md`:
  `isUserVerifyingPlatformAuthenticatorAvailable()` is `true`, and Register on
  `webauthn.io` shows the system passkey sheet. Never a real account.
- If Apple declines: the ADR says so, and the README's browser section says
  passkeys are not available in a pane and why.

## Relevant Files
- `swift/MaxPane/Resources/MaxPane.entitlements`
- `scripts/build-app.sh`, `scripts/make-dmg.sh`
- `swift/MaxPane/Resources/Info.plist` (or wherever `CFBundleURLTypes` lives)
- `docs/acceptance.md`, `docs/decisions/`

## Constraints
- Nothing here can be finished by code alone; the queue item is the plumbing
  and the proof, and it waits on Apple.
- Do not add the key to the shipped entitlements before the profile exists —
  the app will not launch.
