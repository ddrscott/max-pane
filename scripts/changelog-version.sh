#!/usr/bin/env bash
# The top released version in a Keep a Changelog file: the first `## [x.y.z]`
# heading that is not `## [Unreleased]`.
#
#   ./scripts/changelog-version.sh CHANGELOG.md                  prints 0.6.1
#   ./scripts/changelog-version.sh CHANGELOG.md --expect 0.6.1   prints it, or
#                                                                 refuses (exit 1)
#
# The contract this enforces, for release.sh: the changelog's top released
# version must equal the plist's CFBundleShortVersionString. The version in
# the sidebar's corner is the plist's, and the `+N` after it is the count of
# entries under Unreleased in the bundled changelog — so at release time the
# two have to be in step, or the corner and the release notes disagree about
# what shipped. The check is here rather than inline so scripts/tests/ can
# run it against fixtures.
set -euo pipefail

FILE="${1:-}"
EXPECT=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --expect) EXPECT="${2:-}"; shift 2 ;;
    *) echo "usage: $0 CHANGELOG.md [--expect VERSION]" >&2; exit 2 ;;
  esac
done
[ -n "$FILE" ] && [ -r "$FILE" ] || { echo "usage: $0 CHANGELOG.md [--expect VERSION]" >&2; exit 2; }

# `## [0.6.1] - 2026-09-16` → 0.6.1. Brackets optional; Unreleased skipped,
# whatever its case.
TOP="$(awk '
  /^## / {
    v = $2
    sub(/^\[/, "", v); sub(/\]$/, "", v)
    if (tolower(v) == "unreleased") next
    print v; exit
  }
' "$FILE")"
if [ -z "$TOP" ]; then
  echo "$FILE has no released '## [x.y.z]' section." >&2
  exit 1
fi
if [ -n "$EXPECT" ] && [ "$TOP" != "$EXPECT" ]; then
  echo "$FILE's top released version is $TOP, but the plist says $EXPECT." >&2
  echo "Move the Unreleased entries under '## [$EXPECT] - $(date -u +%Y-%m-%d)' (or fix the plist) before releasing." >&2
  exit 1
fi
echo "$TOP"
