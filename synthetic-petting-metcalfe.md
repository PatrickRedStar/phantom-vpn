# Правильный перенос iOS + консолидация tunnel-runtime

## Context

iOS-скаффолд, собранный в предыдущей сессии, не стыкуется с Android и сам по себе не работает на устройстве. Три параллельных аудита (Android feature-catalog, Linux GUI + gui-ipc, iOS bug-catalog) выявили **единый корневой дефект** и ≈12 частных багов.

**Корневой дефект:** в репе уже есть каноничный UI-контракт `crates/gui-ipc` (`StatusFrame`, `ConnState`, `LogFrame`, `TunnelSettings`, `ConnectProfile`) — Linux helper и Linux GUI общаются именно в нём через newline-JSON поверх Unix-socket. Android JNI и текущий Apple FFI его проигнорировали и каждый налепил свою bespoke JSON-схему — **три несовместимых формата на одни и те же данные**. Swift `LogEntry` вообще не декодируется (`ts: Double` vs Rust `"HH:MM:SS"`) → `logs()` всегда пустой. Pipeline туннеля (N параллельных TLS + flow-dispatcher + counters + TX/RX loops) продублирован **трижды** (Linux helper, Linux CLI, Android JNI); iOS FFI был бы четвёртым.

**Частные баги iOS (блокеры):** оба `.entitlements` файла — пустой `<dict/>` (ни App Group, ни NetworkExtension, ни keychain-access-groups → extension не запустится вообще); `VpnTunnelController.providerBundleId` = `.PacketTunnel`, реальный = `.PacketTunnelProvider` — mismatch, менеджер не найдёт extension, ghost-configs копятся; `PhantomBridge.swift` продублирован byte-for-byte в app + extension; `statsLoop` отрабатывает один раз и выходит — после первого `connected` UI-state не обновляется; "8/8 STREAMS" и MuxBars — захардкоженное враньё; AdminView существует, но unreachable из навигации; split-routing toggle в Settings nowhere не подключён; IPv6 settings `nil` → leak; xcframework содержит Finder-dedup (`Info 2.plist`, `ios-arm64 2/`).

**Цель:** привести архитектуру к исходной идее «общее клиентское ядро — тонкие платформенные оболочки». Всё runtime-поведение (transport + telemetry + reconnect + logging) живёт в одном крейте; все GUI потребляют `gui-ipc` типы verbatim через serde. iOS получает полный feature-parity с Android v0.21.0 минус того, что Apple запретила (per-app routing) и что out-of-scope (TV pairing).

**Принятые решения:**
- Scope консолидации — **iOS + Linux helper + Android JNI** в одном заходе (не только iOS).
- v1 iOS фичи — **full parity минус невозможное**: Dashboard, Logs, Settings (тема, язык, DNS, split-routing, QR, debug-share, subscription), Admin. Без per-app, без TV pairing.
- Локализация — `Localizable.strings` RU baseline + EN-заглушки (Android хардкодит Russian — iOS начинает правильно).
- Android trunk в production (v0.21.0, 55) — миграция JNI обязательна к валидации на реальном телефоне с прогоном туннеля + screenshot-diff всех 5 экранов vs reference.

---

## Целевая архитектура

```
┌── crates/gui-ipc  (CANONICAL WIRE TYPES — используются verbatim) ─────┐
│   StatusFrame · ConnState · LogFrame · TunnelSettings · ConnectProfile │
└─────────────────────────────────┬──────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼──────────────────────────────────────┐
│  crates/client-core-runtime  (NEW)                                     │
│  pub async fn run(cfg, tun_io, settings, status_tx, log_tx)            │
│    ├── Telemetry { bytes_rx/tx · stream_tx_bytes[16] · streams_alive } │
│    ├── telemetry task (250 ms tick → StatusFrame → watch::Sender)      │
│    ├── supervise() FSM  (BACKOFF=[3,6,12,24,48,60,60,60], 8 attempts)  │
│    ├── BroadcastLayer  (tracing::Layer → LogFrame → mpsc::Sender)      │
│    ├── flow dispatcher  (flow_stream_idx → N mpsc → TLS streams)       │
│    └── TunIo: Uring(fd) | BlockingThreads(fd) | Callback(Arc<dyn Io>)  │
└────┬──────────────┬───────────────────┬──────────────────┬─────────────┘
     │              │                   │                  │
┌────▼──────┐ ┌─────▼────────┐ ┌────────▼─────────┐ ┌──────▼──────────┐
│ linux-    │ │ linux-cli    │ │ client-android   │ │ client-apple    │
│ helper    │ │              │ │ (JNI listener)   │ │ (C FFI push)    │
│ (socket)  │ │ (tun_uring)  │ │ TunIo::Blocking  │ │ TunIo::Callback │
└───────────┘ └──────────────┘ └──────────────────┘ └─────────────────┘
```

