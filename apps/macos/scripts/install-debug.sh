#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DESTINATION="${GHOSTSTREAM_DESTINATION:-platform=macOS,arch=$(uname -m)}"
DERIVED_DATA_PATH="${GHOSTSTREAM_DERIVED_DATA_PATH:-$PWD/build/DerivedData}"
BUILD_PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Debug"
SOURCE_APP="$BUILD_PRODUCTS_DIR/GhostStream.app"
INSTALLED_APP="${GHOSTSTREAM_INSTALL_PATH:-/Applications/GhostStream.app}"

if [[ "${GHOSTSTREAM_SKIP_BUILD:-0}" != "1" ]]; then
  GHOSTSTREAM_ALLOW_PROVISIONING="${GHOSTSTREAM_ALLOW_PROVISIONING:-1}" \
  GHOSTSTREAM_DERIVED_DATA_PATH="$DERIVED_DATA_PATH" \
  GHOSTSTREAM_DESTINATION="$DESTINATION" \
    ./scripts/build-debug.sh "$@"
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Built app not found: $SOURCE_APP" >&2
  exit 1
fi

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$SOURCE_APP" 2>/dev/null || true
fi

if pgrep -x GhostStream >/dev/null 2>&1; then
  osascript -e 'tell application "GhostStream" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x GhostStream >/dev/null 2>&1 || true
fi

rm -rf "$INSTALLED_APP"
ditto "$SOURCE_APP" "$INSTALLED_APP"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$INSTALLED_APP" 2>/dev/null || true
fi

codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"

if [[ "${GHOSTSTREAM_OPEN_AFTER_INSTALL:-1}" == "1" ]]; then
  open "$INSTALLED_APP"
fi

echo "$INSTALLED_APP"
