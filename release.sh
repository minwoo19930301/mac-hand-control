#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DMG_PATH="$ROOT/dist/Mac-Hand-Control.dmg"
ZIP_PATH="$ROOT/dist/Mac-Hand-Control.zip"
APP_PATH="$ROOT/build/Mac Hand Control.app"

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  echo "Set SIGN_IDENTITY to your Developer ID Application identity." >&2
  echo 'Example: SIGN_IDENTITY="Developer ID Application: Minwoo Kim (TEAMID)" NOTARY_PROFILE="mac-hand-control-notary" ./release.sh' >&2
  exit 1
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "Set NOTARY_PROFILE to a notarytool keychain profile." >&2
  echo 'Create one with: xcrun notarytool store-credentials "mac-hand-control-notary" --apple-id "you@example.com" --team-id "TEAMID"' >&2
  exit 1
fi

SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/package.sh" >/dev/null
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl -a -vvv --type open "$DMG_PATH"

echo "$DMG_PATH"
