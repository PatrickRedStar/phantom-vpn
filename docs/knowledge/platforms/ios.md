---
updated: 2026-10-27
---

# iOS

## Стек

- **SwiftUI** host app (`apps/ios/GhostStream/`)
- **`NEPacketTunnelProvider`** extension (`apps/ios/PacketTunnelProvider/`)
- **`PhantomKit`** — local Swift package (`apps/ios/Packages/PhantomKit/`):
  models + storage + FFI-bridge, shared между host app и extension
- **Rust core:** `crates/client-apple/` → `PhantomCore.xcframework`
- **Unified tunnel runtime:** `crates/client-core-runtime/` с `TunIo::Callback(Arc<dyn PacketIo>)`
- **`i18n`:** `Localizable.strings` — RU baseline + EN, `ru.lproj/InfoPlist.strings`

Зрелость: **full parity с Android** (v0.22.0, 2026-04-17) — ADR [0005](../decisions/0005-client-core-runtime.md).

## Структура `apps/ios/`

```
Packages/PhantomKit/           # Swift package (shared code)
  Sources/PhantomKit/
    FFI/                       # PhantomBridge.swift, PhantomCore-Bridging.h
    Bridge/                    # TunnelIpcBridge (host↔ext sendProviderMessage),
                               # SharedState (App Group), ConnStringBuilder
    Models/                    # StatusFrame, ConnState, LogFrame,
                               # TunnelSettings, ConnectProfile, VpnProfile
    Storage/                   # ProfilesStore, PreferencesStore, Keychain
    Resources/

GhostStream/                   # SwiftUI host app
  App/  UI/  Data/  Service/  Network/  Rust/  Theme/  Resources/
  GhostStream.entitlements
  Info.plist

PacketTunnelProvider/          # NE extension
  PacketTunnelProvider.swift   # entry point (FFI — PhantomBridge из PhantomKit)
  PrivacyInfo.xcprivacy        # у приложения — свой в GhostStream/
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
| `phantom_runtime_set_release_cb(cb)` | Один раз при старте: Swift-колбэк, который освобождает `ctx` |
| `phantom_runtime_start(cfg_json, settings_json, verbose_log, status_cb, log_cb, outbound_cb, ctx) -> i32` | Запуск runtime'а. `cfg_json` — `ConnectProfile`; статус, логи и пакеты к устройству приходят колбэками |
| `phantom_runtime_submit_inbound(ptr, len) -> i32` | IP-пакет от `packetFlow` в туннель; -10 = очередь полна (drop) |
| `phantom_runtime_stop() -> i32` | Синхронный стоп: ждёт супервизор до 5 с, потом abort + join; `ctx` освобождается, только если всё дожато, иначе намеренно утекает |
| `phantom_parse_conn_string(input) -> *mut c_char` | Парсинг `ghs://...` → JSON с полями для iOS |
| `phantom_compute_vpn_routes(direct_cidrs) -> *mut c_char` | Инверсия CIDR-списка для split-routing |
| `phantom_free_string(ptr)` | **Обязательно** вызывать после использования строки из FFI |

`PhantomBridge` сверяет `BridgeContext` каждого колбэка с текущим: запоздалые
статусы и логи прошлой (утёкшей) сессии отбрасываются.

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
| `VpnProfile` | Storage model (id, name, serverAddr, serverName, tunAddr, cert/key PEM, relay, кэш из `/api/me`: cachedExpiresAt/cachedEnabled/cachedIsAdmin, cachedAdminServerCertFp, ...) |
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

## Состояния, ошибки, подписка

Одинаково для iOS и macOS. Переподключением владеет ядро ([ADR 0018](../decisions/0018-rust-owns-reconnect.md)):
при сетевых сбоях оно ретраит бесконечно и публикует `reconnecting`.

