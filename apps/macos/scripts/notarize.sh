#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-${GHOSTSTREAM_NOTARIZE_TARGET:-$PWD/build/Release/export/GhostStream.app}}"

if [[ ! -e "$TARGET" ]]; then
  echo "Notarization target not found: $TARGET" >&2
  exit 1
fi

NOTARY_PROFILE="${GHOSTSTREAM_NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${GHOSTSTREAM_NOTARY_KEY_PATH:-${GHOSTSTREAM_ASC_KEY_PATH:-}}"
NOTARY_KEY_ID="${GHOSTSTREAM_NOTARY_KEY_ID:-${GHOSTSTREAM_ASC_KEY_ID:-}}"
NOTARY_ISSUER_ID="${GHOSTSTREAM_NOTARY_ISSUER_ID:-${GHOSTSTREAM_ASC_ISSUER_ID:-}}"
NOTARY_APPLE_ID="${GHOSTSTREAM_NOTARY_APPLE_ID:-}"
NOTARY_PASSWORD="${GHOSTSTREAM_NOTARY_PASSWORD:-}"
NOTARY_TEAM_ID="${GHOSTSTREAM_NOTARY_TEAM_ID:-${GHOSTSTREAM_DEVELOPMENT_TEAM:-UPG896A272}}"

declare -a notary_args
if [[ -n "$NOTARY_PROFILE" ]]; then
  notary_args=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "$NOTARY_KEY_PATH$NOTARY_KEY_ID$NOTARY_ISSUER_ID" ]]; then
  if [[ -z "$NOTARY_KEY_PATH" || -z "$NOTARY_KEY_ID" || -z "$NOTARY_ISSUER_ID" ]]; then
    echo "Notary API key auth requires key path, key id and issuer id." >&2
    exit 1
  fi
  notary_args=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "$NOTARY_APPLE_ID$NOTARY_PASSWORD" ]]; then
  if [[ -z "$NOTARY_APPLE_ID" || -z "$NOTARY_PASSWORD" ]]; then
    echo "Apple ID notarization requires GHOSTSTREAM_NOTARY_APPLE_ID and GHOSTSTREAM_NOTARY_PASSWORD." >&2
    exit 1
  fi
  notary_args=(--apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID")
else
  cat >&2 <<EOF
Missing notarization credentials.
Use one of:
  GHOSTSTREAM_NOTARY_PROFILE
  GHOSTSTREAM_NOTARY_KEY_PATH + GHOSTSTREAM_NOTARY_KEY_ID + GHOSTSTREAM_NOTARY_ISSUER_ID
  GHOSTSTREAM_NOTARY_APPLE_ID + GHOSTSTREAM_NOTARY_PASSWORD + optional GHOSTSTREAM_NOTARY_TEAM_ID
EOF
  exit 1
fi

SUBMIT_TARGET="$TARGET"
TMP_DIR=""
if [[ -d "$TARGET" && "$TARGET" == *.app ]]; then
  TMP_DIR="$(mktemp -d)"
  trap '[[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"' EXIT
  SUBMIT_TARGET="$TMP_DIR/$(basename "$TARGET").zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT_TARGET"
fi

xcrun notarytool submit "$SUBMIT_TARGET" --wait "${notary_args[@]}"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

case "$TARGET" in
  *.app)
    spctl --assess --type execute --verbose=4 "$TARGET"
    ;;
  *.dmg)
    spctl --assess --type open --context context:primary-signature --verbose=4 "$TARGET"
    ;;
esac

echo "$TARGET"
