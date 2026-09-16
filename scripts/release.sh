#!/usr/bin/env bash
# Cut the GitHub release for the version in Info.plist.
#
# Refuses unless the working tree is clean, the tag `v<version>` exists, points
# at HEAD and is on origin — the DMG is built from the working tree, and a
# release whose asset does not match its tag is worse than no release. Then it
# builds the DMG through make-dmg.sh, takes the release notes from the matching
# section of CHANGELOG.md, writes the cask for that DMG to dist/, and shows the
# `gh release create` it would run.
#
# The sequence, all three steps run by the owner:
#
#   ./scripts/release.sh             1. dry run: build, print the command, stop
#   RELEASE=1 ./scripts/release.sh   2. publish: build again, create the release
#   cp dist/max-pane.rb ...          3. ship the cask (the script prints both
#                                       copies: one into the tap, one back over
#                                       packaging/Casks/max-pane.rb, then commit)
#
# Nothing here modifies a tracked file. Every DMG build hashes differently, so
# the cask's sha256 is only knowable from the asset that actually shipped; it
# is written to dist/max-pane.rb, and copying it into packaging/ afterwards is
# the owner's step. Rewriting the tracked cask in place would dirty the tree the
# publish run then refuses, and the committed hash would never match the asset.
#
# Publishing is the owner's button. Nothing here reaches GitHub without
# RELEASE=1, and nothing pushes the tag: `git push origin v<version>` is a
# separate, deliberate step.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

PLIST="swift/MaxPane/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
TAG="v$VERSION"
DMG="dist/MaxPane-$VERSION.dmg"
NOTES="dist/release-notes-$VERSION.md"
CASK="packaging/Casks/max-pane.rb"
CASK_OUT="dist/max-pane.rb"

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is not clean; commit or stash before releasing:" >&2
  git status --short >&2
  exit 1
fi
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "no tag $TAG. Create it on the commit that ships:" >&2
  echo "  git tag -a $TAG -m \"Max Pane $VERSION\" && git push origin $TAG" >&2
  exit 1
fi
if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
  echo "$TAG points at $(git rev-parse --short "$TAG^{commit}") but HEAD is $(git rev-parse --short HEAD); check out the tag or move it." >&2
  exit 1
fi
# `gh release create` fails late and confusingly on a tag GitHub has not seen.
if ! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  echo "$TAG is not on origin; push it first: git push origin $TAG" >&2
  exit 1
fi

# Release notes are the CHANGELOG section for this version, verbatim: from its
# `## [x.y.z]` heading up to the next `## [` heading (or the link references
# at the foot of the file), heading excluded. Writing them twice is how they
# drift.
mkdir -p dist
awk -v v="$VERSION" '
  /^## \[/ { keep = (index($0, "## [" v "]") == 1); next }
  /^\[[^]]+\]: / { keep = 0 }
  keep && (body || NF) { body = 1; print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$NOTES"
if [ ! -s "$NOTES" ]; then
  echo "CHANGELOG.md has no '## [$VERSION]' section; write one before releasing." >&2
  exit 1
fi

# Build the bundle from this tree every time. make-dmg.sh only builds when
# build/ is absent, and a stale bundle with the right version string still
# carries last week's code (the missing-relay-tty text shipped stale once).
# build-app.sh refuses if that bundle is running, which is the right refusal.
./scripts/build-app.sh release
./scripts/make-dmg.sh

if xcrun stapler validate -q "$DMG" >/dev/null 2>&1; then
  NOTARISED="notarised and stapled"
else
  NOTARISED="NOT notarised — strangers will see a Gatekeeper warning"
fi

# The cask's sha256 is only knowable now: make-dmg.sh has finished, and if it
# notarised, stapling rewrote the DMG. The tracked cask is the template; the
# copy with the real hash goes to dist/, never over the tracked file (see the
# header), and the diff shows what the owner will be committing.
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" \
    -e "s/^  sha256 \".*/  sha256 \"$SHA\"/" "$CASK" > "$CASK_OUT"
echo "==> $CASK_OUT: version $VERSION, sha256 $SHA"
diff -u "$CASK" "$CASK_OUT" || true

CMD=(gh release create "$TAG" "$DMG" --title "Max Pane $VERSION" --notes-file "$NOTES" --verify-tag)

echo
echo "release $TAG"
echo "  asset:  $DMG ($NOTARISED)"
echo "  notes:  $NOTES"
echo "  cask:   $CASK_OUT"
echo
# %q keeps the quoting, so the printed line can be pasted back as-is.
printf '  '; printf '%q ' "${CMD[@]}"; printf '\n\n'
if [ "${RELEASE:-}" != "1" ]; then
  echo "dry run. RELEASE=1 $0 publishes it."
  exit 0
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release $TAG already exists on GitHub; delete it or bump the version." >&2
  exit 1
fi
echo "==> publishing"
"${CMD[@]}"

# The cask can only be shipped once the asset it hashes is public, which is
# now. Two copies, both the owner's: the tap is what `brew install` reads, and
# packaging/ is where the next release starts from.
cat <<EOF

published $TAG. The cask is the remaining step, in this order:

  1. cp $CASK_OUT <path to ddrscott/homebrew-tap>/Casks/max-pane.rb
     then commit and push the tap.
  2. cp $CASK_OUT $CASK
     git add $CASK && git commit -m "chore: cask for $VERSION"
EOF
