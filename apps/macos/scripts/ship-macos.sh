#!/usr/bin/env bash
#
# One-shot release pipeline for macOS:
#   1. Archive + export a signed Release .app (build-release.sh)
#   2. Notarize the .app and staple its ticket (notarize.sh)
#   3. Package a signed DMG around the notarised .app (package-dmg.sh)
#   4. Notarize the DMG and staple its ticket (notarize.sh)
#   5. Validate + report final artefact path
#
# Result: a DMG that opens cleanly on any Apple Silicon Mac even without
# internet access (Gatekeeper accepts the stapled ticket), even when the
# file carries the `com.apple.quarantine` xattr (Telegram / AirDrop /
# iCloud Drive / Safari download).
#
# Reads credentials from environment variables — typically by sourcing
# `<repo-root>/.env` before invocation:
#   set -a; source .env; set +a
#   apps/macos/scripts/ship-macos.sh
#
# Required env vars (mirrors build-release.sh + notarize.sh):
#   GHOSTSTREAM_APP_PROVISIONING_PROFILE_SPECIFIER   (e.g. "ghoststream")
#   GHOSTSTREAM_TUNNEL_PROVISIONING_PROFILE_SPECIFIER (e.g. "ghoststream-2")
#   Notary credentials — one of:
#     GHOSTSTREAM_NOTARY_PROFILE                     (keychain profile)
#     GHOSTSTREAM_ASC_KEY_PATH + _KEY_ID + _ISSUER_ID (App Store Connect API key)
#     GHOSTSTREAM_NOTARY_APPLE_ID + _NOTARY_PASSWORD (+ optional _TEAM_ID)
#
# Optional env vars:
#   GHOSTSTREAM_DIST_COPY_DIR=~/Downloads   — also copy the final DMG here
#
set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

echo ""
echo "==> [1/4] Build release archive + export .app"
echo "    (scripts/build-release.sh — xcodebuild archive + export)"
"$SCRIPTS_DIR/build-release.sh" "$@"

APP_PATH="${GHOSTSTREAM_EXPORT_PATH:-$PWD/build/Release/export}/GhostStream.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected .app missing: $APP_PATH" >&2
  exit 1
fi

echo ""
echo "==> [2/4] Notarize + staple .app"
"$SCRIPTS_DIR/notarize.sh" "$APP_PATH"

echo ""
echo "==> [3/4] Package signed DMG"
GHOSTSTREAM_SIGN_DMG=1 \
GHOSTSTREAM_NOTARIZE_DMG=0 \
  "$SCRIPTS_DIR/package-dmg.sh" "$APP_PATH"

DMG_PATH="$(ls -t "$PWD/build/Release/dist"/GhostStream-*.dmg 2>/dev/null | head -1)"
if [[ -z "$DMG_PATH" || ! -f "$DMG_PATH" ]]; then
  echo "DMG was not created" >&2
  exit 1
fi

echo ""
echo "==> [4/4] Notarize + staple DMG"
"$SCRIPTS_DIR/notarize.sh" "$DMG_PATH"

echo ""
echo "==> Validation"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature -v "$DMG_PATH" 2>&1 | tail -3

if [[ -n "${GHOSTSTREAM_DIST_COPY_DIR:-}" ]]; then
  mkdir -p "$GHOSTSTREAM_DIST_COPY_DIR"
  cp -v "$DMG_PATH" "$GHOSTSTREAM_DIST_COPY_DIR/"
fi

echo ""
echo "===================================================================="
echo " Release DMG ready:"
echo "   $DMG_PATH"
[[ -n "${GHOSTSTREAM_DIST_COPY_DIR:-}" ]] && echo "   $GHOSTSTREAM_DIST_COPY_DIR/$(basename "$DMG_PATH")"
echo "===================================================================="