**Ключевой сдвиг:** stats/logs доставляются платформе **push-style** через callback (runtime тикает `watch::Sender<StatusFrame>` → FFI вызывает `status_cb`). Polling `nativeGetStats()` уходит отовсюду.

---

## Фазы

### Phase 0 — Hygiene (1–2 ч, блокер для всего)

1. **Заполнить entitlements** (сейчас `<dict/>`):
   - `apps/ios/GhostStream/GhostStream.entitlements`:
     - `com.apple.security.application-groups = [group.com.ghoststream.vpn]`
     - `com.apple.developer.networking.networkextension = [packet-tunnel-provider]`
     - `keychain-access-groups = [$(AppIdentifierPrefix)group.com.ghoststream.vpn]`
   - `apps/ios/PacketTunnelProvider/PacketTunnelProvider.entitlements` — те же три.
2. **Bundle-id mismatch**: `VpnTunnelController.providerBundleId` — `"\(Bundle.main.bundleIdentifier!).PacketTunnelProvider"`, не хардкод `.PacketTunnel`.
3. **Очистить XCFramework**: `rm -rf` на `Info 2.plist`, `ios-arm64 2/`, `ios-arm64_x86_64-simulator 2/`. В `build-xcframework.sh` добавить `rm -rf "$OUT"` перед `xcodebuild -create-xcframework`.
4. **cbindgen** step в `build-xcframework.sh` — C-header регенерируется каждый билд, drift невозможен.

### Phase 1 — `crates/client-core-runtime` (1–2 дня)

Извлечение из `apps/linux/helper/src/linux/tunnel.rs` (~500 LOC), очистка от Linux-specific bits. Публичный API:

```rust
pub use gui_ipc::{StatusFrame, ConnState, LogFrame, TunnelSettings, ConnectProfile};

pub const BACKOFF_SECS: &[u32] = &[3, 6, 12, 24, 48, 60, 60, 60];
pub const MAX_ATTEMPTS: u32 = 8;

pub enum TunIo {
    Uring(RawFd),                  // Linux helper + CLI
    BlockingThreads(RawFd),        // Android (нет io_uring)
    Callback(Arc<dyn PacketIo>),   // iOS (NEPacketTunnelFlow)
}

pub trait PacketIo: Send + Sync {
    fn submit_outbound_batch(&self, pkts: Vec<Bytes>);
}

pub struct RuntimeHandles {
    pub cancel: Arc<Notify>,
    pub inbound_tx: mpsc::Sender<Bytes>,  // для Callback mode: owner → runtime
}

pub async fn run(
    cfg: ConnectProfile,
    tun: TunIo,
    settings: TunnelSettings,
    status_tx: tokio::sync::watch::Sender<StatusFrame>,
    log_tx: tokio::sync::mpsc::Sender<LogFrame>,
) -> (RuntimeHandles, JoinHandle<Result<()>>);
```

- Hoist `Telemetry` + `telem_task` (250 ms EMA α=0.35) из linux helper.
- Hoist `supervise()`, **починить `reconnect_next_delay_secs`** (в supervise он сейчас никогда не populates — Linux-аудит §6).
- Hoist `BroadcastLayer` (tracing → LogFrame) из `logsink.rs`.
- **Новое:** RTT probe task на stream_idx=0 (TCP keepalive RTT) → `StatusFrame.rtt_ms` (сейчас всегда `None`).
- Deps: `phantom-core`, `client-common`, `gui-ipc`, `tokio`, `tracing`, `rustls`, `bytes`.

