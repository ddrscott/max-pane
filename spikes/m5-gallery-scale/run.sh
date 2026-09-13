#!/bin/bash
# Run the spike without disturbing anyone at the keyboard.
#
#   ./run.sh out            every phase, results in out/results.json + PNGs
#   ./run.sh out grid web   just those phases
#
# `open -g` launches it in the background and the app never activates: it is an
# LSUIElement agent whose one window sits below the desktop. Nothing it does can
# take focus or a keystroke from the frontmost app.
set -uo pipefail
cd "$(dirname "$0")"
OUT=${1:?out dir}; shift
PHASES=${*:-all}
APP="$PWD/GalleryScale.app"
mkdir -p "$OUT"
rm -f "$OUT/results.json"

# BACKING=2 renders as a 2× display would, whatever panel is connected.
EXTRA=()
[ -n "${BACKING:-}" ] && EXTRA+=(--backing "$BACKING")
open -g -n "$APP" --args --out "$PWD/$OUT" --phases "${PHASES// /,}" ${EXTRA[@]+"${EXTRA[@]}"}

for _ in $(seq 1 300); do
  [ -s "$OUT/results.json" ] && break
  sleep 1
done
sleep 1
pkill -f "GalleryScale.app/Contents/MacOS/GalleryScale" >/dev/null 2>&1
[ -s "$OUT/results.json" ] && echo "OK -> $OUT/results.json" || { echo "FAILED: no results in $OUT"; exit 1; }
