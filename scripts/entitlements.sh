#!/usr/bin/env bash
# Decide the entitlements a bundle is signed with, and whether the passkeys
# capability goes in.
#
#   ./scripts/entitlements.sh BASE OUT --bundle-id ID --identity IDENTITY [--profile PATH]
#
# Writes OUT and prints one word on stdout: `on` when OUT carries
# `com.apple.developer.web-browser.public-key-credential` and the caller must
# embed PATH as Contents/embedded.provisionprofile, `off` when OUT is a
# byte-for-byte copy of BASE. Everything else it has to say goes to stderr.
#
# Why this is its own script. The passkeys key is a *managed capability*: Apple
# grants it to a Developer ID team after reviewing the app as a web browser, and
# the grant arrives as a provisioning profile. A bundle signed with the key and
# no profile that vouches for it is SIGKILLed at launch before it writes a byte
# (exit 137, nothing in the unified log naming why — measured 2026-09-16, see
# docs/acceptance.md). So the key is never in MaxPane.entitlements, and this
# script adds it only when a profile that actually covers this bundle is in
# hand. The decision has enough branches to deserve a test, and a test cannot
# call codesign, so the decision is separated from the signing.
#
# The branches:
#
#   no --profile, or the path does not exist   off: MaxPane.entitlements as is
#   --identity -  (ad-hoc)                      off: an ad-hoc signature has no
#                                               team, so no profile can vouch
#                                               for it; the key would kill the app
#   profile's application-identifier does not   off: a throwaway bundle
#   match --bundle-id                           (app.ljs.maxpane.verify) is not
#                                               the app Apple approved
#   profile is not a profile, lacks the key,    error, exit 1: the owner asked
#   is expired, or names another team           for passkeys and would not get
#                                               them; say so rather than ship
#                                               a build that quietly lacks them
#   otherwise                                   on: BASE plus the key and the
#                                               two identifier keys the profile
#                                               demands, copied from the profile
#
# The identifier keys. A profile pins `com.apple.application-identifier`
# (`TEAMID.bundle.id`, or `TEAMID.*`) and `com.apple.developer.team-identifier`,
# and the kernel matches the signed entitlements against them; Xcode adds both
# silently, we add them here. They are copied out of the profile rather than
# typed, so they cannot disagree with it.
#
# PATH may be a real `.provisionprofile` (CMS-signed; decoded with
# `security cms -D`) or an already-decoded plist (XML or binary), which is how
# the test in scripts/tests/entitlements.sh exercises every branch without a
# profile from Apple. Nothing is verified about the CMS signature: the kernel
# does that at launch and would refuse a forgery there.
set -euo pipefail

KEY="com.apple.developer.web-browser.public-key-credential"
PB=/usr/libexec/PlistBuddy

usage() {
  echo "usage: $0 BASE OUT --bundle-id ID --identity IDENTITY [--profile PATH]" >&2
  exit 2
}

[ $# -ge 2 ] || usage
BASE="$1"; OUT="$2"; shift 2
BUNDLE_ID=""; IDENTITY=""; PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="${2:-}"; shift 2 ;;
    --identity)  IDENTITY="${2:-}";  shift 2 ;;
    --profile)   PROFILE="${2:-}";   shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$BUNDLE_ID" ] && [ -n "$IDENTITY" ] || usage
[ -f "$BASE" ] || { echo "$0: no entitlements file at $BASE" >&2; exit 1; }

# The shipped file must never carry the key itself; that is the launch-killer
# this script exists to prevent, and a stray edit there would bypass every
# branch below.
if $PB -c "Print :$KEY" "$BASE" >/dev/null 2>&1; then
  echo "$0: $BASE carries $KEY; that key only ever comes from a profile (see the comment in this script)." >&2
  exit 1
fi

off() {
  cp "$BASE" "$OUT"
  echo "passkeys: off — $1" >&2
  echo off
  exit 0
}