### Phase 2 — Linux helper → client-core-runtime (0.5 дня)

- `apps/linux/helper/src/linux/tunnel.rs` ужимается до ≈80 LOC адаптера над `client_core_runtime::run`.
- Helper сохраняет: Unix-socket serve, `DnsGuard`, `Ipv6Guard`, `RouteGuard`, pkexec/uid plumbing.
- `apps/linux/cli/src/main.rs` тоже переезжает на `run(cfg, TunIo::Uring(fd), ...)`.
- Validation: `cargo build -p ghoststream-helper -p phantom-client-linux -p ghoststream-gui` + smoke-test туннеля к vdsina (`89.110.109.128:8443`).

### Phase 3 — Apple FFI → client-core-runtime (1 день)

Новый `crates/client-apple/src/lib.rs` (≈150 LOC вместо 700):

```c
int32_t phantom_runtime_start(
    const char *cfg_json,       // serde::to_string(ConnectProfile)
    const char *settings_json,  // serde::to_string(TunnelSettings)
    void (*status_cb)  (const uint8_t *buf, size_t len, void *ctx),
    void (*log_cb)     (const uint8_t *buf, size_t len, void *ctx),
    void (*inbound_cb) (const uint8_t *buf, size_t len, void *ctx),
    void *ctx);
int32_t phantom_runtime_submit_outbound(const uint8_t *buf, size_t len);
int32_t phantom_runtime_stop(void);
char   *phantom_parse_conn_string(const char *input);
char   *phantom_compute_vpn_routes(const char *cidrs_path);
void    phantom_free_string(char *ptr);
```

- `status_cb`: каждый tick `watch::Sender<StatusFrame>` → Rust сериализует JSON `StatusFrame` verbatim → `status_cb`. **No polling.**
- `log_cb`: один вызов на `LogFrame`.
- Swift сторона: `PhantomBridge` предоставляет `Callback`-реализацию `PacketIo` (`packetFlow.writePackets` → `inbound_cb` → runtime `mpsc`).

### Phase 4 — Android JNI → client-core-runtime (1 день + APK regression)

- `crates/client-android/src/lib.rs` переписан с bespoke JSON + globals на `TunIo::BlockingThreads(fd)` + listener через JNI:
  - `external fun nativeStart(tunFd: Int, cfgJson: String, settingsJson: String, listener: PhantomListener): Int`
  - `interface PhantomListener { fun onStatusFrame(json: String); fun onLogFrame(json: String) }`
- `GhostStreamVpnService` реализует `PhantomListener`, парсит `StatusFrame`/`LogFrame`, пушит в `VpnStateManager.statusFlow: StateFlow<StatusFrame>`.
- `DashboardViewModel.startStatsPolling` **удаляется** — подписка на flow. Аналогично `LogsViewModel.init` 500 ms-loop.
- `ConnStringParser.kt` удаляется, `parse_conn_string` уходит в FFI call (unification с iOS).
- **Регрессия-валидация (merge-blocker):**
  - Собрать APK через SSH-tunnel на home PC (reference `memory/reference_apk_build.md`).
  - `adb install`, ручной прогон: connect к vdsina, `ifconfig.me` показывает NL IP, disconnect/reconnect loop 10×, reconnect-backoff countdown визуально корректный, logs DEBUG tab даёт поток, admin subscription extend работает.
  - Screenshot diff всех 5 экранов vs v0.21.0 reference.

### Phase 5 — Swift local package `PhantomKit` (0.5 дня)

```
apps/ios/Packages/PhantomKit/
├── Package.swift
└── Sources/PhantomKit/
    ├── FFI/
    │   ├── PhantomBridge.swift          ← единственный экземпляр
    │   └── PhantomCore-Bridging.h
    ├── Models/
    │   ├── StatusFrame.swift           ← Codable mirror gui-ipc
    │   ├── ConnState.swift             ← enum + asUiWord()
    │   ├── LogFrame.swift
    │   ├── TunnelSettings.swift
    │   ├── ConnectProfile.swift
    │   └── VpnProfile.swift            ← storage schema 1:1 с Android
    ├── Storage/
    │   ├── ProfilesStore.swift         ← App Group JSON
    │   ├── PreferencesStore.swift      ← App Group UserDefaults
    │   └── Keychain.swift              ← shared access group
    └── Bridge/
        └── TunnelIpcBridge.swift       ← sendProviderMessage wrapper
```

