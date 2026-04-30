#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${GHOSTSTREAM_DEVELOPMENT_TEAM:-UPG896A272}"
SIGN_IDENTITY="${GHOSTSTREAM_CODE_SIGN_IDENTITY:-Apple Development}"
DESTINATION="${GHOSTSTREAM_DESTINATION:-platform=macOS,arch=$(uname -m)}"
DERIVED_DATA_PATH="${GHOSTSTREAM_DERIVED_DATA_PATH:-$PWD/build/DerivedData}"

declare -a provisioning_args
declare -a signing_args

if [[ "${GHOSTSTREAM_UNSIGNED:-0}" == "1" ]]; then
  signing_args=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=-
  )
else
  if [[ "${GHOSTSTREAM_ALLOW_PROVISIONING:-0}" == "1" ]]; then
    provisioning_args=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration)
  fi
  signing_args=(
    DEVELOPMENT_TEAM="$TEAM_ID"
    CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
  )
fi

DEBUG_PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/Debug"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr GhostStream \
            PacketTunnelExtension \
            ../ios/Packages/PhantomKit \
            ../ios/Frameworks/PhantomCore.xcframework 2>/dev/null || true
  if [[ -d "$DEBUG_PRODUCTS_DIR" ]]; then
    xattr -cr "$DEBUG_PRODUCTS_DIR" 2>/dev/null || true
  fi
fi
rm -rf "$DEBUG_PRODUCTS_DIR/GhostStream.app" \
       "$DEBUG_PRODUCTS_DIR/PacketTunnelExtension.systemextension" \
       "$DEBUG_PRODUCTS_DIR/com.ghoststream.vpn.tunnel.systemextension" \
       "$DEBUG_PRODUCTS_DIR"/PhantomKit_*.bundle

xcodegen generate
if [[ ${#provisioning_args[@]} -gt 0 ]]; then
  xcodebuild -project GhostStream.xcodeproj \
             -scheme GhostStream \
             -destination "$DESTINATION" \
             -configuration Debug \
             -derivedDataPath "$DERIVED_DATA_PATH" \
             -quiet \
             "${provisioning_args[@]}" \
             build \
             "${signing_args[@]}" \
             "$@"
else
  xcodebuild -project GhostStream.xcodeproj \
             -scheme GhostStream \
             -destination "$DESTINATION" \
             -configuration Debug \
             -derivedDataPath "$DERIVED_DATA_PATH" \
             -quiet \
             build \
             "${signing_args[@]}" \
             "$@"
fi
