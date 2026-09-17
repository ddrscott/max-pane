#!/usr/bin/env bash
# Build MaxPane.app.
#
# There is no Xcode on this machine, so the bundle is assembled by hand around a
# SwiftPM executable and ad-hoc signed. The signing is not optional: WKWebView
# will not spawn its XPC content processes for an unsigned, unbundled binary, so
# a bare `swift run` gives you an app with no web panes and no useful error.
#
#   ./scripts/build-app.sh            release (default)
#   ./scripts/build-app.sh debug
#   ./scripts/build-app.sh release run
#
# MAXPANE_APP builds to a different bundle. Use it whenever an instance you did
# not start is running: this script `rm -rf`s the bundle before reassembling it,
# and pulling a bundle out from under a live process kills it — WKWebView stops
# being able to spawn its XPC processes and the app goes down with no message.
# That has already cost someone a half-finished sign-in.
#
#   MAXPANE_APP=build/gauntlet-p1.app ./scripts/build-app.sh
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

CONFIG="${1:-release}"
RUN="${2:-}"
APP="${MAXPANE_APP:-build/MaxPane.app}"

# Refuse to demolish a bundle someone is running.
if pgrep -f "$APP/Contents/MacOS/MaxPane" >/dev/null 2>&1; then
  echo "refusing to rebuild $APP: an instance of it is running (pid $(pgrep -f "$APP/Contents/MacOS/MaxPane" | tr '\n' ' '))." >&2
  echo "quit it, or build elsewhere: MAXPANE_APP=build/mine.app $0 $*" >&2
  exit 1
fi

./scripts/gen-bindings.sh "$CONFIG"