- Оба target (`GhostStream`, `PacketTunnelProvider`) делают `import PhantomKit` — byte-for-byte-дубль `PhantomBridge.swift` в extension **удаляется**.
- `ConnState.asUiWord() -> String` — Swift port из `gui_ipc::ConnState`. Локализация через `String(localized:)`.
- `VpnProfile` 1:1 с Android `data/VpnProfile.kt` (все 15 полей).
- PEM — Keychain-only (single source of truth, extension читает через access group); `providerConfiguration` несёт только `profileId: String` — никаких PEM в NE preferences database.

### Phase 6 — PacketTunnelProvider переписать (1 день)

`apps/ios/PacketTunnelProvider/PacketTunnelProvider.swift`:
- `startTunnel(options:)`:
  1. `profileId = providerConfiguration["profileId"]` → `ProfilesStore.load(id:)` → PEM из Keychain.
  2. `NEPacketTunnelNetworkSettings`:
     - `IPv4Settings(addresses:[tunIp], subnetMasks:[mask])` + `includedRoutes` из `phantom_compute_vpn_routes` (split-routing) либо `[NEIPv4Route.default()]`.
     - **`IPv6Settings(addresses:[], networkPrefixLengths:[])` + excludedRoutes=[default]** — IPv6 killswitch на tunnel-уровне (сейчас leak).
     - `DNSSettings(servers: profile.dnsServers ?? ["1.1.1.1","8.8.8.8"])` + `matchDomains=[""]`.
     - `MTU = 1350`.
  3. `PhantomBridge.start(cfg, settings, statusCb: ..., logCb: ..., inboundCb: ...)`.
  4. Outbound: `packetFlow.readPackets { pkts, _ in PhantomBridge.submitOutbound(pkts) }` — бесконечный цикл.
  5. Inbound cb → `packetFlow.writePackets([data], withProtocols:[AF_INET])`.
- `stopTunnel(with:)` — cancel outbound task → `PhantomBridge.stop()`.
- `wake()` / `sleep()` — правильные хэндлеры.
- **IPC с host app** через `handleAppMessage(_:)` (`NETunnelProviderSession.sendProviderMessage`):
  - App шлёт `GetStatus` / `SubscribeLogs(sinceSeq)` / `GetCurrentProfile` / `Disconnect`.
  - Extension отвечает сериализованным `StatusFrame` / `[LogFrame]`.
- **Fallback** если session недоступен (extension kill): при каждом status-тике extension пишет `snapshot.json` в App Group; host app читает при старте или при provider-session EOF; `DispatchSource.makeFileSystemObjectSource` для обновлений.

### Phase 7 — iOS Data layer (в PhantomKit, 0.5 дня финализация)

- `ProfilesStore` → `files/profiles.json` в `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn")`.
- `PreferencesStore` → `UserDefaults(suiteName: "group.com.ghoststream.vpn")`, все ключи из Android `PreferencesStore.kt` minus legacy globals (Android §7 — они dead code, не тащим).
- `Keychain` → `kSecAttrAccessibleAfterFirstUnlock` + `kSecAttrAccessGroup = "$(AppIdentifierPrefix)group.com.ghoststream.vpn"`.
- **Удалить double-storage** PEM: только Keychain, провер конфиг несёт лишь `profileId`.

### Phase 8 — iOS Service layer (0.5 дня)

