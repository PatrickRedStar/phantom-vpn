---
updated: 2026-04-17
---

# iOS

## Стек

- **SwiftUI** host app (`apps/ios/GhostStream/`)
- **`NEPacketTunnelProvider`** extension (`apps/ios/PacketTunnelProvider/`)
- **`PhantomKit`** — local Swift package (`apps/ios/Packages/PhantomKit/`):
  models + storage + FFI-bridge, shared между host app и extension
- **Rust core:** `crates/client-apple/` → `PhantomCore.xcframework`
- **Unified tunnel runtime:** `crates/client-core-runtime/` с `TunIo::Callback(Arc<dyn PacketIo>)`
- **`i18n`:** `Localizable.strings` — RU baseline + EN placeholder

Зрелость: **full parity с Android** (v0.22.0, 2026-04-17) — ADR [0005](../decisions/0005-client-core-runtime.md).

## Структура `apps/ios/`

```
Packages/PhantomKit/           # Swift package (shared code)
  Sources/PhantomKit/
    FFI/                       # PhantomBridge.swift, PhantomCore-Bridging.h
    Bridge/                    # TunnelIpcBridge.swift (host↔ext sendProviderMessage)
    Models/                    # StatusFrame, ConnState, LogFrame,
                               # TunnelSettings, ConnectProfile, VpnProfile
    Storage/                   # ProfilesStore, PreferencesStore, Keychain
    Resources/

GhostStream/                   # SwiftUI host app
  App/  UI/  Data/  Service/  Network/  Rust/  Theme/  Resources/
  GhostStream.entitlements
  Info.plist

PacketTunnelProvider/          # NE extension
  PacketTunnelProvider.swift   # entry point
  PhantomBridge.swift          # FFI → Rust runtime
  SharedState.swift            # App Group shared state
  PacketTunnelProvider.entitlements

Frameworks/                    # собранный PhantomCore.xcframework
GhostStream.xcodeproj/
project.yml                    # xcodegen spec
```

## Apple FFI (`crates/client-apple`)

C-интерфейс, экспортируется через `PhantomCore.xcframework`. Полный header —
[crates/client-apple/include/PhantomCore.h](../../../crates/client-apple/include/PhantomCore.h):

| Функция | Назначение |
|---|---|
| `phantom_start(config_json) -> i32` | Запуск runtime'а. `config_json` — `ConnectProfile` |
| `phantom_stop()` | Graceful shutdown runtime'а |
| `phantom_submit_outbound(ptr, len) -> i32` | Outbound IP-пакет от `packetFlow` в Rust |
| `phantom_set_inbound_callback(cb, ctx)` | Регистрация Swift-коллбэка для inbound IP-пакетов |
| `phantom_get_stats() -> *mut c_char` | JSON `{bytes_rx,bytes_tx,pkts_rx,pkts_tx,connected}` |
| `phantom_get_logs(since_seq) -> *mut c_char` | JSON-массив `LogFrame` |
| `phantom_set_log_level(level)` | "trace"/"debug"/"info"/"warn"/"error" |
| `phantom_parse_conn_string(input) -> *mut c_char` | Парсинг `ghs://...` → JSON с полями для iOS |
| `phantom_compute_vpn_routes(direct_cidrs) -> *mut c_char` | Инверсия CIDR-списка для split-routing |
| `phantom_free_string(ptr)` | **Обязательно** вызывать после использования строки из FFI |

Все строки — null-terminated C strings. Ownership любого `*mut c_char`,
возвращённого FFI-функцией, принадлежит caller'у (Swift); освобождается через
`phantom_free_string` — double-free или free чужого указателя = UB.

xcframework собирается скриптом [crates/client-apple/build-xcframework.sh](../../../crates/client-apple/build-xcframework.sh)
с настройками из [cbindgen.toml](../../../crates/client-apple/cbindgen.toml).

## PhantomKit — types

| Тип | Роль |
|---|---|
| `PhantomBridge` | Actor-isolated FFI wrapper; хранит runtime handle + callbacks |
| `StatusFrame` / `ConnState` / `LogFrame` / `TunnelSettings` / `ConnectProfile` | Codable mirrors of `crates/gui-ipc/` canonical wire types |
| `VpnProfile` | Storage model (id, name, serverAddr, serverName, tunAddr, cert/key, adminUrl, adminToken, cachedAdminServerCertFp, ...) |
| `ProfilesStore` | Список профилей + activeId, persisted в App Group shared container |
| `PreferencesStore` | DNS, routing mode, per-app, тема — App Group |
| `Keychain` | Сертификаты / ключи клиента + pinned server FP |
| `TunnelIpcBridge` | Wrapper вокруг `sendProviderMessage` для host ↔ extension IPC |

Все Codable-модели в `Models/` — **зеркала** Rust-типов из `crates/gui-ipc/`.
При изменении shape'а с Rust-стороны обновлять синхронно (runtime отправляет
`serde_json` — любой mismatch → decode error в Swift).

