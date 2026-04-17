# GhostStream iOS

SwiftUI + NEPacketTunnelProvider client. Requires Xcode 15+ and iOS 17+ target device.

## Architecture

```
apps/ios/
├── GhostStream/           # Host app (SwiftUI)
│   ├── App/               # AppNavigation, GhostStreamApp
│   ├── UI/                # Dashboard, Logs, Settings, Admin screens
│   ├── Service/           # VpnStateManager, VpnTunnelController
│   └── Data/              # VpnProfile, ProfilesStore, PreferencesStore
├── PacketTunnelProvider/  # NE extension — runs in separate process
└── Packages/PhantomKit/   # Shared Swift package (both targets import this)
    └── Sources/PhantomKit/
        ├── FFI/           # PhantomBridge (actor) + C function declarations
        ├── Models/        # StatusFrame, ConnState, LogFrame, VpnProfile…
        ├── Storage/       # ProfilesStore, PreferencesStore, Keychain
        └── Bridge/        # TunnelIpcBridge (sendProviderMessage wrapper)
```

## Building

```bash
# Build Rust xcframework first
bash crates/client-apple/build-xcframework.sh

# Generate Xcode project
cd apps/ios && xcodegen generate

# Build + install (requires device UDID)
xcodebuild -project GhostStream.xcodeproj -scheme GhostStream \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## Adding a new screen

1. Create `apps/ios/GhostStream/UI/MyFeature/MyFeatureView.swift`
2. Create `apps/ios/GhostStream/UI/MyFeature/MyFeatureViewModel.swift`
3. Add a `NavigationLink` in `AppNavigation.swift`
4. Add localization keys to `Resources/ru.lproj/Localizable.strings` and `en.lproj/`

## Font probing

Typography.swift probes `UIFont.fontNames(forFamilyName:)` at startup to resolve the
correct PostScript names. If you add a new custom font: add the family name to the probe
list and hard-code the verified PostScript name. Never guess PostScript names from file
names.

## Known limitations

### Ed25519 admin certs

iOS Security framework rejects Ed25519 private keys for TLS client authentication.
If the Admin panel shows a certificate error, regenerate the connection string using ECDSA:
```bash
phantom-keygen new-client --name <n> --key-type ecdsa
```
Ed25519 keys are only usable for non-mTLS connections.

### Per-app routing

Apple requires a special MDM entitlement (`com.apple.developer.networking.networkextension` 
with `per-app-vpn`) that is not available without enterprise enrollment. Per-app routing
is therefore not supported on iOS.

## App Group

All shared state flows through App Group `group.com.ghoststream.vpn`:
- `files/profiles.json` — profile list (ProfilesStore)
- `UserDefaults(suiteName:)` — preferences (PreferencesStore)
- `snapshot.json` — last known StatusFrame (written by extension, read by host)
- Keychain — PEM keys (kSecAttrAccessibleAfterFirstUnlock + shared access group)
