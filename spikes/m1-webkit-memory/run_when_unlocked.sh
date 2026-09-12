#!/usr/bin/env bash
# The visibility-dependent halves of M1 (rAF suspension, first-frame latency,
# idle CPU of a genuinely visible pane) are only valid when the display is awake
# AND the screen is UNLOCKED -- otherwise macOS marks every window occluded and
# WebKit suspends rendering app-wide, which makes the "parented and visible"
# control indistinguishable from the unparented subject.
#
# The app itself blocks on that condition via --require-unlocked; this just
# wraps it with a long wait and the usual fixture-server bring-up.
#   ./run_when_unlocked.sh [mode] [max-wait-seconds]
set -uo pipefail
cd "$(dirname "$0")"
exec ./run.sh "${1:-fixtures}" --require-unlocked --wait-unlock-secs "${2:-3600}"
