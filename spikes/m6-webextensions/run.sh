#!/bin/bash
# Runs every phase and leaves the numbers in out/<stamp>/.
#   EXT_DIR=/path/to/unpacked/darkreader RG_DIR=/path/to/unpacked/refined-github ./run.sh
# Dark Reader: https://github.com/darkreader/darkreader/releases (darkreader-chrome-mv3.zip)
# Refined GitHub: https://github.com/refined-github/refined-github/releases (the *-for-local-testing-only.zip)
set -euo pipefail
cd "$(dirname "$0")"
: "${EXT_DIR:?unpacked Dark Reader directory}"
: "${RG_DIR:=}"
PORT=${PORT:-18960}
OUT=${1:-out/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
./build.sh | tee "$OUT/build.txt"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory fixtures >"$OUT/http.log" 2>&1 &
HTTP=$!
trap 'kill $HTTP 2>/dev/null || true' EXIT
sleep 0.5
BIN=out/M6Spike.app/Contents/MacOS/M6Spike
export FIXTURE="http://127.0.0.1:$PORT/page.html"
{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string; swiftc --version | head -1; } >"$OUT/environment.txt" 2>&1
run() { echo "=== $* ==="; env -u CLAUDE_CODE_CHILD_SESSION "$@" 2>&1 | tee -a "$OUT/console.txt"; }
# Panes get a persistent identifier store, as the app's do (ADR-0003).
run "$BIN" "$OUT" baseline
run "$BIN" "$OUT" ext
GRANT=0 run "$BIN" "$OUT/ungranted" probe
GRANT=1 run "$BIN" "$OUT" probe
if [ -n "$RG_DIR" ]; then run "$BIN" "$OUT" rg; fi
# The minimal extension in fixtures/mini-ext stamps the DOM from its content
# script, which separates "WebKit injected" from "the extension did something".
# Three store/private combinations, because the first run of this spike lost an
# hour to `.nonPersistent()` counting as private browsing.
MINI="$PWD/fixtures/mini-ext"
EXT_DIR="$MINI" STORE=persistent    PRIVATE_DATA=0 run "$BIN" "$OUT/mini-persistent" probe
EXT_DIR="$MINI" STORE=nonPersistent PRIVATE_DATA=0 run "$BIN" "$OUT/mini-nonpersistent" probe
EXT_DIR="$MINI" STORE=nonPersistent PRIVATE_DATA=1 run "$BIN" "$OUT/mini-nonpersistent-private" probe
echo "results in $OUT"
