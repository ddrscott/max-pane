#!/bin/bash
# Build GalleryScale and hand-assemble a minimal .app bundle (no Xcode; CLT only).
# A bundle and an ad-hoc signature are what WebKit needs before it will spawn
# content processes, and the web phase needs those.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=${CONFIG:-release}
APP="$PWD/GalleryScale.app"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GalleryScale" "$APP/Contents/MacOS/GalleryScale"
# Ghostty's resources (terminfo, shell integration) ship as a SwiftPM bundle.
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>GalleryScale</string>
  <key>CFBundleExecutable</key><string>GalleryScale</string>
  <key>CFBundleIdentifier</key><string>studio.leftjoin.maxpane.galleryscale</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <!-- An agent app: no Dock icon, never takes focus from whoever is working. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign -s - --force --deep --timestamp=none "$APP" >/dev/null 2>&1
echo "built: $APP"
