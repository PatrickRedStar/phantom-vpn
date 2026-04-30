#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${GHOSTSTREAM_DEVELOPMENT_TEAM:-UPG896A272}"
CODE_SIGN_STYLE="${GHOSTSTREAM_CODE_SIGN_STYLE:-Automatic}"
CONFIGURATION="${GHOSTSTREAM_CONFIGURATION:-Release}"
DESTINATION="${GHOSTSTREAM_DESTINATION:-generic/platform=macOS}"
DERIVED_DATA_PATH="${GHOSTSTREAM_DERIVED_DATA_PATH:-$PWD/build/ReleaseDerivedData}"
RELEASE_DIR="${GHOSTSTREAM_RELEASE_DIR:-$PWD/build/Release}"
ARCHIVE_PATH="${GHOSTSTREAM_ARCHIVE_PATH:-$RELEASE_DIR/GhostStream.xcarchive}"
EXPORT_PATH="${GHOSTSTREAM_EXPORT_PATH:-$RELEASE_DIR/export}"
EXPORT_OPTIONS_PLIST="${GHOSTSTREAM_EXPORT_OPTIONS_PLIST:-$RELEASE_DIR/ExportOptions.plist}"
EXPORTED_APP="$EXPORT_PATH/GhostStream.app"

ASC_KEY_PATH="${GHOSTSTREAM_ASC_KEY_PATH:-}"
ASC_KEY_ID="${GHOSTSTREAM_ASC_KEY_ID:-}"
ASC_ISSUER_ID="${GHOSTSTREAM_ASC_ISSUER_ID:-}"

declare -a provisioning_args
if [[ -n "$ASC_KEY_PATH$ASC_KEY_ID$ASC_ISSUER_ID" ]]; then
  if [[ -z "$ASC_KEY_PATH" || -z "$ASC_KEY_ID" || -z "$ASC_ISSUER_ID" ]]; then
    echo "GHOSTSTREAM_ASC_KEY_PATH, GHOSTSTREAM_ASC_KEY_ID and GHOSTSTREAM_ASC_ISSUER_ID must be set together." >&2
    exit 1
  fi
  provisioning_args=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
elif [[ "${GHOSTSTREAM_ALLOW_PROVISIONING:-0}" == "1" ]]; then
  provisioning_args=(-allowProvisioningUpdates)
fi

mkdir -p "$RELEASE_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$EXPORT_OPTIONS_PLIST"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr GhostStream \
            PacketTunnelExtension \
            ../ios/Packages/PhantomKit \
            ../ios/Frameworks/PhantomCore.xcframework 2>/dev/null || true
fi

xcodegen generate

xcodebuild -project GhostStream.xcodeproj \
           -scheme GhostStream \
           -configuration "$CONFIGURATION" \
           -destination "$DESTINATION" \
           -derivedDataPath "$DERIVED_DATA_PATH" \
           -archivePath "$ARCHIVE_PATH" \
           "${provisioning_args[@]}" \
           archive \
           DEVELOPMENT_TEAM="$TEAM_ID" \
           CODE_SIGN_STYLE="$CODE_SIGN_STYLE" \
           CODE_SIGNING_ALLOWED=YES \
           CODE_SIGNING_REQUIRED=YES \
           ONLY_ACTIVE_ARCH=NO

cat > "$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>destination</key>
  <string>export</string>
  <key>signingStyle</key>
  <string>${GHOSTSTREAM_EXPORT_SIGNING_STYLE:-automatic}</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
           -archivePath "$ARCHIVE_PATH" \
           -exportPath "$EXPORT_PATH" \
           -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" \
           "${provisioning_args[@]}"

if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "Exported app not found: $EXPORTED_APP" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP"

echo "$EXPORTED_APP"
