#!/bin/bash
# Run one StripBench variant with the display awake and the app properly activated.
# usage: ./run.sh <variant> <screen> <outfile> [extra args...]
set -uo pipefail
cd "$(dirname "$0")"
VARIANT=${1:?variant}; SCREEN=${2:?screen}; OUT=${3:?out}; shift 3
APP="$PWD/StripBench.app"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

# Wake the panels, then hold them awake for the duration of the run.
caffeinate -u -t 4 >/dev/null 2>&1 &
sleep 5
caffeinate -dis -t 400 >/dev/null 2>&1 &
CAFF=$!

open -n "$APP" --args --variant "$VARIANT" --screen "$SCREEN" --out "$PWD/$OUT" "$@"

# Wait for the run to produce its JSON (bench terminates itself).
for _ in $(seq 1 400); do
  [ -s "$OUT" ] && break
  sleep 1
done
sleep 1
pkill -f "StripBench.app/Contents/MacOS/StripBench" >/dev/null 2>&1
kill $CAFF >/dev/null 2>&1
[ -s "$OUT" ] && echo "OK -> $OUT" || { echo "FAILED: no output at $OUT"; exit 1; }