[ -n "$PROFILE" ] || off "no provisioning profile named (MAXPANE_PROVISIONING_PROFILE)"
[ -f "$PROFILE" ] || off "no provisioning profile at $PROFILE"
[ "$IDENTITY" != "-" ] || off "ad-hoc signature; a managed capability needs a Developer ID team, so the profile at $PROFILE is not used"

# Decode. A CMS envelope is DER and starts with 0x30; a plist starts with
# `<?xml` / `<!DOC` / `<plis` or `bplist`.
DECODED="$(mktemp -t maxpane-profile)"
trap 'rm -f "$DECODED"' EXIT
case "$(head -c 6 "$PROFILE")" in
  '<?xml '|'<!DOCT'|'<plist'|bplist) cp "$PROFILE" "$DECODED" ;;
  *)
    if ! security cms -D -i "$PROFILE" -o "$DECODED" 2>/dev/null; then
      echo "$0: $PROFILE is not a provisioning profile (security cms could not decode it)" >&2
      exit 1
    fi ;;
esac
plutil -lint -s "$DECODED" >/dev/null 2>&1 || { echo "$0: $PROFILE decoded to something that is not a plist" >&2; exit 1; }

pb() { $PB -c "Print $1" "$DECODED" 2>/dev/null; }

# The capability itself.
if [ "$(pb ":Entitlements:$KEY")" != "true" ]; then
  echo "$0: the profile at $PROFILE does not grant $KEY." >&2
  echo "    Apple's grant has to be added to the profile in the developer portal; see the README, \"Passkeys and the provisioning profile\"." >&2
  exit 1
fi

# Expiry. `plutil -extract raw` prints a date as ISO 8601 in UTC.
EXPIRES="$(plutil -extract ExpirationDate raw -o - "$DECODED" 2>/dev/null || true)"
if [ -z "$EXPIRES" ]; then
  echo "$0: the profile at $PROFILE has no ExpirationDate" >&2
  exit 1
fi
EXPIRES_S="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$EXPIRES" +%s 2>/dev/null || echo 0)"
if [ "$EXPIRES_S" -le "$(date +%s)" ]; then
  echo "$0: the profile at $PROFILE expired $EXPIRES; download a fresh one from the developer portal." >&2
  exit 1
fi

# Team. The identity reads `Developer ID Application: Name (TEAMID)`.
PROFILE_TEAM="$(pb ':TeamIdentifier:0')"
IDENTITY_TEAM="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$IDENTITY")"
if [ -n "$IDENTITY_TEAM" ] && [ "$PROFILE_TEAM" != "$IDENTITY_TEAM" ]; then
  echo "$0: the profile at $PROFILE is for team $PROFILE_TEAM but the signing identity is $IDENTITY ($IDENTITY_TEAM)." >&2
  exit 1
fi

# Which app the profile covers. `TEAMID.bundle.id` exactly, or `TEAMID.*`.
APP_ID="$(pb ':Entitlements:com.apple.application-identifier')"
TEAM_ID="$(pb ':Entitlements:com.apple.developer.team-identifier')"
[ -n "$APP_ID" ] && [ -n "$TEAM_ID" ] || { echo "$0: the profile at $PROFILE names no application-identifier / team-identifier" >&2; exit 1; }
case "$APP_ID" in
  "$PROFILE_TEAM.$BUNDLE_ID"|"$PROFILE_TEAM.*") ;;
  *) off "the profile at $PROFILE covers $APP_ID, not $BUNDLE_ID (a throwaway bundle is not the app Apple approved)" ;;
esac

# On. The base file, plus what the profile demands.
cp "$BASE" "$OUT"
$PB -c "Add :$KEY bool true" "$OUT" >/dev/null
$PB -c "Add :com.apple.application-identifier string $APP_ID" "$OUT" >/dev/null
$PB -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$OUT" >/dev/null
plutil -lint -s "$OUT" >/dev/null
echo "passkeys: on — profile $PROFILE (team $TEAM_ID, app $APP_ID, expires $EXPIRES)" >&2
echo on
