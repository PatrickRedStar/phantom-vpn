# GhostStream macOS

Нативное SwiftUI приложение для macOS 15+ с `NEPacketTunnelProvider` system extension. Distribution — Direct (DMG + Developer ID notarize + Sparkle 2 auto-update). Primary surface — menu bar (`MenuBarExtra` + popover), secondary — main console window с `NavigationSplitView`.

## Требования

- **Xcode 26+** (нужен для macOS 15 SDK + новых SwiftUI API: `@Observable`, `MenuBarExtra` styles, `NavigationSplitView` column width)
- **macOS 15 Sequoia** или новее (build host и target)
- **rustup** с targets `aarch64-apple-darwin` + `x86_64-apple-darwin`:
  ```bash
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  ```
- **`xcodegen`** — генерация `.xcodeproj` из `project.yml`:
  ```bash
  brew install xcodegen
  ```
- **`cbindgen`** — для генерации `PhantomCore.h` (вызывается из `build-xcframework.sh`):
  ```bash
  cargo install cbindgen
  ```
- **`create-dmg`** (для release / packaging):
  ```bash
  brew install create-dmg
  ```
- **Apple Developer ID account** — для подписи system extension (free account недостаточен, нужен paid Developer Program). Локально для debug можно использовать developer mode (`systemextensionsctl developer on`).

## Сборка debug

```bash
# 1. Rust xcframework с macOS slice (один раз / после правок client-apple или client-core-runtime)
cd crates/client-apple && ./build-xcframework.sh

# 2. Generate Xcode project + Build
cd apps/macos
./scripts/build-debug.sh
# = xcodegen generate
# + signed xcodebuild -scheme GhostStream -configuration Debug build
```

`build-debug.sh` подписывает host app и system extension через Team ID `UPG896A272`.
Если локальных provisioning profiles ещё нет, первый signed build упадёт с `No profiles ... were found`.
В этом случае можно разрешить Xcode создать profiles:

```bash
GHOSTSTREAM_ALLOW_PROVISIONING=1 ./scripts/build-debug.sh
```

Скрипт собирает debug build под текущий Mac и при provisioning-разрешении
позволяет Xcode зарегистрировать этот Mac в Developer Portal.

Для compile-only проверки без рабочей активации system extension:

```bash
GHOSTSTREAM_UNSIGNED=1 ./scripts/build-debug.sh
```

Для запуска с system extension debug build нужно установить в `/Applications`;
из `DerivedData` macOS откажет в активации system extension:

```bash
GHOSTSTREAM_ALLOW_PROVISIONING=1 ./scripts/install-debug.sh
```

## Сборка release DMG

Release build собирается как Developer ID signed app, проходит notarization и
упаковывается в `.dmg` для установки через drag-and-drop в `/Applications`.

Локальная сборка:

```bash
cd crates/client-apple && ./build-xcframework.sh

cd ../../apps/macos
GHOSTSTREAM_ALLOW_PROVISIONING=1 ./scripts/build-release.sh
./scripts/notarize.sh build/Release/export/GhostStream.app
GHOSTSTREAM_SIGN_DMG=1 ./scripts/package-dmg.sh build/Release/export/GhostStream.app
./scripts/notarize.sh build/Release/dist/GhostStream-*-macOS.dmg
```

GitHub Actions делает то же самое в `.github/workflows/release.yml` и
прикладывает `GhostStream-*-macOS.dmg` к release по тегу `v*`.

Обязательные GitHub Secrets:

