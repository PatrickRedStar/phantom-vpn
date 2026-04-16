# GhostStream iOS

iOS-клиент GhostStream / PhantomVPN. SwiftUI + NetworkExtension
(`NEPacketTunnelProvider`) + общее Rust-ядро (`crates/client-apple`, собирается
в `PhantomCore.xcframework`).

## Структура

```
apps/ios/
├── project.yml                  # XcodeGen spec — два таргета: App + Extension
├── GhostStream/                 # SwiftUI приложение
│   ├── App/                     # @main, root view
│   ├── Theme/                   # Colors, Typography, Fonts/ (уже внутри)
│   ├── Data/                    # ProfilesStore, PreferencesStore, модели
│   ├── Service/                 # VpnStateManager, NEVPNManager wrapper
│   ├── Network/                 # AdminHttpClient (mTLS, TOFU)
│   ├── Rust/                    # PhantomBridge.swift — Swift-обёртка FFI
│   ├── UI/                      # Dashboard, Logs, Settings, Admin, Components
│   ├── Assets.xcassets/         # AccentColor (#C4FF3E), AppIcon
│   ├── Info.plist
│   └── GhostStream.entitlements
├── PacketTunnelProvider/        # App Extension (NEPacketTunnelProvider)
│   ├── PacketTunnelProvider.swift
│   ├── SharedState.swift
│   ├── PhantomBridge.swift      # дубликат FFI-обёртки для extension
│   ├── Info.plist
│   └── PacketTunnelProvider.entitlements
└── Frameworks/                  # PhantomCore.xcframework (собирается скриптом)
```

## Предварительные требования

1. **macOS + Xcode 15+** (полный Xcode, не только Command Line Tools).
   ```bash
   # проверить:
   xcodebuild -version
   # если выдаёт "requires Xcode" — установить Xcode из App Store,
   # потом: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```

2. **Rust + iOS targets**:
   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   source "$HOME/.cargo/env"
   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
   ```

3. **XcodeGen + cbindgen**:
   ```bash
   brew install xcodegen
   cargo install cbindgen
   ```

4. **Apple Developer Account** — нужен только для запуска на реальном iPhone.
   Для симулятора достаточно бесплатного Apple ID в Xcode.

## Сборка

```bash
# 1. Собрать Rust xcframework (device + simulator архитектуры)
cd crates/client-apple
./build-xcframework.sh
# → apps/ios/Frameworks/PhantomCore.xcframework

# 2. Сгенерировать Xcode-проект
cd ../../apps/ios
xcodegen generate

# 3. Открыть в Xcode
open GhostStream.xcodeproj
```

В Xcode:
1. Target **GhostStream** → Signing & Capabilities → выбрать Team (Apple ID подойдёт).
2. Target **PacketTunnelProvider** → то же самое (Team должен совпадать).
3. Bundle ID при необходимости поменять на уникальный (`com.твоёимя.vpn`)
   — тогда App Group тоже надо переименовать в entitlements обоих таргетов.

## Симулятор vs реальный iPhone

| Что работает | Симулятор | iPhone |
|---|---|---|
| UI (Dashboard/Logs/Settings/Admin) | ✅ | ✅ |
| Импорт профиля / QR | ✅ | ✅ |
| Подключение VPN | ❌ (NetworkExtension недоступен) | ✅ |
| Admin API (mTLS) | ⚠️ можно тестить с эмулятором сервера | ✅ через туннель |

**Важно:** iOS Simulator **не загружает** NetworkExtension-расширения. Все
UI-экраны можно смотреть в симуляторе, но чтобы реально включить туннель —
нужен физический iPhone с настроенным Team.

## App Groups

Оба таргета используют `group.com.ghoststream.vpn` для обмена конфигом и
статусом между main app и PacketTunnelProvider (через
`UserDefaults(suiteName:)` + Darwin notifications). Apple Developer портал
выдаёт App Group автоматически при первой сборке на устройстве.

## Шрифты

Все 7 TTF/OTF уже в `GhostStream/Theme/Fonts/` (Space Grotesk, Departure Mono,
JetBrains Mono, Instrument Serif) и зарегистрированы в `Info.plist → UIAppFonts`.
PostScript имена в `Theme/Typography.swift` помечены `// TODO verify` — их
нужно проверить один раз после первого запуска через:
```swift
UIFont.familyNames.flatMap { UIFont.fontNames(forFamilyName: $0) }
```

## Связь с Rust

10 C-функций из `crates/client-apple/src/lib.rs` вызываются из Swift через
`@_silgen_name` inline-декларации в `GhostStream/Rust/PhantomBridge.swift` —
без отдельного bridging header, чтобы упростить линковку через XCFramework.

## Известные ограничения iOS

- **Per-app routing** — Apple не даёт сторонним приложениям (нужен MDM
  entitlement). Поля в профиле (`perAppMode`, `perAppList`) сохраняются для
  совместимости, но игнорируются. Секция в Settings скрыта.
- **Ed25519 client cert для admin mTLS** — iOS `URLSession` не принимает
  Ed25519 в `SecIdentity`. Если сервер выдал клиенту Ed25519-сертификат —
  перевыпустить через `phantom-keygen` с флагом ECDSA P-256.
- **Sleep/wake** — система может усыплять PacketTunnelProvider. Heartbeats
  TLS из `client-common` поддерживают соединение; дополнительно `sleep()` /
  `wake()` в extension корректно останавливают/возобновляют polling.