- `VpnStateManager`: `@Observable class`, держит `statusFrame: StatusFrame?` + `@Published var state: ConnState`. Источники: `NETunnelProviderSession.sendProviderMessage` (live) + `DispatchSource.FileSystemObject` над snapshot.json (fallback).
- `VpnTunnelController`:
  - `providerBundleId = "\(Bundle.main.bundleIdentifier!).PacketTunnelProvider"` — вычисляется, не хардкод.
  - `loadOrCreateManager()`: идемпотентный поиск по bundle-id, если `filter > 1` — сносим ghosts.
  - `installAndStart(profile:)`: `providerConfiguration = ["profileId": profile.id]` + `serverAddress: profile.serverAddr`.
  - `isOnDemandEnabled = prefs.autoStartOnBoot` + `onDemandRules = [NEOnDemandRuleConnect()]`.

### Phase 9 — UI screens 1:1 с Android (2–3 дня)

**Theme (0.5 дня):**
- Bootstrap-probe в `GhostStreamApp.init`: `UIFont.fontNames(forFamilyName:)` × 3 семейства → hard-code правильные PostScript names в `Typography.swift`. Убрать все `// TODO verify at runtime`.
- Colors — скопированы hex-in-hex с Android (iOS-audit §6).

**Dashboard:**
- State label ← `statusFrame.state.asUiWord()` (локализовано: RU «ПЕРЕДАЮ / КОНТАКТ / ПЕРЕСБОР / ДРЕМА / ОБРЫВ», EN «Transmitting/Handshaking/Regrouping/Dormant/Severed»).
- **`.reconnecting` state ПРИСУТСТВУЕТ** — баг унификации с Android (там тоже нет).
- Throughput ← `rateRxBps / rateTxBps` напрямую из `StatusFrame`, вручную не считаем.
- **MuxBars** переписать — реальные `streamActivity[16]`. "N/M STREAMS" ← `streamsUp/nStreams`. Убрать захардкод "8/8".
- Scope chart: ring-buffer client-side 60/300/1800/3600 s, кормится реальными rate-значениями.
- Reconnect banner: `state == .reconnecting` → «Попытка N/8, следующая через Xс» (`reconnect_attempt`, `reconnect_next_delay_secs`).
- Subscription card: `AdminHttpClient.getClients()` → match by `tun_addr` → обновляет `cachedExpiresAt/cachedEnabled/cachedIsAdmin/cachedAdminServerCertFp`. Преобразование даты — structured (`subscription.expired` bool), не substring-match (Android-аудит §2 tech debt).
- Preflight banner: `cachedExpiresAt < now` OR `cachedEnabled == false` → error-tint полоса + hint.
- Connect/Disconnect FAB — inline в скролле (сохраняется из прошлой сессии).

**Logs:**
- Polling 500 ms через `sendProviderMessage(GetLogs(sinceSeq))`; runtime push-based на FFI-уровне, но host↔extension messaging polling окей.
- Filter chips ALL/TRACE/DEBUG/INFO/WARN/ERROR, default INFO, FIFO cap 50 000.
- Auto-scroll (reverseLayout), цвета per-level (ERROR=danger, WARN=warn, DEBUG=BlueDebug).
- Share → `UIActivityViewController` поверх `NSTemporaryDirectory()/ghoststream-logs-<epoch>.txt`.
- Copy / Copy All — **UI-триггеры добавить** (на Android существуют в VM но не подключены — чиним обе).

**Settings (full Android parity):**
- Profile list: card per profile, tap=activate, long-press "Edit" (rename/delete/admin CTA если `cachedIsAdmin`).
- Ping badges: `measureTcpLatency` (TCP connect 3 s timeout) — вызывается на screen appear для всех профилей (на Android метод есть но не вызывается — фиксим обе платформы).
- QR scanner sheet: `AVCaptureVideoPreviewLayer` fullscreen, 4-corner viewfinder 34 pt GsSignal, scanline gradient, paste-from-clipboard card. `AVCaptureMetadataOutput` type `.qr`. Первый barcode dismiss'ит sheet с результатом.
- DNS per-profile: 4 preset (Cloudflare / Google / Quad9 / AdGuard) + custom CSV, валидация IPv4.
- Split-routing: toggle + country list (ru/ua/by/kz/cn/ir), download progress, размер кэша.
- Language picker: RU / EN / System → `UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")` + alert-restart (iOS требует relaunch).
- Theme picker: Dark / Light / System → `PreferencesStore.theme` (default "dark" — retro cathode) + `.preferredColorScheme(...)`.
- Auto-start: toggle → `NETunnelProviderManager.isOnDemandEnabled` + `NEOnDemandRuleConnect`.
- Debug-share: plain-text bundle (app version, git tag, iOS ver, device, active profile, effective config, VpnState, последние 500 log lines) → `UIActivityViewController`.
- **Per-app секция удалена** (iOS физически не может).

**Admin:**
- Reachable: long-press профиля (с `cachedIsAdmin`) OR "Edit → Admin panel". Путь навигации — `NavigationLink` внутри Settings stack.
- Gateway derive: `tunAddr = X.Y.Z.W/P` → `https://X.Y.Z.1:8080`. Hostname verifier disabled. SHA-256 TOFU pin в `cachedAdminServerCertFp`.
- Client grid: список + create sheet (name + expires_days + is_admin) + delete confirm + enable/disable toggle + **is_admin toggle** (Android API есть, UI нет — iOS добавляет это и синхронно делаем на Android).
- Subscription actions: chips +30d / +90d / +365d + "Set N days" + Perpetual + Revoke.
- Client detail: conn_string → QR dialog, stats sparkline (`↓N ↑M`), destination logs top 50.
- Error banner с hint "connect via VPN first" при network errors.
- **`AdminHttpClient`** (существует, надо проверить):
  - `URLSessionDelegate.didReceive challenge`: `SecIdentity` из PEM chain + private key (EC / RSA — не Ed25519).
  - TOFU SHA-256 pin.
  - Hostname verification disabled (CN=10.7.0.1).
  - **Ed25519 rejected up-front** с понятным error banner: «Admin cert на Ed25519 — iOS Security framework не поддерживает, пере-создайте ghs:// через `phantom-keygen --key-type ecdsa`». Документируем footgun в `apps/ios/README.md`.

### Phase 10 — Localization (0.5 дня)

- `apps/ios/GhostStream/Resources/ru.lproj/Localizable.strings` — baseline (Russian скопирован из Android + новые ключи для экранов, которых на Android нет).
- `apps/ios/GhostStream/Resources/en.lproj/Localizable.strings` — английские placeholder-перевод (translator pass в конце).
- `apps/ios/Packages/PhantomKit/Sources/PhantomKit/Resources/Localizable.strings` — для `ConnState.asUiWord()` и preflight messages.
- Lint: ни одной инлайн-строки вне resources (grep-check в CI).

### Phase 11 — Validation на реальных устройствах (0.5–1 день)

**iOS (Team 7DHEYBY99N, iPhone 16 Pro Max подключён):**
```bash
cargo check --workspace
./crates/client-apple/build-xcframework.sh     # чистый artefact
cd apps/ios && xcodegen generate
xcodebuild -project GhostStream.xcodeproj -scheme GhostStream \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> ...GhostStream.app
```
Ручной smoke:
- Импорт ghs:// через QR.
- Connect к vdsina → `https://ifconfig.me` в Safari = `89.110.109.128` (NL exit).
- Disconnect / reconnect 10×.
- Wi-Fi off → on → `.reconnecting` state с countdown, восстановление.
- IPv6 killswitch: `curl -6 ifconfig.co` (через Shortcuts) → fail, нет IPv6 route.
- Logs DEBUG → поток, `ts_unix_ms` монотонно растёт.
- Admin long-press → extend subscription +30d → на сервере (`/opt/phantom-vpn/config/clients.json`) `expires_at` обновился.
- Lock screen 5 мин → unlock → tunnel alive.

**Android (Phase 4 regression):**
```bash
# Через SSH home PC tunnel (reference memory/reference_apk_build.md)
./scripts/build-apk.sh
adb install -r android/app/build/outputs/apk/debug/app-debug.apk
```
- Все 5 экранов screenshot diff vs v0.21.0 reference.
- Туннель к vdsina + ifconfig.me check.
- Reconnect loop 10×.
- Logs tab работает через новый flow-based mechanism.

**Linux:**
```bash
cargo build -p ghoststream-helper -p ghoststream-gui -p phantom-client-linux
sudo install -m 4755 target/release/ghoststream-helper /usr/bin/
cargo run -p ghoststream-gui
```
- Connect через pkexec → status frames tick, logs stream, disconnect clean.

### Phase 12 — Docs + release (0.5 дня)

- `CLAUDE.md` — переписать архитектурный раздел (client-core-runtime → TunIo abstraction), таблицу платформ (iOS = ✅ Production), раздел «Мульти-агентный workflow» дополнить iOS-зонами.
- `apps/ios/README.md` — PhantomKit package, как добавить экран, font probing note.
- `docs/architecture.md` (новый) — диаграмма + call-graph cross-platform.
- Commit log:
  1. `refactor(core): extract client-core-runtime from linux helper`
  2. `refactor(linux): helper + cli now consume client-core-runtime`
  3. `refactor(ios): apple ffi consumes client-core-runtime + gui-ipc types`
  4. `refactor(android): jni consumes client-core-runtime, listener-based stats/logs`
  5. `refactor(ios): PhantomKit local swift package`
  6. `feat(ios): PacketTunnelProvider sendProviderMessage IPC + IPv6 killswitch`
  7. `feat(ios): data layer + service layer + keychain sharing`
  8. `feat(ios): UI screens 1:1 parity with android`
  9. `feat(ios): admin panel reachable + subscription refresh + debug share`
  10. `feat(i18n): Localizable.strings RU baseline (EN placeholder)`
  11. `chore: v0.22.0 — ios client + android versionCode 56`

---

## Ключевые файлы

**Новые crates:**
- `crates/client-core-runtime/{Cargo.toml, src/lib.rs, src/telemetry.rs, src/supervise.rs, src/logsink.rs, src/tun_io.rs}`

**Изменённые Rust (полный rewrite):**
- `crates/client-apple/src/lib.rs` (~150 LOC вместо 700)
- `crates/client-android/src/lib.rs` (~180 LOC)
- `apps/linux/helper/src/linux/tunnel.rs` (~80 LOC вместо 500)
- `apps/linux/cli/src/main.rs` (~150 LOC)

**Новые Swift:**
- `apps/ios/Packages/PhantomKit/Package.swift`
- `apps/ios/Packages/PhantomKit/Sources/PhantomKit/**/*.swift` (10–15 файлов)

**Переписанные Swift:**
- `apps/ios/GhostStream/App/{GhostStreamApp, AppNavigation}.swift`
- `apps/ios/GhostStream/UI/{Dashboard, Logs, Settings, Admin, Components}/*` (~25 файлов)
- `apps/ios/PacketTunnelProvider/PacketTunnelProvider.swift`
- `apps/ios/GhostStream/Service/{VpnStateManager, VpnTunnelController}.swift`

**Новые ресурсы:**
- `apps/ios/GhostStream/Resources/{ru,en}.lproj/Localizable.strings`

**Наполнить (пустые сейчас):**
- `apps/ios/GhostStream/GhostStream.entitlements`
- `apps/ios/PacketTunnelProvider/PacketTunnelProvider.entitlements`

**Документация:**
- `CLAUDE.md`, `apps/ios/README.md`, `docs/architecture.md` (new)

---

## Переиспользование — итог

| Компонент | Источник | Используется через |
|---|---|---|
| Wire format, crypto, constants | `phantom-core` | dep |
| TLS handshake + TX/RX | `client-common::{tls_connect, tls_tx_loop, tls_rx_loop, write_handshake}` | dep |
| UI контракт | `gui-ipc::{StatusFrame, LogFrame, ConnState, TunnelSettings, ConnectProfile}` | serde verbatim на всех GUI |
| Tunnel orchestration | `client-core-runtime::run` | Linux helper, CLI, Android JNI, Apple FFI — **единый** |
| Reconnect backoff | `client-core-runtime::BACKOFF_SECS` | unified |
| Tracing → logs | `client-core-runtime::logsink::BroadcastLayer` | unified |
| `parse_conn_string` | `client-common::helpers` | FFI call на iOS и Android (убираем Kotlin-дубль `ConnStringParser.kt`) |
| `compute_vpn_routes` | `client-common::helpers` | FFI call |

---

## Явно out-of-scope

