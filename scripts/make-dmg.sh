#!/usr/bin/env bash
# Package build/MaxPane.app as dist/MaxPane-<version>.dmg.
#
# The DMG is what a stranger downloads from the GitHub release, so this is the
# one place the app has to be right for a machine that is not this one: signed
# with the Developer ID, not ad-hoc, and notarised when the credential to do it
# exists. Only `hdiutil` and the Xcode command line tools are used — nothing
# from Homebrew, so the release box needs nothing installed.
#
#   ./scripts/make-dmg.sh              package build/MaxPane.app (built if absent)
#   MAXPANE_NOTARIZE=0 ./scripts/make-dmg.sh   skip notarisation even if set up
#
# The version comes from Info.plist, the same file the app reads at runtime, so
# the file name and the About box cannot disagree.
#
# Notarisation is gated on a notarytool keychain profile named `maxpane-notary`
# (MAXPANE_NOTARY_PROFILE overrides). Without it the script builds the DMG,
# says plainly that it is not notarised, prints the one command that sets the
# profile up, and exits 0. It never prompts: a release script that stops to ask
# for an Apple ID password is a release script that hangs in CI.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

APP="${MAXPANE_APP:-build/MaxPane.app}"
PLIST="swift/MaxPane/Resources/Info.plist"
VOLNAME="Max Pane"
NOTARY_PROFILE="${MAXPANE_NOTARY_PROFILE:-maxpane-notary}"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
DMG="dist/MaxPane-$VERSION.dmg"

# Build the app if there is none. build-app.sh refuses to demolish a running
# bundle; the check is repeated here so the refusal names this script.
if [ ! -d "$APP" ]; then
  if pgrep -f "$APP/Contents/MacOS/MaxPane" >/dev/null 2>&1; then
    echo "refusing to build $APP: an instance of it is running (pid $(pgrep -f "$APP/Contents/MacOS/MaxPane" | tr '\n' ' '))." >&2
    echo "quit it first, or point MAXPANE_APP at a bundle nobody is running." >&2
    exit 1
  fi
  ./scripts/build-app.sh release
fi

# A stale bundle is the most likely way to ship the wrong build: Info.plist was
# bumped, build-app.sh was not re-run, and the DMG name says 0.5.0 while the
# binary inside is whatever was compiled last week.
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
if [ "$BUNDLE_VERSION" != "$VERSION" ]; then
  echo "$APP is version $BUNDLE_VERSION but $PLIST says $VERSION; rebuild it: ./scripts/build-app.sh release" >&2
  exit 1
fi

# Same identity logic as build-app.sh. An ad-hoc signed app inside a DMG is
# exactly the Gatekeeper scare this script exists to prevent — "Apple could not
# verify" on every stranger's Mac — so ad-hoc is refused rather than shipped.
IDENTITY="${MAXPANE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  echo "no Developer ID Application identity on this machine; a DMG of an ad-hoc signed app" >&2
  echo "opens with a Gatekeeper warning on every other Mac. Refusing to package it." >&2
  exit 1
fi
# The identity reads `Developer ID Application: Name (TEAMID)`; the team id
# notarytool wants is the parenthesised part. Derived, not typed, so the help
# text below is right on whichever Mac and account is doing the release.
TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$IDENTITY")"
TEAM_ID="${TEAM_ID:-<team id>}"
# Captured once: with pipefail, `codesign | grep -q` fails on a match, because
# grep exits early and codesign dies of SIGPIPE.
SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
if ! grep -qxF "Authority=$IDENTITY" <<<"$SIGNATURE"; then
  echo "$APP is not signed by \"$IDENTITY\"; rebuild it on this machine: ./scripts/build-app.sh release" >&2
  grep '^Authority=' <<<"$SIGNATURE" >&2 || true
  exit 1
fi
codesign --verify --deep --strict "$APP"

# Apple rejects a submission whose binaries lack the hardened runtime or a
# secure timestamp. build-app.sh signs with both (and the entitlements in
# swift/MaxPane/Resources/MaxPane.entitlements that keep the camera, location and
# microphone grantable under the runtime), so a miss here means a stale bundle
# or an offline build that fell back to --timestamp=none. Checked before the
# image is built and whether or not notarisation is set up, so the DMG that
# exists is always one Apple would accept.
MISSING=""
grep -q 'flags=.*runtime' <<<"$SIGNATURE" || MISSING="$MISSING hardened-runtime"
grep -q '^Timestamp=' <<<"$SIGNATURE" || MISSING="$MISSING secure-timestamp"
if [ -n "$MISSING" ]; then
  echo "$APP is not notarisable: missing$MISSING." >&2
  echo "rebuild it online: ./scripts/build-app.sh release (it signs with --options runtime --timestamp)." >&2
  exit 1
fi
echo "==> notarisable: hardened runtime and secure timestamp present"