- `MACOS_CERTIFICATE_P12_BASE64` — Developer ID Application certificate в `.p12`, закодированный base64.
- `MACOS_CERTIFICATE_PASSWORD` — пароль от `.p12`.
- `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64` — публичный Developer ID Application `.cer`, который соответствует private key из `.p12`.
- `APPLE_TEAM_ID` — Team ID, по умолчанию используется `UPG896A272`.
- `APP_STORE_CONNECT_API_KEY_BASE64`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` — API key для automatic provisioning и notarization.
- `MACOS_APP_PROVISIONING_PROFILE_BASE64` — Developer ID profile для `com.ghoststream.vpn`.
- `MACOS_TUNNEL_PROVISIONING_PROFILE_BASE64` — Developer ID profile для `com.ghoststream.vpn.tunnel`.

Если App Store Connect API key не используется, notarization можно выполнить
через Apple ID:

- `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` — fallback auth для notarization.

Base64 для GitHub Secret на macOS:

```bash
base64 -i DeveloperID.p12 | pbcopy
base64 -i "Developer ID Application: Petr Kurkin (UPG896A272).cer" | pbcopy
base64 -i GhostStream.provisionprofile | pbcopy
```

Альтернативно — открыть в Xcode:

```bash
cd apps/macos
xcodegen generate
open GhostStream.xcodeproj
# Cmd+B в Xcode для compile/debug diagnostics.
# Для activation system extension запускать установленный app из /Applications.
```

## Запуск

```bash
open /Applications/GhostStream.app
```

**На первый запуск:**

1. App запросит активацию system extension → появится system prompt **GhostStream wants to add a system extension**.
2. Идти в **System Settings → General → Login Items & Extensions → Extensions → Network Extensions** и разрешить GhostStream. Если кнопка в разделе не видна, проверь **Privacy & Security**: на некоторых версиях macOS approval показывается там.
3. Дальше app покажет prompt в **System Settings → VPN & Filters** для добавления VPN configuration → Allow.
4. После активации — `WelcomeWindow` с большим полем для вставки `ghs://` строки.
5. После import профиля — menu bar показывает GhostStream icon в `STANDBY`.

**Проверка system extension:**

```bash
systemextensionsctl list
# должен показать com.ghoststream.vpn.tunnel: activated enabled
```

**Recovery / clean reinstall:**

```bash
sudo systemextensionsctl reset       # сносит все system extensions
# или адресно:
sudo systemextensionsctl uninstall <TEAM_ID> com.ghoststream.vpn.tunnel
```

## Шрифты

TTF/OTF шрифты живут в **shared `PhantomUI` package**, не локально в macOS app:

```
apps/ios/Packages/PhantomKit/Sources/PhantomUI/Resources/Fonts/
  SpaceGrotesk-Bold.ttf
  DepartureMono-Regular.otf
  JetBrainsMono-Regular.ttf
  InstrumentSerif-Regular.ttf
```

`Package.swift` объявляет их через `.process("Resources/Fonts")`. Bundle автоматически линкуется в обоих targets (host app + system extension), регистрация шрифтов — на старте app через `PhantomUI.registerFonts()`.

## Структура

```
apps/macos/
├── project.yml                # xcodegen spec
├── README.md                  # этот файл
├── GhostStream/               # Host app target (.app)
│   ├── App/                   # GhostStreamApp, AppDelegate, AppRouter
│   ├── UI/                    # MenuBar, Window, Sidebar, Dashboard, Logs,
│   │                          # Settings, Servers, Admin, Onboarding, Components
│   ├── Service/               # VpnTunnelController, SystemExtensionInstaller,
│   │                          # LoginItemController, SparkleUpdater, DockPolicyController
│   ├── Resources/             # Assets.xcassets (AppIcon + MenuBarIcon), Localizable.xcstrings
│   ├── Info.plist             # LSMinimumSystemVersion 15.0
│   └── GhostStream.entitlements
├── PacketTunnelExtension/     # System extension target (.systemextension)
│   ├── PacketTunnelProvider.swift
│   ├── Info.plist             # NetworkExtension/NEProviderClasses + NEMachServiceName
│   └── PacketTunnelExtension.entitlements
└── scripts/
    ├── build-debug.sh
    ├── build-release.sh
    ├── notarize.sh
    ├── package-dmg.sh
    └── generate-eddsa-keys.sh   # one-time Sparkle EdDSA key generation
```

Полная архитектура, диаграммы, поверхности UI, hotkeys, system extension activation flow, distribution pipeline, pitfalls — в [docs/knowledge/platforms/macos.md](../../docs/knowledge/platforms/macos.md).
