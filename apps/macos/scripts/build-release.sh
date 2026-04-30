#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${GHOSTSTREAM_DEVELOPMENT_TEAM:-UPG896A272}"
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
EXPORT_SIGNING_STYLE="${GHOSTSTREAM_EXPORT_SIGNING_STYLE:-manual}"
EXPORT_SIGNING_CERTIFICATE="${GHOSTSTREAM_EXPORT_SIGNING_CERTIFICATE:-Developer ID Application}"
APP_PROFILE_SPECIFIER="${GHOSTSTREAM_APP_PROVISIONING_PROFILE_SPECIFIER:-}"
TUNNEL_PROFILE_SPECIFIER="${GHOSTSTREAM_TUNNEL_PROVISIONING_PROFILE_SPECIFIER:-}"
CODE_SIGN_STYLE="${GHOSTSTREAM_CODE_SIGN_STYLE:-Automatic}"
if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "${GHOSTSTREAM_CODE_SIGN_STYLE:-}" ]]; then
  CODE_SIGN_STYLE=Manual
fi

export GHOSTSTREAM_EXPORT_SIGNING_CERTIFICATE="$EXPORT_SIGNING_CERTIFICATE"
export GHOSTSTREAM_APP_PROVISIONING_PROFILE_SPECIFIER="$APP_PROFILE_SPECIFIER"
export GHOSTSTREAM_TUNNEL_PROVISIONING_PROFILE_SPECIFIER="$TUNNEL_PROFILE_SPECIFIER"

declare -a archive_provisioning_args
if [[ -n "$ASC_KEY_PATH$ASC_KEY_ID$ASC_ISSUER_ID" ]]; then
  if [[ -z "$ASC_KEY_PATH" || -z "$ASC_KEY_ID" || -z "$ASC_ISSUER_ID" ]]; then
    echo "GHOSTSTREAM_ASC_KEY_PATH, GHOSTSTREAM_ASC_KEY_ID and GHOSTSTREAM_ASC_ISSUER_ID must be set together." >&2
    exit 1
  fi
  archive_provisioning_args=(
    -allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
elif [[ "${GHOSTSTREAM_ALLOW_PROVISIONING:-0}" == "1" ]]; then
  archive_provisioning_args=(-allowProvisioningUpdates)
fi

declare -a export_provisioning_args=()
if [[ "$EXPORT_SIGNING_STYLE" != "manual" ]]; then
  if [[ ${#archive_provisioning_args[@]} -gt 0 ]]; then
    export_provisioning_args=("${archive_provisioning_args[@]}")
  fi
elif [[ -z "$APP_PROFILE_SPECIFIER" || -z "$TUNNEL_PROFILE_SPECIFIER" ]]; then
  echo "Manual Developer ID export requires GHOSTSTREAM_APP_PROVISIONING_PROFILE_SPECIFIER and GHOSTSTREAM_TUNNEL_PROVISIONING_PROFILE_SPECIFIER." >&2
  exit 1
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

archive_command=(
  xcodebuild
  -project GhostStream.xcodeproj
  -scheme GhostStream
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  -archivePath "$ARCHIVE_PATH"
)
if [[ ${#archive_provisioning_args[@]} -gt 0 ]]; then
  archive_command+=("${archive_provisioning_args[@]}")
fi
archive_command+=(
  archive
  DEVELOPMENT_TEAM="$TEAM_ID"
  CODE_SIGN_STYLE="$CODE_SIGN_STYLE"
  CODE_SIGNING_ALLOWED=YES
  CODE_SIGNING_REQUIRED=YES
  ONLY_ACTIVE_ARCH=NO
)
if [[ "$CODE_SIGN_STYLE" == "Manual" ]]; then
  archive_command+=(CODE_SIGN_IDENTITY="$EXPORT_SIGNING_CERTIFICATE")
fi
"${archive_command[@]}"

cat > "$EXPORT_OPTIONS_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Add :method string developer-id" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :destination string export" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :signingStyle string $EXPORT_SIGNING_STYLE" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :stripSwiftSymbols bool true" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :manageAppVersionAndBuildNumber bool false" "$EXPORT_OPTIONS_PLIST"

if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
  /usr/libexec/PlistBuddy -c "Add :signingCertificate string $EXPORT_SIGNING_CERTIFICATE" "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:com.ghoststream.vpn string $APP_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:com.ghoststream.vpn.tunnel string $TUNNEL_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
fi

export_command=(
  xcodebuild
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)
if [[ ${#export_provisioning_args[@]} -gt 0 ]]; then
  export_command+=("${export_provisioning_args[@]}")
fi
"${export_command[@]}"

if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "Exported app not found: $EXPORTED_APP" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$EXPORTED_APP"

echo "$EXPORTED_APP"
