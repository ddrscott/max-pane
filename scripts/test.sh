#!/usr/bin/env bash
# Run everything: laned-core's Rust tests and the Swift app's.
#
#   ./scripts/test.sh            the edit-loop run: fast, and everything that
#                                protects correctness still runs
#   ./scripts/test.sh bench      the cost tests, in release, where their numbers
#                                are worth reading
#   ./scripts/test.sh shots DIR  render the header and picker sheets as PNGs
#   ./scripts/test.sh all        the default run, then bench, then shots
#
# What "fast" leaves out is two tests, not two hundred: `rust_side_snapshot_cost`
# and `cost_of_a_keystroke` are ~1.28 s of the suite's 2.7 s between them, and
# both are timing measurements whose numbers only mean something in release.
# Everything else costs single-digit milliseconds and stays in. Each gated test
# prints a SKIPPED line naming the switch, so the default run never quietly
# claims to have done more than it did.
#
# The Swift half needs the framework dance below because there is no Xcode here.
# swift-testing ships inside Command Line Tools, but SwiftPM does not look for it
# there — it needs the framework search path at compile time and two rpaths at
# run time (Testing.framework, and lib_TestingInterop.dylib which lives
# somewhere else entirely). Without them `swift test` fails at dlopen with a
# message that names neither.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

CLT_FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

# The suite runs as its own profile, which is the whole of isolating it: ledger,
# config, socket and cookie jars all follow the name.
#
# The cookie jars are why it is not optional. `DataStorePool` derives a
# WKWebsiteDataStore UUID from the profile's salt, and the *default* profile's
# salt is empty — so a test process with no profile derives exactly the UUIDs the
# real app uses. The store tests only ask for identity, so nothing is written
# today, but a test process that can name the owner's live cookie jar is one
# WebKit release away from touching it.
export MAXPANE_PROFILE="${MAXPANE_PROFILE:-tests}"

swift_test() {
  (cd swift/MaxPane && swift test "$@" \
    -Xswiftc -F -Xswiftc "$CLT_FW" \
    -Xlinker -F -Xlinker "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_LIB")
}

default_run() {
  echo "==> laned-core"
  cargo test --workspace

  echo
  echo "==> MaxPane"
  swift_test

  # libtest swallows a passing test's stdout, so the SKIPPED lines the gated
  # tests print are invisible here. Say it out loud instead: a suite that does
  # not announce what it left out is a suite you stop trusting.
  echo
  echo "note: skipped the cost tests (rust_side_snapshot_cost, cost_of_a_keystroke)"
  echo "      and the render sheets. $0 all runs them."
}

bench_run() {
  echo
  echo "==> cost tests (release)"
  # Release, because a debug timing number measures the debug build and nothing
  # a user will ever run. --nocapture so the measurements are actually printed;
  # they are the point, the assertion is only a floor under them.
  MAXPANE_BENCH=1 cargo test --release --workspace -- --nocapture \
    rust_side_snapshot_cost cost_of_a_keystroke
}

shots_run() {
  local dir="${1:-}"
  [ -n "$dir" ] || { echo "usage: $0 shots DIR" >&2; exit 2; }
  mkdir -p "$dir"
  echo
  echo "==> render sheets -> $dir"
  MAXPANE_SHOTS="$(cd "$dir" && pwd)" swift_test
  ls -1 "$dir"
}

case "${1:-}" in
  "")      default_run ;;
  bench)   bench_run ;;
  shots)   shots_run "${2:-}" ;;
  all)     default_run; bench_run; shots_run "${2:-${TMPDIR:-/tmp}/maxpane-shots}" ;;
  *)       echo "usage: $0 [bench | shots DIR | all]" >&2; exit 2 ;;
esac
