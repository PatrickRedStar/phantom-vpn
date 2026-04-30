---
created: 2026-04-27
updated: 2026-04-27
status: in-progress
tags: [platform, macos, swiftui, network-extension]
---

# macOS

## Стек

- **SwiftUI** host app (`apps/macos/GhostStream/`) — `MenuBarExtra` + `WindowGroup` + `Settings`-сцены, **macOS 15 Sequoia** minimum (используются последние API: `@Observable`, `NavigationSplitView` с `.navigationSplitViewColumnWidth`, `MenuBarExtra` styles).
- **`NEPacketTunnelProvider` system extension** (`apps/macos/PacketTunnel/`) — отдельный `.systemextension` bundle, активируется через `OSSystemExtensionRequest`.
- **`PhantomKit` + `PhantomUI`** — Swift package в `apps/ios/Packages/PhantomKit/` (shared с iOS):
  - `PhantomKit` target — Models / Bridge / Storage / FFI (cross-platform).
  - `PhantomUI` target — Theme / Components / Fonts (cross-platform pure SwiftUI).
- **Rust core:** `crates/client-apple/` → `PhantomCore.xcframework` с macOS slice (universal arm64+x86_64) поверх iOS slice'ов.
- **Unified tunnel runtime:** `crates/client-core-runtime/` с `TunIo::Callback(Arc<dyn PacketIo>)` (тот же variant что iOS — packet flow через `NEPacketTunnelProvider`).
- **Sparkle 2** — auto-update с EdDSA signature verification, appcast XML.
- **`i18n`:** `Localizable.xcstrings` — RU baseline + EN.

Зрелость: **in-progress** (v0.23.0, 2026-04-27 — старт работ). Distribution через **Direct (DMG + Developer ID notarize)**, не через Mac App Store (sandboxed App Store distribution не даёт NetworkExtension entitlement без enterprise enrollment).

## Структура `apps/macos/`

```
project.yml                      # xcodegen spec (как apps/ios/project.yml)
GhostStream.xcodeproj/           # generated

GhostStream/                     # Host app target (.app)
  App/
    GhostStreamApp.swift         # @main, MenuBarExtra + WindowGroup + Settings scene
    AppDelegate.swift            # dock policy, login item registration, system ext bootstrap
    AppRouter.swift              # window management coordinator + global hotkeys
  UI/
    MenuBar/
      MenuBarPopover.swift       # primary surface (380×520)
      MenuBarStatusItem.swift    # template icon + state badge tint
    Window/
      MainConsoleWindow.swift    # NavigationSplitView host (1200×800)
      CommandPalette.swift       # ⌘⇧C fuzzy search panel
      LogsDetachedWindow.swift   # ⌘⇧L отдельное окно с TailView
      AboutWindow.swift          # custom About + Sparkle check
    Sidebar/
      SidebarList.swift          # ALL CAPS Departure Mono items
      SidebarProfileBlock.swift  # pinned profile picker внизу sidebar
    Dashboard/  Logs/  Settings/  Servers/  Admin/  Onboarding/
    Components/                  # macOS-only (FrostedToolbar, KeyboardShortcutHint)
  Service/
    VpnTunnelController.swift    # NETunnelProviderManager wrapper
    SystemExtensionInstaller.swift  # OSSystemExtensionRequest activation flow
    LoginItemController.swift    # SMAppService.mainApp.register()
    SparkleUpdater.swift         # SPUUpdater + EdDSA pubkey
    DockPolicyController.swift   # toggle LSUIElement runtime
  Resources/
    Assets.xcassets/             # AppIcon + MenuBarIcon (template)
    Localizable.xcstrings        # RU + EN
  Info.plist                     # LSMinimumSystemVersion 15.0, LSUIElement
  GhostStream.entitlements       # NEAppGroup, NetworkExtension, app-groups

PacketTunnel/                    # System extension target (.systemextension)
  PacketTunnelProvider.swift     # entry point (port iOS)
  Info.plist                     # NSExtensionPointIdentifier=com.apple.networkextension.packet-tunnel
  PacketTunnel.entitlements      # NEAppGroup, NetworkExtension, sandbox

scripts/
  build-debug.sh                 # xcodegen + xcodebuild Debug
  build-release.sh               # archive + export Developer ID app
  notarize.sh                    # notarytool submit + staple
  package-dmg.sh                 # create-dmg + EdDSA sign appcast entry
  generate-eddsa-keys.sh         # one-time Sparkle key generation
```

## Targets и bundle IDs

