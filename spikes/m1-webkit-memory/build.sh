#!/usr/bin/env bash
# Build the M1 spike into a real, ad-hoc-signed .app bundle.
#
# There is no Xcode on this machine, only Command Line Tools, so xcodebuild is
# unavailable. SwiftPM builds the executable; this script then hand-assembles
# the bundle WKWebView needs in order to spawn its XPC content processes
# (Contents/MacOS/<bin>, Contents/Info.plist with CFBundleIdentifier /
# CFBundlePackageType APPL / NSPrincipalClass NSApplication) and ad-hoc signs it.
#
#   ./build.sh              # build + bundle + sign
#   ./build.sh --run ...    # then run, passing remaining args to the binary
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="M1Spike"
BUNDLE_ID="com.leftjoin.maxpane.m1spike"
APP="build/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/${APP_NAME}"
test -x "$BIN" || { echo "no binary at $BIN"; exit 1; }

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "$BIN" "${APP}/Contents/MacOS/${APP_NAME}"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>Max Pane M1 Spike</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <!-- fixtures are served over plain http on loopback -->
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsLocalNetworking</key><true/>
    <key>NSAllowsArbitraryLoads</key><true/>
  </dict>
</dict></plist>
PLIST

echo "==> ad-hoc codesign"
codesign -s - --force --timestamp=none --deep "$APP"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'

echo "==> built ${APP}"

if [ "${1:-}" = "--run" ]; then
  shift
  exec "${APP}/Contents/MacOS/${APP_NAME}" "$@"
fi