echo "==> swift build ($CONFIG)"
(cd swift/MaxPane && swift build -c "$CONFIG")
BIN="swift/MaxPane/.build/$CONFIG/MaxPane"
[ -x "$BIN" ] || { echo "no executable at $BIN" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
# Helpers, not MacOS: macOS filesystems are case-insensitive by default, so a
# CLI called `maxpane` next to an app called `MaxPane` silently overwrites it.
# That failure looks like the app launching and printing CLI usage.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/MaxPane"
cp swift/MaxPane/Resources/Info.plist "$APP/Contents/Info.plist"
# CFBundleIconFile names this without the extension. Dock and Finder read it
# from the bundle, not from the plist, so a missing file here is a generic
# icon and no error anywhere. The .icns is generated from AppIcon-source.png
# by scripts/gen-app-icon.py; edit the PNG, re-run that, commit both.
cp swift/MaxPane/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The Ghostty resource bundle: terminfo and shell integration, read by
# libghostty before its runtime starts. SwiftPM's Bundle.module looks for it at
# the app root, which codesign rejects as unsealed contents, or at this
# machine's absolute build path, which no other machine has. The fork of
# libghostty-spm in Package.swift asks Contents/Resources first, so it goes
# there. Without it, the first terminal pane traps in Bundle.module — which is
# how 0.6.0 shipped, and why this refuses rather than warns.
GHOSTTY_BUNDLE="swift/MaxPane/.build/$CONFIG/GhosttyKit_GhosttyTerminal.bundle"
[ -d "$GHOSTTY_BUNDLE" ] || { echo "no Ghostty resource bundle at $GHOSTTY_BUNDLE" >&2; exit 1; }
cp -R "$GHOSTTY_BUNDLE" "$APP/Contents/Resources/GhosttyKit_GhosttyTerminal.bundle"

# A throwaway bundle gets a throwaway bundle id.
#
# `UserDefaults` is keyed by bundle identifier, not by profile, so a test
# instance built to a different path still shares the real app's domain — and
# the split view's `autosaveName` lives there. A worker that so much as launched
# could move the divider in the strip someone is working in. --profile isolates
# the ledger, the sockets and the cookie jars; it does not and cannot isolate
# this.
if [ "$APP" != "build/MaxPane.app" ]; then
  SUFFIX="$(basename "$APP" .app | tr -c 'a-zA-Z0-9' '-' | sed 's/-*$//')"
  /usr/bin/plutil -replace CFBundleIdentifier -string "app.ljs.maxpane.$SUFFIX" \
    "$APP/Contents/Info.plist"
  echo "==> bundle id app.ljs.maxpane.$SUFFIX (throwaway; keeps UserDefaults separate)"
fi

# laned-core must be linked statically. If ld ever finds the .dylib instead, the
# app loads target/release/deps/liblaned_core.dylib from this checkout at
# runtime, and the next `cargo build` that touches the FFI kills every launch
# with a uniffi checksum trap in Core.open. Refuse to ship that.
if otool -L "$APP/Contents/MacOS/MaxPane" | grep -q laned_core; then
  echo "MaxPane links liblaned_core dynamically; see swift/MaxPaneCore/Package.swift" >&2
  otool -L "$APP/Contents/MacOS/MaxPane" | grep laned_core >&2
  exit 1
fi

echo "==> maxpane-open (the BROWSER shim)"
cargo build --release -p maxpane-open
cp "target/release/maxpane-open" "$APP/Contents/Helpers/maxpane-open"
cp "target/release/maxpane" "$APP/Contents/Helpers/maxpane"

# Sign with the Developer ID when this machine has one, ad-hoc otherwise. The
# difference matters the moment the bundle leaves the folder it was built in:
# an ad-hoc signature is valid only on the machine that made it, so a copy in
# /Applications keeps working while `spctl` refuses to vouch for it.
#
# MAXPANE_SIGN_IDENTITY overrides; MAXPANE_SIGN_IDENTITY=- forces ad-hoc.
IDENTITY="${MAXPANE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "==> signing (ad-hoc — no Developer ID on this machine)"
else
  echo "==> signing as $IDENTITY"
fi

# Signing must come last. Adding a file to the bundle afterwards breaks the seal,
# and the only symptom is `codesign --verify` saying "a sealed resource is
# missing or invalid" — which nothing checks unless you ask it to. So we ask.
#
# Hardened runtime is on (`--options runtime`), because Apple's notary service
# rejects a bundle without it, and a stranger's Mac warns on an un-notarised
# download. It used to be off for fear that WebKit would lose its content
# processes and libghostty its renderer; neither needs an exception. WebKit's
# helpers are Apple's own XPC services with their own entitlements, and
# libghostty is linked statically with no JIT. The only entitlements the app
# carries are the camera, microphone and location ones in MaxPane.entitlements,
# so a web page can be granted what it asked for (see the comment there) — plus
# the passkeys capability when, and only when, a provisioning profile grants it
# (below).
# The helper CLIs get the runtime with no entitlements: they open sockets and
# talk to the app, nothing more.
#
# `--timestamp` asks Apple's timestamp server to countersign, which the notary
# service also requires. It needs the network; offline, sign without it and say
# so, because a build that dies for want of a timestamp is worse than a build
# that cannot be notarised yet. Ad-hoc signatures take the runtime flag too, so
# a local build exercises the same runtime a shipped one does.
# Passkeys. WebAuthn in a WKWebView needs
# `com.apple.developer.web-browser.public-key-credential`, a managed capability
# Apple grants per team through a provisioning profile; signed with the key and
# no profile, the app is SIGKILLed at launch. scripts/entitlements.sh decides:
# the shipped MaxPane.entitlements as is (`off`) unless a profile that covers
# this bundle id and this team is at MAXPANE_PROVISIONING_PROFILE (default
# packaging/MaxPane.provisionprofile; set it empty to ignore a profile that is
# there), in which case the key and the profile's identifiers go in (`on`) and
# the profile is embedded where the kernel looks for it. An ad-hoc build is
# always `off`. A profile that is present but wrong stops the build. The README
# ("Passkeys and the provisioning profile") says how to get one.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
PROFILE="${MAXPANE_PROVISIONING_PROFILE-packaging/MaxPane.provisionprofile}"
ENTITLEMENTS="$(mktemp -t maxpane-entitlements)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
PASSKEYS="$(./scripts/entitlements.sh swift/MaxPane/Resources/MaxPane.entitlements "$ENTITLEMENTS" \
  --bundle-id "$BUNDLE_ID" --identity "$IDENTITY" ${PROFILE:+--profile "$PROFILE"})"
if [ "$PASSKEYS" = "on" ]; then
  echo "==> passkeys on: embedding $PROFILE"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
fi
TIMESTAMP="--timestamp"
if [ "$IDENTITY" = "-" ]; then
  # Timestamps are meaningless on an ad-hoc signature; codesign ignores the
  # request, but asking for one still costs a round-trip to Apple.
  TIMESTAMP="--timestamp=none"
elif ! PROBE_ERR="$(codesign --force --sign "$IDENTITY" --options runtime --timestamp \
       "$APP/Contents/Helpers/maxpane-open" 2>&1 >/dev/null)"; then
  # The probe fails for more reasons than a missing network: a locked keychain,
  # an expired certificate, a revoked identity. codesign names which on stderr,
  # so it is shown rather than guessed at as "unreachable".
  echo "WARNING: the timestamped signing probe failed; signing without a secure timestamp." >&2
  echo "         codesign said:" >&2
  sed 's/^/           /' <<<"${PROBE_ERR:-(no output)}" >&2
  echo "         This build cannot be notarised. Fix the cause above (offline? rebuild online;" >&2
  echo "         keychain or certificate? see the message) before make-dmg.sh." >&2
  TIMESTAMP="--timestamp=none"
fi
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/maxpane-open" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$APP/Contents/Helpers/maxpane" >/dev/null
codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP --entitlements "$ENTITLEMENTS" "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "built $APP"
echo
echo "  CLI:      $PWD/$APP/Contents/Helpers/maxpane"
echo "  BROWSER:  $PWD/$APP/Contents/Helpers/maxpane-open  (set automatically in panes it starts)"

if [ "$RUN" = "run" ]; then
  # `open` hands our environment to the app, and the app hands it to every
  # pane. Run from a Claude session, that carries CLAUDE_CODE_CHILD_SESSION into
  # each pane and every `claude` started there stops saving its transcript.
  # The spawner scrubs these too; this keeps the app process itself clean.
  env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_EFFORT \
    $(env | sed -n 's/^\(CLAUDE_CODE_[A-Z_]*\)=.*/-u \1/p') \
    open "$APP"
fi
