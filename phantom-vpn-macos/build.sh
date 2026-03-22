#!/bin/bash
# Build PhantomVPN.app for macOS
set -e

cd "$(dirname "$0")"

echo "→ Building Swift package..."
swift build -c release 2>&1

APP="PhantomVPN.app"
BINARY=".build/release/PhantomVPN"

if [ ! -f "$BINARY" ]; then
    echo "✗ Build failed: binary not found at $BINARY"
    exit 1
fi

echo "→ Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/PhantomVPN"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.ghoststream.phantom-vpn</string>
    <key>CFBundleName</key>
    <string>PhantomVPN</string>
    <key>CFBundleDisplayName</key>
    <string>PhantomVPN</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>PhantomVPN</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>PhantomVPN needs administrator privileges to create VPN tunnels.</string>
</dict>
</plist>
EOF

echo "✓ Built: $APP"
echo ""
echo "→ To install phantom-client-macos binary:"
echo "   sudo install -m 0755 /path/to/phantom-client-macos /usr/local/bin/"
echo ""
echo "→ To run:"
echo "   open $APP"