## IPC host ↔ extension

iOS sandbox разделяет host app и NE extension. Для обмена — `NETunnelProviderManager.sendProviderMessage`
(wrapper — `TunnelIpcBridge`). Типичные сообщения: `start(profileId)`, `stop`,
`status()`, `logs(sinceSeq)`.

`profileId` передаётся из host app в extension через IPC — extension сам
читает профиль из `ProfilesStore` (App Group shared) и запускает Rust runtime.
Секреты (cert/key) живут в Keychain с shared access group.

## IPv6 killswitch

В `PacketTunnelProvider` (добавлено в v0.22.0 Phase 6): IPv6-трафик, который
система может пустить мимо TUN-интерфейса, блокируется на уровне
`NEPacketTunnelNetworkSettings.ipv6Settings` с route'ом `::/0` в туннель (или
явным отказом от IPv6), чтобы не утекал plain IPv6 при IPv4-only конфиге
туннеля. Защита от классической DNS/трафик утечки при dual-stack клиенте.

## i18n

`Localizable.strings` с RU как baseline (русскоязычная аудитория) и EN-placeholder
(будет дозаполняться по мере нужды). Переключение автоматическое по системному
языку устройства.

## Архитектурные особенности

- **`TunIo::Callback`** — iOS не даёт raw fd TUN'а. Используется
  `NEPacketTunnelFlow.readPackets/writePackets`. Rust вызывает Swift callback'и
  через FFI, Swift кладёт пакеты в packetFlow и обратно.
- **App Group shared storage** — host app и extension разделены sandbox'ом. Общие
  storages: Keychain + `UserDefaults` в App Group container. `ProfilesStore` и
  `PreferencesStore` читают оттуда оба процесса.
- **Host↔extension IPC** — через `sendProviderMessage` (обёрнуто в `TunnelIpcBridge`).
- **Background limits** — NE extension лимитирован по CPU и памяти. Heavy compute
  (TLS, batching) держать в Rust runtime, I/O — async.

## Критичные pitfalls

- **Не забыть `phantom_free_string`** для каждой строки, полученной из FFI. Утечки
  не ловятся тестами, вырастают в production.
- **Codable mismatch** при изменении Rust-типов из `gui-ipc` — apply synchrone
  правки в `PhantomKit/Models/*.swift`.
- **App Group identifier** должен совпадать в entitlements host app и extension,
  иначе shared storage не работает (молчаливо — просто пустые данные).
- **Keychain access group** — cert/key должны быть доступны extension'у
  (`kSecAttrAccessGroup` = App Group).
- **IPv6 killswitch** — без него при dual-stack iOS может пустить IPv6 напрямую,
  мимо TUN, что раскрывает реальный IP.
- **xcframework** пересобирать после любых правок в `crates/client-apple/` —
  Xcode не детектит изменения автоматически, нужен `build-xcframework.sh`.
- **Dev provisioning profile** — для локального тестирования NE extension нужен
  paid Apple Developer account, free не даёт NetworkExtension entitlement.

## Релизный процесс

iOS релизится в TestFlight / App Store (отдельно от Android-тегов, на общем `v*`-теге):

```bash
# 1. Пересобрать Rust xcframework (если правил client-apple/client-core-runtime)
cd crates/client-apple && ./build-xcframework.sh

# 2. Открыть проект
cd apps/ios
xcodegen generate      # если project.yml менялся
open GhostStream.xcodeproj
```

Archive + upload — через Xcode Organizer (manual code signing, App Store distribution).
Отдельная таблица `versionCode` не ведётся — App Store требует только `CFBundleVersion`
инкрементальным.

## Sources

- **Host app:** [apps/ios/GhostStream/](../../../apps/ios/GhostStream/)
- **PacketTunnelProvider extension:** [apps/ios/PacketTunnelProvider/](../../../apps/ios/PacketTunnelProvider/)
- **PhantomKit package:** [apps/ios/Packages/PhantomKit/](../../../apps/ios/Packages/PhantomKit/)
- **iOS README:** [apps/ios/README.md](../../../apps/ios/README.md)
- **Rust FFI:** [crates/client-apple/](../../../crates/client-apple/), [PhantomCore.h](../../../crates/client-apple/include/PhantomCore.h)
- **Runtime (shared):** [crates/client-core-runtime/](../../../crates/client-core-runtime/)
- **Canonical wire types:** [crates/gui-ipc/](../../../crates/gui-ipc/)
- **ADR:** [0005 client-core-runtime](../decisions/0005-client-core-runtime.md), [0004 ghs:// conn_string](../decisions/0004-ghs-url-conn-string.md)
- **gitnexus:** `gitnexus_query({query: "apple ffi phantom start"})`, `gitnexus_query({query: "ios packet tunnel provider"})`
- **Handshake:** [../architecture/handshake.md](../architecture/handshake.md)
- **Troubleshooting:** [../troubleshooting.md](../troubleshooting.md)
