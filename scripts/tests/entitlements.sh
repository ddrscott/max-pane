#!/usr/bin/env bash
# Every branch of scripts/entitlements.sh, without a profile from Apple.
#
# Run by scripts/test.sh's default run; also on its own. The profiles here are
# decoded plists, which entitlements.sh accepts in place of a CMS envelope, so
# the one branch this cannot reach is `security cms -D` on a real profile —
# that is the same call Xcode makes and is not ours to test.
#
# What is pinned, and why each matters:
#   - the shipped MaxPane.entitlements does not carry the passkeys key, and the
#     script refuses a base file that does: with the key and no profile the app
#     is SIGKILLed at launch (docs/acceptance.md, 2026-09-16)
#   - with no profile, the output is byte-identical to the base: the build
#     behaves exactly as it did before any of this existed
#   - an ad-hoc identity never gets the key, whatever profile is offered
#   - a profile for another bundle id turns passkeys off, not the build:
#     throwaway bundles (build/verify.app) are the everyday case
#   - a profile without the grant, an expired one, or one for another team is
#     an error, because the owner asked for passkeys and would silently not
#     get them
#   - a good profile yields the base plus exactly three keys, copied from it
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/entitlements.sh"
BASE="$REPO_ROOT/swift/MaxPane/Resources/MaxPane.entitlements"
KEY="com.apple.developer.web-browser.public-key-credential"
PB=/usr/libexec/PlistBuddy
DEVID='Developer ID Application: Test Person (TEAM123456)'

T="$(mktemp -d -t maxpane-entitlements-test)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1" >&2; fails=$((fails + 1)); }

# A decoded profile. $1 team, $2 application-identifier, $3 expiry (ISO, UTC),
# $4 "granted" or "ungranted".
profile() {
  local team="$1" appid="$2" expires="$3" grant="$4" f="$T/$5"
  local key_xml=""
  [ "$grant" = granted ] && key_xml="<key>$KEY</key><true/>"
  cat >"$f" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Name</key><string>Max Pane Developer ID</string>
  <key>TeamIdentifier</key><array><string>$team</string></array>
  <key>ExpirationDate</key><date>$expires</date>
  <key>Entitlements</key><dict>
    <key>com.apple.application-identifier</key><string>$appid</string>
    <key>com.apple.developer.team-identifier</key><string>$team</string>
    $key_xml
  </dict>
</dict></plist>
EOF
  echo "$f"
}

# run NAME EXPECTED-STDOUT EXPECTED-EXIT args...
run() {
  local name="$1" want_out="$2" want_rc="$3"; shift 3
  local out rc
  out="$("$SCRIPT" "$@" 2>"$T/err")" && rc=0 || rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail "$name: exit $rc, wanted $want_rc: $(cat "$T/err")"; return 1
  fi
  if [ "$want_rc" = 0 ] && [ "$out" != "$want_out" ]; then
    fail "$name: printed '$out', wanted '$want_out'"; return 1
  fi
  return 0
}

echo "==> scripts/entitlements.sh"

# The shipped file never carries the key.
if $PB -c "Print :$KEY" "$BASE" >/dev/null 2>&1; then
  fail "MaxPane.entitlements carries $KEY; the app will not launch with it and no profile"
else
  pass "MaxPane.entitlements does not carry the passkeys key"
fi

# ...and the script refuses a base that does, with or without a profile.
cp "$BASE" "$T/bad-base.plist"; $PB -c "Add :$KEY bool true" "$T/bad-base.plist" >/dev/null
run "refuses a base with the key" "" 1 "$T/bad-base.plist" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" \
  && pass "refuses a base file that already carries the key"

# No profile: byte-identical.
run "no profile" off 0 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" \
  && { cmp -s "$BASE" "$T/out" && pass "no profile: off, output identical to the base" || fail "no profile: output differs from the base"; }

# A named profile that is not there: off, not an error (the default path is
# named unconditionally by build-app.sh).
run "missing profile" off 0 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" --profile "$T/nope.provisionprofile" \
  && { cmp -s "$BASE" "$T/out" && pass "missing profile file: off, output identical" || fail "missing profile: output differs"; }

