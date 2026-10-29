#!/usr/bin/env bash
#
# iOS → TestFlight (internal testing only, no App Review — ADR 0020: external
# TestFlight and App Store both rejected 4.3(a) with an account-removal warning):
#   1. Rebuild PhantomCore.xcframework (skip: GHOSTSTREAM_SKIP_XCFRAMEWORK=1)
#   2. xcodegen + archive, signed by the Xcode account (team UPG896A272)
#   3. Export + upload to App Store Connect (app "GhostStream Tunnel")
#
# Bump CURRENT_PROJECT_VERSION in apps/ios/project.yml first: App Store
# Connect rejects a build number it has already seen. A TestFlight build
# lives 90 days.
#
# Signing goes through the account signed in to Xcode, not the App Store
# Connect API key: with the key Xcode can't attach the App Group to a new
# App ID ("Authentication failed").
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$IOS_DIR/build/AppStore"

if [[ "${GHOSTSTREAM_SKIP_XCFRAMEWORK:-0}" != "1" ]]; then
  "$IOS_DIR/../../crates/client-apple/build-xcframework.sh"
fi

cd "$IOS_DIR"
rm -rf "$OUT/export" "$OUT/GhostStream.xcarchive"
mkdir -p "$OUT"
xcodegen -q
xcodebuild archive -project GhostStream.xcodeproj -scheme GhostStream -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/GhostStream.xcarchive" -allowProvisioningUpdates

cat > "$OUT/ExportOptions.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>teamID</key><string>UPG896A272</string>
<key>signingStyle</key><string>automatic</string>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><true/>
</dict></plist>
EOF

# Homebrew rsync 3.x in PATH breaks the IPA step ("--extended-attributes:
# unknown option"): Xcode runs /usr/bin/rsync, which spawns `rsync` from PATH.
env PATH=/usr/bin:/bin:/usr/sbin:/sbin /usr/bin/xcodebuild -exportArchive \
  -archivePath "$OUT/GhostStream.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates
