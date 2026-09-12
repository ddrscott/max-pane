#!/bin/bash
# Build StripBench and hand-assemble a minimal .app bundle (no Xcode; CLT only).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="$PWD/StripBench.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/StripBench"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StripBench"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>StripBench</string>
  <key>CFBundleDisplayName</key><string>StripBench</string>
  <key>CFBundleExecutable</key><string>StripBench</string>
  <key>CFBundleIdentifier</key><string>studio.leftjoin.maxpane.stripbench</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSUIElement</key><false/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign -s - --force --deep --timestamp=none "$APP" >/dev/null 2>&1
codesign -dv "$APP" 2>&1 | head -3
echo "built: $APP"