# Passkeys. The bundle either carries the web-browser public-key-credential
# entitlement *and* the provisioning profile that grants it, or neither. The
# key without the profile is an app that is SIGKILLed on every Mac at launch;
# the profile without the key is a build that had passkeys in hand and did not
# take them. build-app.sh (via scripts/entitlements.sh) produces only the two
# consistent states, so a mismatch here is a hand-edited bundle.
PASSKEY="com.apple.developer.web-browser.public-key-credential"
HAS_KEY=0; HAS_PROFILE=0
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "<key>$PASSKEY</key>" && HAS_KEY=1
[ -f "$APP/Contents/embedded.provisionprofile" ] && HAS_PROFILE=1
if [ "$HAS_KEY" != "$HAS_PROFILE" ]; then
  if [ "$HAS_KEY" = 1 ]; then
    echo "$APP is signed with $PASSKEY but has no Contents/embedded.provisionprofile: it will not launch anywhere." >&2
  else
    echo "$APP embeds a provisioning profile but is not signed with $PASSKEY." >&2
  fi
  echo "rebuild it: ./scripts/build-app.sh release" >&2
  exit 1
fi
if [ "$HAS_KEY" = 1 ]; then
  echo "==> passkeys: entitlement and embedded profile present"
else
  echo "==> passkeys: off (no provisioning profile; see the README, \"Passkeys and the provisioning profile\")"
fi

# Notarisation. `history` is the cheapest call that proves the profile exists
# and the credentials in it work; anything else it says is treated as "cannot
# notarise from here" and reported, never guessed around. Decided once, here,
# because two things get notarised below and the answer is the same for both.
NOTARY_READY=0
notary_check() {
  local err
  if [ "${MAXPANE_NOTARIZE:-1}" = "0" ]; then
    echo "==> notarisation skipped (MAXPANE_NOTARIZE=0)"
    return 0
  fi
  if ! err="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
    echo "==> NOT notarised: the DMG will be signed but Apple will not have seen it."
    if grep -q 'No Keychain password item' <<<"$err"; then
      cat <<EOF
    A stranger's Mac will still warn on first open. To enable notarisation, run
    once (the password is an app-specific password from appleid.apple.com, not
    the Apple ID password):

      xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id email> --team-id $TEAM_ID --password <app-specific password>

    then re-run $0.
EOF
    else
      echo "    notarytool could not use profile '$NOTARY_PROFILE':" >&2
      sed 's/^/    /' <<<"$err" >&2
    fi
    return 0
  fi

  NOTARY_READY=1
}
notary_check

# Submit one file to Apple and staple its ticket on. notarytool takes a DMG as
# it is and an app only as a zip, so an app goes up zipped and the ticket comes
# back onto the bundle itself.
notarize_and_staple() {
  local path="$1" what="$2" upload submit id status
  echo "==> notarising $what with profile $NOTARY_PROFILE (waits for Apple; minutes, not seconds)"
  upload="$path"
  if [ -d "$path" ]; then
    upload="$STAGE/$(basename "$path").zip"
    ditto -c -k --keepParent "$path" "$upload"
  fi
  submit="$STAGE/submit-$what.json"
  xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$submit" || true
  # plutil reads JSON, so no jq dependency on the release box.
  id="$(plutil -extract id raw -o - "$submit" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$submit" 2>/dev/null || true)"
  if [ "$status" != "Accepted" ]; then
    echo "notarisation of $what ${status:-failed} (submission ${id:-unknown}); Apple's log follows." >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    exit 1
  fi
  echo "==> stapling $what"
  xcrun stapler staple "$path"
}

# Stage a folder with the app and an Applications symlink — the drag-to-install
# layout every Mac user already knows. `ditto` rather than `cp -R`: it keeps
# the bundle byte-for-byte, and a copy that drops an extended attribute breaks
# the code signature with no message until Gatekeeper refuses it.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/maxpane-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/MaxPane.app"
ln -s /Applications "$STAGE/Applications"

# The app gets its own ticket, stapled before the image is built: the image is
# read-only once made, so this is the only moment the bundle inside it can be
# stapled. A DMG ticket alone lets the *download* open offline; the app copied
# out of it still had to ask Apple, on a Mac with no network, the first time it
# ran. Two submissions, one per thing a user ends up with.
if [ "$NOTARY_READY" = 1 ]; then
  notarize_and_staple "$STAGE/MaxPane.app" app
  xcrun stapler validate "$STAGE/MaxPane.app"
fi

echo "==> $DMG"
mkdir -p dist
rm -f "$DMG"
# UDZO (zlib-compressed, read-only) is the format Finder mounts without asking
# anything. HFS+ rather than APFS: it mounts on anything, and the image holds
# one app and one symlink, so APFS buys nothing.
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

# Sign the image itself so Gatekeeper can name who made it, with a secure
# timestamp because notarisation requires one. `--timestamp` talks to Apple's
# timestamp server, so this is the first step here that needs the network.
echo "==> signing DMG as $IDENTITY"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"

# The image: its own ticket, so the download opens offline too. Stapling
# changes the file, which is why the sha256 below is printed last.
if [ "$NOTARY_READY" = 1 ]; then
  notarize_and_staple "$DMG" dmg
  echo "==> Gatekeeper's verdict on the image:"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi


echo
echo "built $DMG"
echo "  sha256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "  size:    $(du -h "$DMG" | awk '{print $1}')"
echo "  version: $VERSION"
