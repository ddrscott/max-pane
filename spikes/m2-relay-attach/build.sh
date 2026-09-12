#!/bin/zsh
# Reproducible build of the M2 spike: SwiftPM library + CLI bench + a hand-assembled
# AppKit .app bundle (no Xcode on this machine — Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
swift build -c "$CONFIG"

BIN=".build/$CONFIG/M2Harness"
APP="M2Harness.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/M2Harness"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>M2Harness</string>
  <key>CFBundleDisplayName</key>       <string>M2 Relay Attach Harness</string>
  <key>CFBundleIdentifier</key>        <string>studio.leftjoin.maxpane.m2harness</string>
  <key>CFBundleVersion</key>           <string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key>        <string>M2Harness</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleSignature</key>         <string>????</string>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
</dict>
</plist>
PLIST
codesign -s - --force --deep "$APP" >/dev/null 2>&1
echo "built $APP  (run: ./$APP/Contents/MacOS/M2Harness)"
