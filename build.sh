#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/Mac Hand Control.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
rm -f "$MACOS_DIR/MacHandControl"

swiftc \
  -target arm64-apple-macosx14.0 \
  -O \
  -module-cache-path "$MODULE_CACHE_DIR" \
  -framework Cocoa \
  -framework AVFoundation \
  -framework Vision \
  -framework ApplicationServices \
  -framework CoreGraphics \
  "$ROOT/Sources/MacHandControl/main.swift" \
  -o "$MACOS_DIR/MacHandControl"

cp "$ROOT/Info.plist" "$CONTENTS_DIR/Info.plist"
swift "$ROOT/Scripts/make_icon.swift" "$ROOT" >/dev/null
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$ROOT/Resources/AppIcon.icns"
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$APP_DIR" >/dev/null
else
  codesign \
    --force \
    --sign - \
    --requirements '=designated => identifier "local.codex.MacHandControl"' \
    "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
