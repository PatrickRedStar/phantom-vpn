---
name: Dev-macOS-GUI
description: GhostStream macOS GUI client developer — owns apps/macos/ (SwiftUI + NEPacketTunnelProvider)
type: reference
---

# Разработчик — macOS GUI Client

## Зона ответственности
- `apps/macos/` — весь Swift/SwiftUI код
- `crates/client-macos/src/lib.rs` — FFI-мост (C ABI для NetworkExtension)

При изменениях FFI — **обязательно согласовать с Архитектором**.

## Bundle / App Group
- Bundle ID: `com.ghoststream.vpn.macos`
- App Group: `group.com.ghoststream.vpn` (shared container для host ↔ NE extension)
- NetworkExtension: `NEPacketTunnelProvider` subclass

## Технический стек
- **SwiftUI** + **Combine** (реактивный UI)
- **NetworkExtension.framework** — `NEPacketTunnelProvider` (аналог Android VPN Service)
- **Sparkle** — авто-обновления (опционально)
- Xcode 15+, Swift 5.9+, macOS 13+ Ventura (target)
- Подпись: Developer ID Application + NetworkExtension entitlement (требует Apple подписи)

## Архитектура

```
GhostStream.app (host)
├── MainWindow (SwiftUI)        ← UI: Connect, профили, логи, settings
├── ProfileStore (Keychain + App Group UserDefaults)
└── VpnManager                  ← обёртка над NETunnelProviderManager

GhostStreamTunnel.appex (Network Extension)
├── PacketTunnelProvider        ← subclass of NEPacketTunnelProvider
│   - startTunnel(options:) → утверждает tunnelNetworkSettings
│   - stopTunnel(with:) → graceful shutdown
│   - setTunnelNetworkSettings → IPv4 routes, DNS
│   → вызывает FFI: phantom_start(tun_fd, server, sni, cert, key)
└── LogStreamer (XPC к host через App Group file)
```

## FFI контракт (C ABI из Rust)

Rust сторона: `crates/client-macos/src/lib.rs` (cdylib, `#[no_mangle] pub extern "C"`).
Swift-сторона: module map + bridging header.

```swift
// Ожидаемые символы
func phantom_start(_ tunFd: Int32,
                   _ serverAddr: UnsafePointer<CChar>,
                   _ serverName: UnsafePointer<CChar>,
                   _ certPath: UnsafePointer<CChar>,
                   _ keyPath: UnsafePointer<CChar>,
                   _ caCertPath: UnsafePointer<CChar>) -> Int32
// 0=OK, -10=spawn failed (OOM)
func phantom_stop()
func phantom_get_stats() -> UnsafePointer<CChar>?      // JSON
func phantom_get_logs(sinceSeq: Int64) -> UnsafePointer<CChar>?  // JSON
func phantom_set_log_level(_ level: UnsafePointer<CChar>)
func phantom_free_cstring(_ ptr: UnsafePointer<CChar>) // ОБЯЗАТЕЛЬНО освобождать строки из Rust
```

## Specifics — macOS TUN
- Нельзя `/dev/net/tun` (нет на macOS). `NEPacketTunnelProvider.packetFlow` — это `NEPacketFlow` (read/write через callbacks).
- **Но** для io_uring-подобной архитектуры используется `utun` kernel device через fd, переданный в extension (`self.packetFlow`). Rust получает fd и читает/пишет напрямую.
- AF prefix: **4 байта** (`AF_INET = 0x00000002` BE) перед каждым IP-пакетом. Rust должен стрипать/добавлять.
- io-uring **недоступно** на macOS — использовать обычные blocking read/write в отдельном потоке (`std::thread::spawn`).

## Connection string
Тот же `ghs://` URL-формат что Android/Linux. Парсинг через `crates/client-common/src/helpers.rs::parse_conn_string` (переиспользуем).

Способы ввода:
1. Paste из буфера (⌘V)
2. QR-код через камеру (AVFoundation + Vision framework)
3. Drag-n-drop `.ghs` файла

## Permissions / Entitlements
- `com.apple.developer.networking.networkextension` = `packet-tunnel-provider`
- `com.apple.security.application-groups` = `group.com.ghoststream.vpn`
- Codesigning with Developer ID + провижен профилем
- First-run: пользователь через System Settings → VPN одобряет конфигурацию

## Сборка и деплой

```bash
# Rust cdylib (universal binary для arm64 + x86_64)
cargo build --release -p phantom-client-macos --target aarch64-apple-darwin
cargo build --release -p phantom-client-macos --target x86_64-apple-darwin
lipo -create -output apps/macos/Frameworks/libphantom_macos.dylib \
  target/aarch64-apple-darwin/release/libphantom_macos.dylib \
  target/x86_64-apple-darwin/release/libphantom_macos.dylib

# Xcode build (локально на macOS машине, НЕ vdsina — нет SDK)
cd apps/macos
xcodebuild -scheme GhostStream -configuration Release \
           -archivePath build/GhostStream.xcarchive archive
xcodebuild -exportArchive -archivePath build/GhostStream.xcarchive \
           -exportOptionsPlist exportOptions.plist \
           -exportPath build/
# DMG: hdiutil create build/GhostStream.dmg ...
```

## Тестирование
- Локально: установить `.app`, одобрить профиль VPN, Connect через UI
- Логи host: `Console.app` → фильтр по `com.ghoststream.vpn`
- Логи extension: `log stream --predicate 'subsystem == "com.ghoststream.vpn.tunnel"'`

## Известные гетчи
- **Extension крашится без логов** — чаще всего codesign/entitlement, проверь через `codesign -d --entitlements :- GhostStream.app/Contents/PlugIns/GhostStreamTunnel.appex`
- **packetFlow.readPackets callback** может вызываться с пустым массивом — надо повторно планировать чтение
- **Memory limit extension**: 15 MB резидентно на macOS (против 50 MB на iOS). Bytes pool обязателен.
- **Sandbox FS**: extension не может писать в `~/Library/Application Support/` хоста. Всё через App Group container.

## Запрещено без архитектора
- Менять FFI сигнатуры без обновления Rust (и наоборот)
- Менять TUN MTU (должен быть 1350)
- Менять формат `ghs://` conn_string
- Добавлять iOS target без согласования (был удалён в v0.15.x, возврат — отдельный проект)

## Крупные задачи
Если изменение затрагивает `client-common` / `core` или сервер — сказать main agent'у
использовать параллельные субагенты одним `Agent` tool-call. См. `ORCHESTRATION.md`.
