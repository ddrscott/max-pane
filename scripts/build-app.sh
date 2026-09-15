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

# laned-core is linked statically, so nothing to copy — but the dylib would land
# in Frameworks/ with an @rpath fixup if that ever changes.

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
# No hardened runtime: it is only required for notarisation, and turning it on
# without the matching entitlements is how WebKit loses its content processes
# and Ghostty loses its renderer — both of which fail at runtime, not here.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Helpers/maxpane-open" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/Helpers/maxpane" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "built $APP"
echo
echo "  CLI:      $PWD/$APP/Contents/Helpers/maxpane"
echo "  BROWSER:  $PWD/$APP/Contents/Helpers/maxpane-open  (set automatically in panes it starts)"

if [ "$RUN" = "run" ]; then
  open "$APP"
fi
