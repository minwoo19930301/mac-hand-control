#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$ROOT/dist"
STAGE_DIR="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/Mac-Hand-Control.dmg"

APP_PATH="$("$ROOT/build.sh")"

rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR"

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "Mac Hand Control" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

rm -rf "$STAGE_DIR"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign \
    --force \
    --timestamp \
    --sign "$SIGN_IDENTITY" \
    "$DMG_PATH" >/dev/null
fi

echo "$DMG_PATH"