- **У провайдера нет своих watchdog'ов** — ни «нет connected за N с», ни
  «слишком долго в reconnecting»: они гасили или перезапускали туннель поверх
  ретраев ядра. Провайдер реагирует только на `connected` (completion для NE),
  `error` и события NE. Сон ядро ловит само (скачок wall-clock), поэтому на
  `wake()` macOS-провайдер только пишет событие. Смена сети (NWPathMonitor,
  только macOS) перезапускает рантайм, лишь когда ядро не в `connected`, —
  это срезает паузу бэкоффа, живую сессию не рвёт.
- **`reconnecting` — отдельное состояние** и на iOS: провайдер ставит
  `reasserting = true` на время переподключения ядра (системный статус —
  «Переподключение»), дашборд показывает «Переподключение», таймер сессии
  не сбрасывается — `session_secs` ядра идёт через переподключения.
- **`error` = фатальная причина** (отзыв доступа, истёкший доступ, неверные
  часы, кривой профиль). Провайдер останавливает туннель, error-кадр остаётся в
  снапшоте, и хост показывает `last_error` до следующего Connect. Неудачный
  рестарт рантайма по смене сети тоже останавливает туннель с
  причиной, а не оставляет его без рантайма.
- **Дашборд** при поднятом туннеле показывает плашку здоровья, как на Android:
  все потоки упали (`dead`), живы k из n (`degraded`), тишина в канале
  (`stale`), скорость ограничена (только по `bandwidth_class = throttled`).
  `TunnelHealth` в PhantomKit знает `dead`.
- **Подписка и флаг админа** берутся из `/api/me` (`expires_at`, `enabled`,
  `is_admin`) и кладутся в кэш профиля до запросов админки — срок видят и
  не-админы. Старый сервер без этих полей кэш не трогает.

## Маршруты, relay, MTU

- **Relay** ([ADR 0013](../decisions/0013-macos-admin-relay-parity.md)):
  на iOS в `providerConfiguration` едет только `profileId`, поэтому подмена
  адреса — в extension: `VpnProfile.withRelayEndpoint` ставит relay в
  `serverAddr` и в authority `ghs://`, SNI остаётся exit'ом. В редакторе
  профиля — тумблер Relay и `host:port` (без порта — порт exit'а).
- **Полный туннель пропускает LAN** ([ADR 0019](../decisions/0019-owner-decisions-audit-2026-10.md)):
  `excludedRoutes` = те же диапазоны, что Android `SPECIAL_RANGES` (0/8,
  10/8, 100.64/10, 127/8, 169.254/16, 172.16/12, 192.168/16, 224/4, 240/4);
  подсеть туннеля из `tunAddr` — в `includedRoutes` (admin API). Свой /32
  сервера/реле не нужен: сокеты NE-провайдера мимо туннеля.
- **MTU 1300**, как на Android.
- На старте туннеля в журнал (экран «Журнал») пишется строка
  `tunnel start relay=on|off target=… sni=… mtu=… excludedRoutes=N`.

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
- **Background limits** — NE extension лимитирован по CPU и памяти (~50 МБ,
  jetsam). Heavy compute (TLS, batching) держать в Rust runtime, I/O — async;
  очереди ядра под iOS меньше (256 / 1024), число стримов не трогается.
  Колбэки Rust (status, логи, пакеты) `PhantomBridge` выполняет синхронно на
  потоке форвардера в `autoreleasepool` — без Task на кадр, медленный
  потребитель упирается в ограниченный канал ядра. Раз в 60 с провайдер
  пишет в журнал `memory footprint=… available=…` (`phys_footprint` и
  `os_proc_available_memory()`) — видно, сколько до лимита.
- **Потокобезопасность провайдера** — буферы статуса/логов, gate снапшотов и
  флаг completion `startTunnel` под `stateLock`, как на macOS (двойной
  completion ронял бы экстеншен).

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

CI: `.github/workflows/ios-ci.yml` — xcframework, `swift test` PhantomKit,
симуляторная сборка + GhostStreamTests (без подписи). Версия — в
`project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`), SHA коммита
кладётся в `GitCommitSHA` Info.plist пост-сборочным шагом. Манифесты
приватности — `PrivacyInfo.xcprivacy` у приложения и extension.

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
