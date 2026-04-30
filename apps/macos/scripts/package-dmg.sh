#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:-${GHOSTSTREAM_APP_PATH:-$PWD/build/Release/export/GhostStream.app}}"
DIST_DIR="${GHOSTSTREAM_DIST_DIR:-$PWD/build/Release/dist}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo dev)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 0)"
DMG_PATH="${GHOSTSTREAM_DMG_PATH:-$DIST_DIR/GhostStream-$VERSION-$BUILD-macOS.dmg}"
STAGING_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

ditto "$APP_PATH" "$STAGING_DIR/GhostStream.app"
ln -s /Applications "$STAGING_DIR/Applications"

if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "GhostStream" \
    --window-pos 200 120 \
    --window-size 640 420 \
    --icon-size 128 \
    --icon "GhostStream.app" 160 190 \
    --app-drop-link 450 190 \
    --hide-extension "GhostStream.app" \
    "$DMG_PATH" \
    "$STAGING_DIR"
else
  hdiutil create \
    -volname "GhostStream" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

if [[ "${GHOSTSTREAM_SIGN_DMG:-0}" == "1" ]]; then
  DMG_SIGN_IDENTITY="${GHOSTSTREAM_DMG_CODE_SIGN_IDENTITY:-${GHOSTSTREAM_CODE_SIGN_IDENTITY:-Developer ID Application}}"
  codesign --force --timestamp --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
  codesign --verify --verbose=2 "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"

echo "$DMG_PATH"
