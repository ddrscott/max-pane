#!/usr/bin/env bash
# Full M1 spike run: fixture server + app + external ps cross-check.
#   ./run.sh fixtures            # deterministic local fixtures
#   ./run.sh real                # 100 real URLs over the network
#   ./run.sh fixtures --require-unlocked --wait-unlock-secs 1800
set -euo pipefail
cd "$(dirname "$0")"
MODE="${1:-fixtures}"; shift || true
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN="out/${MODE}-${STAMP}"
mkdir -p "$RUN"

# fixture server (always needed: the animated instrument pages are local)
if ! curl -fsS --max-time 3 http://127.0.0.1:8801/health >/dev/null 2>&1; then
  echo "==> starting fixture server"
  (cd fixtures && nohup uv run --no-project serve.py --base-port 8801 --ports 20 > "../$RUN/fixtures.log" 2>&1 &)
  sleep 4
fi
curl -fsS --max-time 3 http://127.0.0.1:8801/health >/dev/null || { echo "fixture server not healthy"; exit 1; }

./build.sh > "$RUN/build.log" 2>&1

{ echo "=== machine ==="; sysctl hw.memsize machdep.cpu.brand_string hw.ncpu hw.perflevel0.logicalcpu hw.perflevel1.logicalcpu
  echo "=== os ==="; sw_vers; uname -a
  echo "=== toolchain ==="; swift --version; xcode-select -p; clang --version | head -1
  echo "=== load ==="; sysctl vm.loadavg; } > "$RUN/environment.txt" 2>&1

echo "==> running spike (mode=$MODE) -> $RUN"
./build/M1Spike.app/Contents/MacOS/M1Spike --mode "$MODE" --log "$RUN/run.log" --out "$RUN" "$@" &
APP_PID=$!
sleep 3
./sample_external.sh "$APP_PID" "" "$RUN/ps-samples.csv" 10 1200 &
SAMPLER=$!
wait "$APP_PID"; RC=$?
kill "$SAMPLER" 2>/dev/null || true
echo "==> exit $RC; artifacts in $RUN"
exit $RC
