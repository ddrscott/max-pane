#!/usr/bin/env bash
# The release contract in scripts/changelog-version.sh: the changelog's top
# released version is what release.sh compares the plist to, and a mismatch
# refuses the release.
#
# Run by scripts/test.sh's default run; also on its own. Fixtures here, and
# the real CHANGELOG.md against the real Info.plist last — the one that would
# actually stop a release.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/changelog-version.sh"
PB=/usr/libexec/PlistBuddy

T="$(mktemp -d -t maxpane-changelog-test)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; fails=$((fails + 1)); }

# run NAME EXPECTED-STDOUT EXPECTED-EXIT args...
run() {
  local name="$1" want_out="$2" want_rc="$3"; shift 3
  local out rc
  out="$("$SCRIPT" "$@" 2>"$T/err")" && rc=0 || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail "$name: exit $rc, wanted $want_rc: $(cat "$T/err")"; return 0
  fi
  if [ "$want_rc" = 0 ] && [ "$out" != "$want_out" ]; then
    fail "$name: printed '$out', wanted '$want_out'"; return 0
  fi
  pass "$name"
}

echo "==> scripts/changelog-version.sh"

cat >"$T/typical.md" <<'EOF'
# Changelog

## [Unreleased]

### Added
- Something new

## [0.6.1] - 2026-09-16

### Fixed
- A thing

## [0.6.0] - 2026-09-16

[Unreleased]: https://example.com/compare/v0.6.1...HEAD
[0.6.1]: https://example.com/compare/v0.6.0...v0.6.1
EOF
run "top released version, skipping Unreleased" "0.6.1" 0 "$T/typical.md"
run "--expect that matches passes" "0.6.1" 0 "$T/typical.md" --expect 0.6.1
run "--expect that does not match refuses" "" 1 "$T/typical.md" --expect 0.7.0
grep -q "top released version is 0.6.1, but the plist says 0.7.0" "$T/err" \
  && pass "the refusal names both versions" || fail "the refusal did not name both versions: $(cat "$T/err")"

cat >"$T/no-unreleased.md" <<'EOF'
## [0.6.1] - 2026-09-16
- A thing
EOF
run "no Unreleased section at all" "0.6.1" 0 "$T/no-unreleased.md"

cat >"$T/bare.md" <<'EOF'
## unreleased
## 0.7.0 - 2026-10-01
EOF
run "headings without brackets, Unreleased in any case" "0.7.0" 0 "$T/bare.md"

cat >"$T/only-unreleased.md" <<'EOF'
## [Unreleased]
### Added
- Not shipped
EOF
run "a changelog with nothing released refuses" "" 1 "$T/only-unreleased.md"
run "no file is a usage error" "" 2
run "an unknown flag is a usage error" "" 2 "$T/typical.md" --bogus

# The real thing: what release.sh runs, against the tree as it is.
PLIST_VERSION="$($PB -c 'Print CFBundleShortVersionString' "$REPO_ROOT/swift/MaxPane/Resources/Info.plist")"
run "CHANGELOG.md's top release is Info.plist's $PLIST_VERSION" "$PLIST_VERSION" 0 \
  "$REPO_ROOT/CHANGELOG.md" --expect "$PLIST_VERSION"

if [ "$fails" -gt 0 ]; then
  echo "$fails failure(s)" >&2
  exit 1
fi
