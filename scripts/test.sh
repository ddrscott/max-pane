#!/usr/bin/env bash
# Run everything: laned-core's Rust tests and the Swift app's.
#
#   ./scripts/test.sh            the edit-loop run: fast, and everything that
#                                protects correctness still runs
#   ./scripts/test.sh --skip X   the same run, with `swift test`'s own --skip
#                                (or any other swift test flag) passed through;
#                                this is the one sanctioned way to leave a
#                                real-WebKit suite out
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
#
# Forced, not defaulted. This used to be `${MAXPANE_PROFILE:-tests}`, and a shell
# inside a live Max Pane pane inherits `MAXPANE_PROFILE=default` and the app's
# own `MAXPANE_SOCKET` from the pane that spawned it — so run from there, every
# real-WebKit suite saw the empty default salt, printed SKIPPED, and the run went
# green having proved less than it said. The four path overrides still beat the
# profile inside the app (see `Profile.swift`), so they go too: a test process
# must never be pointed at his ledger, config, socket or jars by accident.
export MAXPANE_PROFILE=tests
unset MAXPANE_SOCKET MAXPANE_LEDGER MAXPANE_CONFIG MAXPANE_DATA_SALT

TESTS_DIR=swift/MaxPane/Tests/MaxPaneKitTests
# The guard every real-WebKit suite carries prints this phrase when it trips.
WEBKIT_SKIP='SKIPPED .* in real WebKit'

swift_test() {
  (cd swift/MaxPane && swift test "$@" \
    -Xswiftc -F -Xswiftc "$CLT_FW" \
    -Xlinker -F -Xlinker "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_FW" \
    -Xlinker -rpath -Xlinker "$CLT_LIB")
}

# Say what the real-WebKit suites did, and refuse a green run that skipped one.
#
# swift-testing does not swallow a passing test's stdout, so the SKIPPED lines
# the guards print are in the log; but a line among thousands is a line nobody
# reads. Count them against the guards in the tree, name the suites that were
# opted out by `--skip` on this command line, and fail if any suite skipped for
# any other reason — after the export above the only way the guard can trip is
# the profile not reaching the test process, and that is a harness bug, not a
# result.
webkit_skip_report() {
  local log="$1"; shift
  local -a skips=() guarded=() opted=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip)  skips+=("${2:-}"); shift 2 ;;
      --skip=*) skips+=("${1#--skip=}"); shift ;;
      *)       shift ;;
    esac
  done
  local f name pat
  for f in $(grep -l 'in real WebKit:' "$TESTS_DIR"/*.swift | sort); do
    name="$(basename "$f" .swift)"
    guarded+=("$name")
    for pat in "${skips[@]+"${skips[@]}"}"; do
      if [[ "$name" =~ $pat ]]; then opted+=("$name"); break; fi
    done
  done
  # The guard prints once per test, so count distinct lines: each suite has its
  # own phrase, and the distinct lines are the suites.
  local tripped
  tripped="$( { grep "$WEBKIT_SKIP" "$log" || true; } | sort -u | grep -c . || true)"
  local ran=$(( ${#guarded[@]} - ${#opted[@]} - tripped ))

  echo
  echo "real-WebKit suites: ${#guarded[@]} in the tree, $ran ran, ${#opted[@]} opted out, $tripped skipped by the profile guard"
  if [ ${#opted[@]} -gt 0 ]; then
    echo "      opted out (--skip): ${opted[*]}"
  fi
  if [ "$tripped" -gt 0 ]; then
    grep "$WEBKIT_SKIP" "$log" | sort -u | sed 's/^/      /'
    echo
    echo "FAIL: $tripped real-WebKit suite(s) skipped without an explicit opt-out." >&2
    echo "      The profile guard tripped, so MAXPANE_PROFILE=tests did not reach the" >&2
    echo "      test process. The only sanctioned skip is: $0 --skip <Suite>" >&2
    return 1
  fi
}

default_run() {
  # The signing decision (scripts/entitlements.sh) has branches that codesign
  # cannot exercise without a profile from Apple; this runs every one of them
  # against decoded fixtures. Milliseconds, so it is in the edit-loop run.
  ./scripts/tests/entitlements.sh
  # The release contract: CHANGELOG.md's top released version is the plist's
  # (scripts/changelog-version.sh, which release.sh runs). Fixtures, then
  # the real files.
  ./scripts/tests/changelog-version.sh

  echo
  echo "==> laned-core"
  cargo test --workspace

  echo
  echo "==> MaxPane (profile: $MAXPANE_PROFILE)"
  local log
  log="$(mktemp -t maxpane-swift-test)"
  swift_test "$@" 2>&1 | tee "$log"
  webkit_skip_report "$log" "$@"
  rm -f "$log"

  # libtest swallows a passing test's stdout, so the SKIPPED lines the gated
  # Rust tests print are invisible here. Say it out loud instead: a suite that
  # does not announce what it left out is a suite you stop trusting.
  echo
  echo "note: skipped the cost tests (rust_side_snapshot_cost, cost_of_a_keystroke,"
  echo "      cost_of_importing_a_real_profile)"
  echo "      and the render sheets. $0 all runs them."
}

bench_run() {
  echo
  echo "==> cost tests (release)"
  # Release, because a debug timing number measures the debug build and nothing
  # a user will ever run. --nocapture so the measurements are actually printed;
  # they are the point, the assertion is only a floor under them.
  #
  # `cost_of_importing_a_real_profile` is here but will print SKIPPED unless
  # MAXPANE_IMPORT_SOURCE names a browser history file: it is the one measurement
  # that has no synthetic stand-in, because it reads a real person's browsing off
  # a real disk. Listed anyway so `bench` says out loud that it exists.
  MAXPANE_BENCH=1 cargo test --release --workspace -- --nocapture \
    rust_side_snapshot_cost cost_of_a_keystroke cost_of_importing_a_real_profile
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
  ""|-*)   default_run "$@" ;;
  bench)   bench_run ;;
  shots)   shots_run "${2:-}" ;;
  all)     default_run; bench_run; shots_run "${2:-${TMPDIR:-/tmp}/maxpane-shots}" ;;
  *)       echo "usage: $0 [--skip SUITE ... | bench | shots DIR | all]" >&2; exit 2 ;;
esac
