#!/usr/bin/env bash
# Prove a built bundle starts on a Mac that is not this one.
#
# 0.6.0 shipped a DMG that trapped at the first terminal pane: the Ghostty
# resource bundle was found only through SwiftPM's absolute build path, which
# every machine but the build machine lacks. Every manual install here had
# quietly leaned on this checkout. This hides that fallback, launches a
# throwaway copy of the bundle on a throwaway profile, opens a terminal pane
# — the line that trapped — and asks whether the process is still there.
#
#   ./scripts/smoke-app.sh            build/MaxPane.app
#   ./scripts/smoke-app.sh path.app
#
# A window appears for a few seconds. MAXPANE_SMOKE=0 skips it in release.sh.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

APP="${1:-build/MaxPane.app}"
[ -d "$APP" ] || { echo "no bundle at $APP" >&2; exit 1; }
PROFILE="smoke-$$"
SCRATCH="$(mktemp -d -t maxpane-smoke)"
COPY="$SCRATCH/MaxPane.app"
HIDDEN=()

cleanup() {
  [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true
  for b in "${HIDDEN[@]:-}"; do [ -n "$b" ] && [ -d "$b.hidden" ] && mv "$b.hidden" "$b"; done
  rm -rf "$SCRATCH" \
    "$HOME/Library/Application Support/MaxPane/profiles/$PROFILE" \
    "$HOME/.config/maxpane/profiles/$PROFILE"
  defaults delete "app.ljs.maxpane.$PROFILE" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/app.ljs.maxpane.$PROFILE.plist"
}
trap cleanup EXIT

# Hide the build-path fallback so only what is inside the bundle can answer.
for b in swift/MaxPane/.build/*/{release,debug}/GhosttyKit_GhosttyTerminal.bundle; do
  [ -d "$b" ] || continue
  mv "$b" "$b.hidden"; HIDDEN+=("$b")
done

cp -R "$APP" "$COPY"
/usr/bin/plutil -replace CFBundleIdentifier -string "app.ljs.maxpane.$PROFILE" "$COPY/Contents/Info.plist"
codesign --force --deep --sign - "$COPY" >/dev/null 2>&1

echo "==> smoke: launching a throwaway copy on profile $PROFILE"
# The same scrub build-app.sh's `run` does; see there for why.
env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_EFFORT \
  $(env | sed -n 's/^\(CLAUDE_CODE_[A-Z_]*\)=.*/-u \1/p') \
  MAXPANE_WINDOWED=1 "$COPY/Contents/MacOS/MaxPane" --profile "$PROFILE" >"$SCRATCH/smoke.log" 2>&1 &
PID=$!
sleep 5
kill -0 "$PID" 2>/dev/null || { echo "smoke: the app died before its window (log follows)" >&2; cat "$SCRATCH/smoke.log" >&2; exit 1; }

# A terminal pane is where 0.6.0 trapped: libghostty reads its resources here.
"$COPY/Contents/Helpers/maxpane" --profile "$PROFILE" run sleep 30 >/dev/null
sleep 4
kill -0 "$PID" 2>/dev/null || { echo "smoke: the app died opening a terminal pane (log follows)" >&2; cat "$SCRATCH/smoke.log" >&2; exit 1; }
"$COPY/Contents/Helpers/maxpane" --profile "$PROFILE" ls | grep -q "pty:" \
  || { echo "smoke: no terminal pane on the strip" >&2; exit 1; }
echo "==> smoke: alive with a terminal pane, without the build directory"
