#!/bin/bash
# Builds out/M6Spike.app. No Xcode: swiftc + a hand-made bundle, ad-hoc signed,
# the way the app itself is built. The deployment target is deliberately
# macOS 14.0 — the app's floor — so this binary is the weak-linking test: it
# must build, and `nm -m` must show OBJC_CLASS_$_WKWebExtension* as weak.
set -euo pipefail
cd "$(dirname "$0")"
APP=out/M6Spike.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O \
  -target arm64-apple-macos14.0 \
  -import-objc-header shim.h \
  -framework AppKit -framework WebKit \
  main.swift -o "$APP/Contents/MacOS/M6Spike"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
echo "--- WKWebExtension symbols (expect 'weak external'):"
nm -m "$APP/Contents/MacOS/M6Spike" | grep -E "undefined.*WKWebExtension" | sed 's/^ *//'
echo "--- LC_BUILD_VERSION:"
otool -l "$APP/Contents/MacOS/M6Spike" | grep -A4 LC_BUILD_VERSION | grep -E "minos|sdk" | sed 's/^ *//'