- **Per-app routing на iOS** — Apple запретила без MDM entitlement.
- **TV pairing** — отдельный проект.
- **macOS standalone** — будет `apps/macos/` после iOS стабилизации.
- **Mac Catalyst** — дубликат macOS.
- **EN полный перевод** — в v1 ключи готовы, translator pass отдельно.
- **Custom CA pinning туннеля** — используем системный trust + TOFU для admin (как на Android).

---

## Риски + mitigation

1. **Android regression** (production v0.21.0). Mitigation: Phase 4 заканчивается полным smoke-test на телефоне + screenshot diff. Merge blocker.
2. **`sendProviderMessage` rate limits** (~10–20 Hz). Fallback — `snapshot.json` в App Group + `DispatchSource.makeFileSystemObjectSource`.
3. **XCFramework Finder-дубликаты** возвращаются. `build-xcframework.sh` делает `rm -rf "$OUT"` перед генерацией + pre-commit hook чекает отсутствие `* 2.*` файлов.
4. **Ed25519 admin cert** не поддерживается iOS Security framework. Mitigation: `AdminHttpClient` отклоняет при init с error-banner «regenerate via phantom-keygen --key-type ecdsa». Документируем в `apps/ios/README.md`.
5. **Font fallback silent** (wrong PostScript → system font). Mitigation: bootstrap probe в `GhostStreamApp.init`, CI-assertion.
6. **Keychain access group недоступен extension'у** при кривых entitlements. Mitigation: Phase 0 фиксит entitlements первым делом, Phase 6 валидирует read/write из обоих процессов.
7. **`reconnect_next_delay_secs` не populated** в current `supervise()`. Mitigation: Phase 1 sets field в sleep-branch явно.
8. **cbindgen drift** C-header vs Rust FFI. Mitigation: Phase 0 integrates cbindgen в `build-xcframework.sh`, header регенерируется каждый билд.
9. **Swift 6 strict concurrency** (Task ownership, `@MainActor` across extension/app). Mitigation: `PhantomKit` явно изолирует FFI за `actor PhantomBridge`; UI ViewModels — `@MainActor`; background tasks — `nonisolated` + `Sendable`.

---

## Верификация — end-to-end

**Быстрая (без устройства):**
```bash
cargo check --workspace
cargo test -p client-core-runtime
cargo test -p client-common
cd apps/ios && xcodegen generate
xcodebuild -project GhostStream.xcodeproj -scheme GhostStream \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

**Полная (iOS device + Android device + Linux dev-host):** см. Phase 11.

**Регресс-чек (каждая платформа):**
- VPN tunnel 30 мин под нагрузкой (iperf к exit-ноде) — counter monotonic, нет memory leak.
- Reconnect loop 10× — `attempt` не утекает.
- Admin API full CRUD + subscription action все 4 варианта (`extend/set/cancel/revoke`) + `is_admin` toggle.
- Logs DEBUG — `ts_unix_ms` монотонно растёт, filter cycling работает.

---

## Estimate

| Phase | Объём |
|---|---|
| 0 — Hygiene (entitlements, bundle-id, xcframework cleanup) | 1–2 ч |
| 1 — `client-core-runtime` crate | 1–2 дня |
| 2 — Linux helper + CLI migrate | 0.5 дня |
| 3 — Apple FFI migrate | 1 день |
| 4 — Android JNI migrate + APK regression | 1 день |
| 5 — PhantomKit package | 0.5 дня |
| 6 — PacketTunnelProvider rewrite | 1 день |
| 7–8 — iOS data + service layers | 1 день |
| 9 — iOS UI (5 экранов, parity) | 2–3 дня |
| 10 — Localization | 0.5 дня |
| 11 — Validation trio | 0.5–1 день |
| 12 — Docs + release | 0.5 дня |
| **Total** | **≈10–12 рабочих дней** |

Параллелизация: после Phase 3 (Apple FFI стабилен) можно одновременно гнать 5/6/7/8 разными субагентами (Dev-Rust, Dev-iOS-Tunnel, Dev-iOS-Data, Dev-iOS-UI), ужимается до ~7 календарных дней.