| Target | Bundle ID | Type | Entitlements |
|---|---|---|---|
| `GhostStream.app` | `com.ghoststream.vpn` | Host app | NEAppGroup, NetworkExtension, app-groups, hardened runtime |
| `PacketTunnel.systemextension` | `com.ghoststream.vpn.tunnel` | System extension | NEAppGroup, NetworkExtension, sandbox, hardened runtime |

**App Group** (общий для host + extension): `group.com.ghoststream.vpn` — тот же что iOS, единый код в PhantomKit Storage.

**Code signing**: Developer ID Application (один cert для обоих targets — system extension должна быть подписана тем же team как и host app, иначе `OSSystemExtensionErrorDomain` Code 4 при активации).

## Architecture diagram

```
┌─────────────────────── User Process (host app) ─────────────────────────┐
│                                                                          │
│  GhostStreamApp (SwiftUI)                                                │
│   ├── MenuBarExtra ────► MenuBarPopover (primary surface)                │
│   ├── WindowGroup    ────► MainConsoleWindow (NavigationSplitView)       │
│   │                         ├── STREAM (Dashboard)                       │
│   │                         ├── TAIL (Logs)                              │
│   │                         ├── SETUP (Settings)                         │
│   │                         ├── ROSTER (ServerRoster)                    │
│   │                         └── ADMIN (only if cert.is_admin)            │
│   └── Settings scene ────► SettingsView (login item / dock / theme)     │
│                                                                          │
│  Service layer:                                                          │
│   ├── VpnTunnelController ── (NETunnelProviderManager)                  │
│   ├── SystemExtensionInstaller ── (OSSystemExtensionRequest)            │
│   ├── LoginItemController ── (SMAppService.mainApp)                     │
│   └── SparkleUpdater ── (SPUStandardUpdaterController)                  │
│                                                                          │
│  PhantomKit (shared с iOS):                                             │
│   ├── Bridge/TunnelIpcBridge ── sendProviderMessage wrapper             │
│   ├── Storage/{Keychain,Profiles,Preferences} ── App Group              │
│   ├── Models ── StatusFrame, ConnState, LogFrame, VpnProfile             │
│   └── FFI/PhantomBridge ── PhantomCore.xcframework (macOS slice)        │
│                                                                          │
└────────────────────────────────────┬─────────────────────────────────────┘
                                     │
              IPC: sendProviderMessage / Darwin notifications
              Shared storage: App Group UserDefaults + Keychain
                                     │
┌────────────────────────────────────▼─────────────────────────────────────┐
│           System Extension Process (PacketTunnel.systemextension)         │
│                                                                          │
│  NEPacketTunnelProvider                                                  │
│   ├── PhantomBridge (FFI) ── PhantomCore.xcframework                    │
│   └── client-core-runtime (Rust)                                        │
│        ├── TunIo::Callback(Arc<dyn PacketIo>)                           │
│        ├── handshake (mTLS + H2)                                        │
│        ├── supervise FSM (8 attempts, [3,6,12,24,48,60,60,60]s)        │
│        └── telemetry (250ms, EMA α=0.35) → StatusFrame                  │
│                                                                          │
│  packetFlow.readPackets ──► Rust runtime ──► TLS H2 ──► NL exit         │
│  packetFlow.writePackets ◄── Rust runtime ◄── TLS H2 ◄── NL exit         │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

## 7 поверхностей UI

| # | Surface | Назначение |
|---|---|---|
| 1 | **MenuBarStatusItem** | Template icon в menu bar (mono scope ring), state-badge tint (`signal` для connected, `warn` для tuning, `danger` для error). Click → toggle popover. |
| 2 | **MenuBarPopover** (380×520) | Primary surface. State headline (`STANDBY` / `TUNING.` / `TRANSMITTING.`), big GhostFab connect/disconnect button, active profile picker, mini ScopeChart (last 60s). |
| 3 | **MainConsoleWindow** (1200×800, min 960×640) | Secondary surface — `NavigationSplitView`. Sidebar с табами **STREAM / TAIL / SETUP / ROSTER** (+**ADMIN** если активный cert имеет `is_admin`). Detail pane = full-width scope chart, mux bars, RX/TX/RTT stats / log stream / settings panel / server roster table. |
| 4 | **WelcomeWindow** (720×520) | First-launch onboarding после system extension activation. Большое поле `PasteGhsField` (multiline JetBrainsMono TextEditor) для вставки `ghs://` строки. Clipboard auto-detect banner. Collapsible manual form (server addr + cert + key + name) для advanced. |
| 5 | **CommandPalette** (600×420 floating NSPanel) | ⌘⇧C fuzzy search через профили + actions (Connect/Disconnect/Reconnect/Switch profile/Theme toggle/Quit/About). Sublime-text-style FuzzyMatcher. Esc dismiss. |
| 6 | **LogsDetachedWindow** (800×600) | ⌘⇧L — standalone Logs window (TailView). Keep-alive отдельно от main; продолжает работать когда main hidden. Колонки `LEVEL | TS | MSG`, копирование строк. |
| 7 | **AboutWindow** (480×360) | Custom About (НЕ NSAboutWindow). Phosphor wordmark, version + build + commit hash, "Check for updates" button (Sparkle), license / credits. |

