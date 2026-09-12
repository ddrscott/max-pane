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
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

CONFIG="${1:-release}"
RUN="${2:-}"
APP="build/MaxPane.app"

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

# laned-core is linked statically, so nothing to copy — but the dylib would land
# in Frameworks/ with an @rpath fixup if that ever changes.

echo "==> maxpane-open (the BROWSER shim)"
cargo build --release -p maxpane-open
cp "target/release/maxpane-open" "$APP/Contents/Helpers/maxpane-open"
cp "target/release/maxpane" "$APP/Contents/Helpers/maxpane"

# Signing must come last. Adding a file to the bundle afterwards breaks the seal,
# and the only symptom is `codesign --verify` saying "a sealed resource is
# missing or invalid" — which nothing checks unless you ask it to. So we ask.
echo "==> signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/maxpane-open" >/dev/null
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/maxpane" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

echo "built $APP"
echo
echo "  CLI:      $PWD/$APP/Contents/Helpers/maxpane"
echo "  BROWSER:  $PWD/$APP/Contents/Helpers/maxpane-open  (set automatically in panes it starts)"

if [ "$RUN" = "run" ]; then
  open "$APP"
fi
