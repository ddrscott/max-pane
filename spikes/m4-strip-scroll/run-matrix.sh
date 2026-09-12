#!/bin/bash
# Run the full M4 matrix: 3 variants x 2 screens.
# usage: ./run-matrix.sh [outdir]
set -uo pipefail
cd "$(dirname "$0")"
OUT=${1:-results}
mkdir -p "$OUT"
APP="$PWD/StripBench.app"

run() { # variant screen tag extra...
  local v=$1 sc=$2 tag=$3; shift 3
  local f="$PWD/$OUT/$tag.json"
  rm -f "$f" "$f.log"
  echo "--- $tag ---"
  open -n "$APP" --args --variant "$v" --screen "$sc" --lanes 150 --out "$f" "$@"
  for _ in $(seq 1 300); do [ -s "$f" ] && break; sleep 1; done
  pkill -f "StripBench.app/Contents/MacOS/StripBench" >/dev/null 2>&1
  sleep 1
  [ -s "$f" ] && echo "  ok" || echo "  FAILED"
}

# Headline: main (60 Hz) panel, full 60 s idle sample, realistic 6000 pt/s sweep.
for v in naive recycled collection; do
  run "$v" 0 "s0-$v" --velocity 6000 --idle-seconds 60 --settle 2
done

# Secondary: built-in ProMotion panel if present, short idle.
for v in naive recycled collection; do
  run "$v" 1 "s1-$v" --velocity 6000 --idle-seconds 10 --settle 2
done
echo "matrix done -> $OUT"