GOOD="$(profile TEAM123456 TEAM123456.app.ljs.maxpane 2099-01-01T00:00:00Z granted good.plist)"

# Ad-hoc: never.
run "ad-hoc" off 0 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity - --profile "$GOOD" \
  && { cmp -s "$BASE" "$T/out" && pass "ad-hoc identity: off even with a good profile" || fail "ad-hoc: output differs"; }

# Another bundle id: off, not an error.
run "throwaway bundle" off 0 "$BASE" "$T/out" --bundle-id app.ljs.maxpane.verify --identity "$DEVID" --profile "$GOOD" \
  && { cmp -s "$BASE" "$T/out" && pass "profile for another bundle id: off, output identical" || fail "other bundle: output differs"; }

# Errors.
UNGRANTED="$(profile TEAM123456 TEAM123456.app.ljs.maxpane 2099-01-01T00:00:00Z ungranted ungranted.plist)"
run "ungranted" "" 1 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" --profile "$UNGRANTED" \
  && { grep -q "does not grant $KEY" "$T/err" && pass "profile without the grant: error names the key" || fail "ungranted: wrong message: $(cat "$T/err")"; }

EXPIRED="$(profile TEAM123456 TEAM123456.app.ljs.maxpane 2020-01-01T00:00:00Z granted expired.plist)"
run "expired" "" 1 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" --profile "$EXPIRED" \
  && { grep -q "expired 2020-01-01" "$T/err" && pass "expired profile: error names the date" || fail "expired: wrong message: $(cat "$T/err")"; }

OTHER_TEAM="$(profile OTHER00000 OTHER00000.app.ljs.maxpane 2099-01-01T00:00:00Z granted team.plist)"
run "other team" "" 1 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" --profile "$OTHER_TEAM" \
  && { grep -q "team OTHER00000" "$T/err" && pass "profile for another team: error names both teams" || fail "team: wrong message: $(cat "$T/err")"; }

printf 'not a profile at all\n' >"$T/garbage.provisionprofile"
run "garbage" "" 1 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" --profile "$T/garbage.provisionprofile" \
  && pass "a file that is not a profile: error"

# On.
if run "good" on 0 "$BASE" "$T/out" --bundle-id app.ljs.maxpane --identity "$DEVID" --profile "$GOOD"; then
  ok=1
  [ "$($PB -c "Print :$KEY" "$T/out")" = true ] || { ok=0; fail "good: $KEY missing from output"; }
  [ "$($PB -c 'Print :com.apple.application-identifier' "$T/out")" = TEAM123456.app.ljs.maxpane ] || { ok=0; fail "good: application-identifier not copied"; }
  [ "$($PB -c 'Print :com.apple.developer.team-identifier' "$T/out")" = TEAM123456 ] || { ok=0; fail "good: team-identifier not copied"; }
  # Every base key survives, and nothing else was added.
  for k in $($PB -c 'Print' "$BASE" | sed -n 's/^    \([^ ]*\) = .*/\1/p'); do
    [ "$($PB -c "Print :$k" "$T/out")" = "$($PB -c "Print :$k" "$BASE")" ] || { ok=0; fail "good: base key $k changed"; }
  done
  n_base="$($PB -c 'Print' "$BASE" | grep -c '^    [^ ]* = ')"
  n_out="$($PB -c 'Print' "$T/out" | grep -c '^    [^ ]* = ')"
  [ "$n_out" = "$((n_base + 3))" ] || { ok=0; fail "good: expected $((n_base + 3)) keys, got $n_out"; }
  [ "$ok" = 1 ] && pass "good profile: on; base plus the key and the two identifiers"
fi

# A wildcard profile covers a throwaway bundle too.
WILD="$(profile TEAM123456 'TEAM123456.*' 2099-01-01T00:00:00Z granted wild.plist)"
run "wildcard" on 0 "$BASE" "$T/out" --bundle-id app.ljs.maxpane.verify --identity "$DEVID" --profile "$WILD" \
  && pass "wildcard profile: on for a throwaway bundle id"

if [ "$fails" -gt 0 ]; then
  echo "entitlements: $fails failure(s)" >&2
  exit 1
fi
echo "entitlements: all branches pass"