## Hotkeys

| Shortcut | Action |
|---|---|
| `⌘K` | Connect/Disconnect toggle |
| `⌘⇧C` | Открыть Command Palette |
| `⌘0` | Show MainConsoleWindow |
| `⌘1` | Sidebar → STREAM (Dashboard) |
| `⌘2` | Sidebar → TAIL (Logs) |
| `⌘3` | Sidebar → SETUP (Settings) |
| `⌘4` | Sidebar → ROSTER (Servers) |
| `⌘5` | Sidebar → ADMIN (если admin cert) |
| `⌘⇧L` | Открыть Logs detached window |
| `⌘,` | Settings (jump к SETUP в main window) |
| `⌘N` | New profile (paste ghs://) |
| `⌘W` | Hide window (app остаётся в menu bar) |
| `⌘Q` | Quit (с confirmation если connected) |

## System extension activation flow

В отличие от iOS (где `NEPacketTunnelProvider` упакован как `.appex` app extension), на macOS это **system extension** (`.systemextension` bundle, грузится в kernel через `sysextd`). Lifecycle:

```
NotInstalled
    ↓ (host app first launch → OSSystemExtensionRequest.activationRequest)
RequestPending
    ↓ (system показывает prompt: "GhostStream wants to add a system extension")
AwaitingUserApproval ── (user → System Settings → Privacy & Security → Allow)
    ↓
Activated ── (systemextensionsctl list → com.ghoststream.vpn.tunnel: activated enabled)
    ↓
ManagerConfigured ── (NETunnelProviderManager.saveToPreferences())
    ↓
Ready ── (System Settings → VPN & Filters показывает GhostStream)
    ↓
   user click Connect → manager.connection.startVPNTunnel()
    ↓
   extension загружается system'ом → tunnel up
```

`SystemExtensionInstaller.swift` управляет flow с UI feedback в `WelcomeWindow`. **Manual user steps:**

1. На первый запуск пользователь видит system prompt → нужно открыть **System Settings → Privacy & Security** → нажать **Allow**.
2. После approve в **System Settings → VPN & Filters** появляется запись GhostStream — также может потребовать allow VPN configuration (подписать первый раз).
3. Subsequent launches: extension уже активна, host app просто включает manager.

**Recovery**: `sudo systemextensionsctl reset` снимает все system extensions — app переходит в `LOST SIGNAL.` state, UI banner предлагает re-activate с тем же flow.

## mTLS storage и App Group

Keychain через `PhantomKit/Storage/Keychain.swift` с access group **`group.com.ghoststream.vpn`** (тот же что iOS).

На macOS App Groups требуют `com.apple.security.application-groups` entitlement в обоих targets (host app + system extension), плюс **`kSecUseDataProtectionKeychain = true`** для shared items (на iOS это default, на macOS — нет, нужно явно).

Стораж содержит:
- `client.crt` (PEM) — клиентский сертификат
- `client.key` (PEM PKCS1/PKCS8) — приватный ключ клиента
- CA fingerprint (для server cert pinning)
- `cachedAdminServerCertFp` — TOFU pin для admin endpoint (single profile)

`ProfilesStore` (App Group `files/profiles.json`) и `PreferencesStore` (App Group `UserDefaults`) — те же что iOS, читаются обоими процессами.

## Build / sign / notarize / DMG / Sparkle

**Build pipeline (high-level)**:

```bash
# 1. Rust xcframework с macOS slice (один раз, после правок client-apple/runtime)
cd crates/client-apple && ./build-xcframework.sh
# собирает aarch64-apple-darwin + x86_64-apple-darwin → lipo → macOS slice
# рядом с iOS slice'ами в PhantomCore.xcframework

# 2. Generate Xcode project
cd apps/macos && xcodegen generate

# 3. Debug build (local iteration)
./scripts/build-debug.sh
# = xcodebuild -scheme GhostStream -configuration Debug build

# 4. Release build (signed)
./scripts/build-release.sh
# = xcodebuild archive + export Developer ID app

# 5. Notarize
./scripts/notarize.sh
# = xcrun notarytool submit GhostStream.app.zip --apple-id ... --team-id ... --wait
# + xcrun stapler staple GhostStream.app

# 6. Package DMG + Sparkle sign
./scripts/package-dmg.sh
# = create-dmg ... GhostStream.dmg
# + sign_update GhostStream.dmg ed_priv_key.pem → signature
# + update appcast.xml (enclosure + signature + version + minimumSystemVersion)
```

**Sparkle 2 EdDSA**:
- Generate EdDSA key pair один раз (`./scripts/generate-eddsa-keys.sh` → private в Keychain локально / 1Password, public в Info.plist `SUPublicEDKey`).
- На каждый release — `sign_update` подписывает DMG → получает signature → попадает в appcast XML.
- Appcast хостится на vdsina (`https://ghs.example.com/appcast.xml`) или GitHub Releases.
- App периодически (раз в 24h) проверяет appcast → показывает update prompt с release notes (Markdown rendered) → скачивает + EdDSA verifies + installs.

**CI**: `.github/workflows/macos-release.yml` — m1 runner с self-hosted secrets (Developer ID cert, EdDSA private key, notarization App-Specific Password). Trigger: tag `v*`. Output: GitHub Release с notarized DMG + appcast.xml asset.

## PhantomKit / PhantomUI shared с iOS

`apps/ios/Packages/PhantomKit/Package.swift` объявляет:

```swift
platforms: [.iOS(.v17), .macOS(.v15)]
```

Два target'а в одном package'е:

- **`PhantomKit`** — Bridge / Models / Storage / FFI. Cross-platform по природе. iOS-only API (UIKit-зависимости) под `#if os(iOS)`. macOS host app + system extension импортируют тот же `import PhantomKit`.
- **`PhantomUI`** — Theme / Components / Fonts (TTF/OTF). Pure SwiftUI, cross-platform. Перенесено из `apps/ios/GhostStream/Theme/` и `apps/ios/GhostStream/UI/Components/` (no-op refactor для iOS, новое подключение для macOS). Resources объявлены как `.process("Resources/Fonts")`.

Components, переиспользуемые на macOS as-is: `GhostCard`, `ScopeChart` (Canvas-based), `MuxBars`, `GhostFab`, `Hairline`, `PulseDot`, `SerifAccent`, `HeaderMeta`, `ScreenHeader`. macOS-only компоненты (`FrostedToolbar`, `KeyboardShortcutHint`) живут локально в `apps/macos/GhostStream/UI/Components/`. iOS-only `BottomNav` остаётся в iOS app — на Mac заменяется на `SidebarList`.

## Differences from iOS

| Аспект | iOS | macOS |
|---|---|---|
| Primary navigation | Bottom nav (5 tabs) в hosted SwiftUI app | Menu bar primary + sidebar secondary (`NavigationSplitView`) |
| Window count | 1 (root view) | Multiple: MenuBar popover + Console + LogsDetached + Welcome + About + CommandPalette |
| Network extension | `.appex` app extension (packaged внутри `.app`) | `.systemextension` (отдельный bundle, активируется через `OSSystemExtensionRequest`) |
| Activation flow | Auto при первом `manager.saveToPreferences()` + user allow VPN | Two-stage: system extension activation (`OSSystemExtensionRequest` → user allow в Privacy & Security) + manager save (user allow в VPN & Filters) |
| Distribution | App Store (TestFlight + Release) | Direct (Developer ID + DMG + notarize + Sparkle 2 auto-update) |
| Login item | OS-managed background app refresh | `SMAppService.mainApp.register()` — explicit user toggle в Settings |
| Dock policy | N/A | Toggle LSUIElement runtime: visible (Dock + menu bar) ↔ accessory (menu bar only) |
| Per-app routing | **Не поддерживается** (требует MDM enterprise entitlement) | Не поддерживается (та же причина) |
| Command palette | Нет | ⌘⇧C — fuzzy search через профили + actions |
| Server roster | Settings list | Dedicated **ROSTER** sidebar tab с SwiftUI `Table` (NAME / ENDPOINT / RTT / LAST USED / ★, sortable, right-click menu) |
| Logs window | Внутри tab | Может быть detached (`⌘⇧L`) — keep-alive отдельно от main |
| Theme switch | System-following | System-following + manual toggle в SETUP |
| Auto-update | App Store | Sparkle 2 (EdDSA + appcast) |
| `TunIo` variant | `Callback(Arc<dyn PacketIo>)` | `Callback(Arc<dyn PacketIo>)` (тот же, packet flow callback-based на обеих платформах) |

## Архитектурные особенности

- **`TunIo::Callback`** — macOS не даёт raw fd TUN'а (как и iOS). Используется `NEPacketTunnelFlow.readPackets/writePackets`. Rust вызывает Swift callback'и через FFI, Swift кладёт пакеты в packetFlow и обратно. Идентично iOS.
- **App Group shared storage** — host app и system extension разделены sandbox'ом. Общие storages: Keychain + `UserDefaults` в App Group container. `ProfilesStore` и `PreferencesStore` читают оттуда оба процесса.
- **Host ↔ extension IPC** — `sendProviderMessage` (Request/Response, `gui-ipc` JSON) для heavy data (logs); App Group `UserDefaults` + Darwin notifications (`CFNotificationCenterGetDarwinNotifyCenter`) для lightweight state push (StatusFrame).
- **System extension lifecycle** — отдельный процесс под `sysextd`, может быть остановлен `sudo systemextensionsctl reset`. Host app должен детектить такие сценарии (`OSSystemExtensionStateDidChange`) и отрабатывать UI banner для re-activate.
- **IPv6 killswitch** — то же что iOS (Phase 6 v0.22.0): IPv6 routes `::/0` в туннель, чтобы не утекал plain IPv6 при IPv4-only конфиге.
- **Login item** — `SMAppService.mainApp.register()` на macOS 13+ (не legacy LaunchAgents). User toggle в SETUP, persistent через user-level preferences.
- **Dock policy runtime override** — `NSApplication.setActivationPolicy(.accessory)` для menu-bar-only mode без перезапуска (не просто LSUIElement в Info.plist, который требует cold restart).

## Критичные pitfalls

- **System extension code signing** — host app и system extension должны быть подписаны **одним и тем же Developer ID Team**, иначе `OSSystemExtensionErrorDomain` Code 4 (codeSignatureInvalid) при активации.
- **Notarization обязательна для distribution** — без notarize Gatekeeper заблокирует первый запуск (`damaged and can't be opened`). Notarize даже для personal testing если приложение раздаётся вне локальной машины.
- **`kSecUseDataProtectionKeychain = true`** на macOS обязательно для App-Group-shared Keychain items, иначе extension не увидит ключи (silent failure).
- **App Group identifier** должен совпадать в entitlements host app и system extension (`group.com.ghoststream.vpn`) — иначе shared storage не работает (молчаливо, как на iOS).
- **System extension не перезагружается при rebuild** — после изменения extension'а нужно `systemextensionsctl uninstall <team> com.ghoststream.vpn.tunnel` + reinstall. В debug builds можно использовать developer mode (`systemextensionsctl developer on`) — игнорирует подписи.
- **Sparkle EdDSA private key — НЕ коммитить** — хранить в Keychain локально / 1Password / GitHub secrets. Compromise key → fork-update attack возможен.
- **xcframework пересобирать после правок client-apple/runtime** — Xcode не детектит изменения в Rust автоматически, нужен `build-xcframework.sh`.
- **`OSSystemExtensionRequest` requires entitlement `com.apple.developer.system-extension.install`** — не работает в Sandboxed app или без правильного provisioning profile.
- **MenuBarExtra на macOS 13** не имеет всех styles доступных на 15 — мы таргетим только 15+, но не забыть это при поднятии min version вниз.
- **`@Observable` macro require macOS 14+** — используется свободно (мы на 15+), но при portировании iOS-кода с `ObservableObject` стоит проверить совместимость.

## References / Sources

- **Host app:** [apps/macos/GhostStream/](../../../apps/macos/GhostStream/)
- **System extension:** [apps/macos/PacketTunnel/](../../../apps/macos/PacketTunnel/)
- **xcodegen spec:** [apps/macos/project.yml](../../../apps/macos/project.yml)
- **README:** [apps/macos/README.md](../../../apps/macos/README.md)
- **PhantomKit + PhantomUI package (shared с iOS):** [apps/ios/Packages/PhantomKit/](../../../apps/ios/Packages/PhantomKit/)
- **Rust FFI:** [crates/client-apple/](../../../crates/client-apple/), [PhantomCore.h](../../../crates/client-apple/include/PhantomCore.h)
- **Runtime (shared):** [crates/client-core-runtime/](../../../crates/client-core-runtime/)
- **Canonical wire types:** [crates/gui-ipc/](../../../crates/gui-ipc/)
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md)
- **iOS reference (sibling platform):** [ios.md](ios.md)
- **gitnexus:** `gitnexus_query({query: "macos system extension"})`, `gitnexus_query({query: "menu bar popover"})`
- **Handshake:** [../architecture/handshake.md](../architecture/handshake.md)
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
