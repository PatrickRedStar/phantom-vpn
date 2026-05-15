---
updated: 2026-05-09
status: accepted
---

# 0009 — Android honest state + TSPU-resilient reconnect

## Context

Тестирование на Samsung S25 Ultra под российскими сетями (TSPU + смена
Wi-Fi/SIM/SIM на лету) обнажило 3 структурных проблемы клиента, которые
до этого скрывались за "оно вроде работает":

1. **UI лжёт**. `state="connected"` в Rust ставится один раз после H2
   handshake (`crates/client-core-runtime/src/supervise.rs:434`) и **никогда
   не пересматривается**. `streams_alive[]` сбрасывается в `false`
   только когда RX/TX loop вернулся с ошибкой — но если loop **завис**
   в `read_exact()` (типовой half-open сценарий), `alive=true` остаётся
   навсегда. Дашборд (`apps/android/.../DashboardScreen.kt`) мигает
   полосками по **таймеру**, а не от реального трафика. `VpnState` в
   Kotlin и `StatusFrameData` — два независимых потока, не
   синхронизированы. Результат: пользователь видит зелёный «Transmitting»
   неопределённо долго после того как туннель тихо сдох.

2. **Стабильность дырявая** на 4 уровнях:
   - **TLS read timeout отсутствует** — `tls_rx_loop` бесконечно ждёт
     данных. Под TSPU "silent drop" socket остаётся ESTABLISHED, read
     никогда не возвращает Err.
   - **`setUnderlyingNetworks()` не вызывается** — Android не знает на
     каком физическом интерфейсе живёт VPN; при смене Wi-Fi↔SIM может
     случиться маршрутный loop (TUN → VPN socket → VPN tunnel → TUN).
   - **DPI throttle до 128 kbit/s не детектится** — heartbeat-фрейм
     маленький, проходит, тоннель формально жив, но непригоден.
   - **Backoff `3, 6, 12, 24, 48, 60` слишком медленный** для "шатаний"
     сети — первая попытка через 3 с, при кратковременной DPI-турбулентности
     это означает 3-секундный стол визуально.

3. **Логи молчат при тихих обвалах**. ADR 0008 ввёл structured `LogFrame`
   v2 (category + fields) и tracing-pipeline на Rust, но **на Android UI
   эти данные игнорировались**: `LogFrameData` парсил только `msg + level`,
   логи хранились только в RAM (`MutableList<LogEntry>`) и пропадали при
   рестарте приложения, поиск был только по level, никакого фильтра по
   category или free-text query.

## Decision

Один большой релиз **v0.24.0** = «правда + восстановление + слышимость».
Hot failover (параллельные туннели через Wi-Fi+SIM с cutover) **отложен
в Phase 2** — это отдельный архитектурный рефакторинг `Manager`, которым
заняться имеет смысл когда первый набор изменений стабилизируется на
устройствах пользователей.

### 1. Honest state pipeline

**`crates/gui-ipc/src/lib.rs`** — `StatusFrame` расширяется
backward-compat полями (`#[serde(default)]`):

```rust
pub struct StatusFrame {
    // ... existing ...
    pub last_rx_ms: u64,            // 0 = never
    pub last_tx_ms: u64,
    pub idle_rx_secs: u32,
    pub health: TunnelHealth,        // Healthy / Stale / Degraded / Reconnecting
    pub bandwidth_class: BandwidthClass, // Normal / Throttled
}
```

**`crates/client-core-runtime/src/telemetry.rs`** в 250 ms tick:

- Стэмпит `last_rx_unix_ms` / `last_tx_unix_ms` при `bytes_rx`/`bytes_tx`
  delta > 0 (lock-free через `AtomicU64`).
- Считает `idle_rx_secs` и derive `health`:
  - `state == Connected && idle_rx_secs > 18` → `Stale`
  - `state == Connected && bandwidth_class == Throttled` → `Degraded`
- Tracks `peak_rate_rx_bps`. Если current EMA ≤ 20% × peak в течение
  warm-up (60 s+), `health = Throttled`. Hysteresis при возврате: ≥ 70%
  × peak → `Normal`. Edge changes логируются (`network.throttle.detected`
  / `network.throttle.recovered`).

**`apps/android/.../service/VpnStateManager.kt`** — новые состояния:
`Stale(idleRxSecs)`, `Throttled(currentKbps, peakKbps)`,
`Reconnecting(attempt, nextDelaySecs, lastError)`. Они материализуются
через **derived StateFlow** `derivedVpnState = combine(lifecycle,
statusFrame)`:

```kotlin
fun deriveUiState(lifecycle: VpnState, frame: StatusFrameData): VpnState =
    when {
        frame.reconnectAttempt != null && lifecycle is alive ->
            Reconnecting(...)
        lifecycle is Connected && frame.health == STALE ->
            Stale(idleRxSecs = frame.idleRxSecs)
        lifecycle is Connected && frame.health == DEGRADED ->
            Throttled(currentKbps = ..., ...)
        ...
    }
```

DashboardScreen потребляет `derivedVpnState`. Полоски multiplex мигают
**только** когда `statusFrame.rateRxBps > 0` (реальный live трафик).
Timer продолжает идти через Stale/Throttled (одна сессия) — но окрашен
в `C.warn`/`C.danger`. Stop FAB активен во всех "tunnel up-ish"
состояниях.

### 2. Resilience: TLS read timeout + bound network + tuned backoff

**`crates/client-common/src/tls_tunnel.rs`** — `tls_rx_loop` принимает
`idle_timeout: Option<Duration>`. Header и body `read_exact` обёрнуты в
`tokio::time::timeout`. При срабатывании — лог
`tracing::warn!(category="network", event="rx.idle_timeout")` и
`Err("rx idle timeout: no data for Ns")`, поднимается до
`drive_tunnel` → штатный reconnect. Runtime использует
`RX_IDLE_TIMEOUT_SECS = 45`. OpenWrt CLI остаётся на `None` (legacy).

**`crates/client-core-runtime/src/lib.rs`** — новые public-API:

```rust
pub const RX_IDLE_TIMEOUT_SECS: u32 = 45;
pub const BACKOFF_SECS: &[u32] = &[1, 2, 5, 10, 20, 30, 30, 30];

pub enum TunnelErrorCategory {
    HardReset, IdleTimeout, NetworkUnreachable, TlsAlert, DnsFailed, Other,
}
pub fn classify_tunnel_error(s: &str) -> TunnelErrorCategory { ... }
pub fn reconnect_delay_secs(cat: TunnelErrorCategory, attempt: u32) -> u32 { ... }
```

`should_reconnect` принимает `last_error_str` и подменяет таблицу backoff'а
на per-category override: HardReset→1s, IdleTimeout→2s, TlsAlert→5s,
NetworkUnreachable→60s (ждём NetworkCallback wake), Other→табличный
`BACKOFF_SECS`.

**`apps/android/.../service/GhostStreamVpnService.kt`** —
`applyUnderlyingNetworks(reason: String)` вызывается:

- сразу после `Builder().establish()`
- из каждого callback `NetworkCallback` (`onAvailable` / `onLost` /
  `onCapabilitiesChanged`)

Выбирает `activeNetwork` с capability `INTERNET + NOT_VPN`, fallback на
`allNetworks.firstOrNull{...}`. Лог `Сеть: Wi-Fi/N123 (onAvailable)` в
LogsScreen для дебага.

### 3. Logs: parse + persist + search + structured render + export

**`VpnStateManager.LogFrameData`** парсит category + fields (`BTreeMap`
в JSON → `Map<String, String>`).

**`LogsViewModel`** теперь:

- хранит persistent rotating ring buffer в `filesDir/logs/`
  (`ghoststream.log` + до 5 rotated `.0..4`, 2 MB каждый)
- replay'ит активный файл при старте — пользователь видит контекст
  предыдущей сессии
- track'ит `availableCategories` (set заполняется по факту прихода
  framed events)
- три фильтра: level / category / free-text search query
- `shareLogs` собирает ВСЕ файлы (active + rotated) в один .txt и шарит
  через `FileProvider`

**`LogsScreen`** — добавлены:

- search box (BasicTextField) — substring case-insensitive по `msg /
  category / fields`
- category chip row (видна только если есть category events)
- per-row expandable fields rendering: row с `fields != null` кликабелен,
  раскрывается в таблицу k=v
- category badge перед сообщением

### 4. What's NOT in v0.24.0 (Phase 2)

- **Hot failover** — параллельные туннели через Wi-Fi + SIM с
  zero-downtime cutover. Требует рефакторинга `Manager` в `supervise.rs`
  на multi-tunnel + `TunPacketRouter` + JNI методы
  `nativeStartSecondary` / `nativeCutoverToSecondary`. Cutover criteria
  (Secondary reached Connected ∧ bytes_rx>0 ∧ Primary stale|lost) тоже
  отложены. Для текущего пользователя value: при смене сети сейчас будет
  reconnect через 1-2 с (новый backoff + idle timeout), без hot failover.
- **`Network.bindSocket()`** — explicit bind TCP socket на конкретный
  Android Network до `connect()`. Эта часть едет вместе с hot failover,
  потому что осмысленна только когда есть две одновременных сети.

## Consequences

**Плюсы:**

- UI **не лжёт**. Stale/Throttled/Reconnecting видно явно с цветом и
  таймером.
- Half-open zombie ломается за **45 с** вместо нескольких минут.
- TSPU shaping (128 kbit/s) детектируется и показывается как
  `Throttled` — пользователь понимает что сеть жива, но непригодна.
- Reconnect под кратковременную DPI-турбулентность теперь начинается
  через 1-5 с вместо 3-12 с — субъективно ощущается как «не отвалилось».
- Логи **переживают** перезапуск, ищутся, фильтруются по category, FieldS
  раскрываются. Саппорт-разбор реальных инцидентов становится
  возможен.

**Минусы / tradeoffs:**

- Wire format `StatusFrame` расширяется на 5 полей. Старые потребители
  (iOS/Linux/macOS) видят их через `#[serde(default)]` — поведение
  совместимо. Все шинают через тот же `gui-ipc` crate, breaking changes
  невозможны.
- Persistent log на диск ~~ 2 MB × 5 = до 10 MB постоянного storage.
  Очищается при `Clear`.
- Telemetry tick тяжелее на ~50 ns (атомарные store + derivation). Нагрузка
  ничтожна.
- `tls_rx_loop` сигнатура изменилась — каскад на OpenWrt (`tls_rx_loop(r,
  sink, None)`).

**Что закрывает:**

- "UI пишет connected, а интернета нет" — самый частый user complaint.
- Зомби-туннель после смены сети.
- "Что-то странное, логов нет" — теперь есть и они переживают рестарт.

**Что открывает:**

- Phase 2: hot failover на двух сетях одновременно (downtime ~0).
- Future: серверная агрегация `throttle.detected` событий → backbone
  для adaptive SNI/relay routing.

## References

- StatusFrame: `crates/gui-ipc/src/lib.rs::StatusFrame`
- Health derivation: `crates/client-core-runtime/src/telemetry.rs::derive_health`,
  `derive_bandwidth_class`
- TLS timeout: `crates/client-common/src/tls_tunnel.rs::tls_rx_loop`
- Error categorisation: `crates/client-core-runtime/src/lib.rs::TunnelErrorCategory`
- Underlying networks: `apps/android/.../GhostStreamVpnService.kt::applyUnderlyingNetworks`
- UI honesty: `apps/android/.../service/VpnStateManager.kt::deriveUiState`,
  `apps/android/.../ui/dashboard/DashboardScreen.kt`
- Logs persistence: `apps/android/.../ui/logs/LogsViewModel.kt`,
  `apps/android/.../ui/logs/LogsScreen.kt`
- Связан с: ADR [0007](0007-macos-statusframe-passthrough.md),
  ADR [0008](0008-verbose-debug-observability.md),
  ADR [0005](0005-client-core-runtime.md).
- Не закрывает: hot failover, `Network.bindSocket()` — отдельный ADR
  для Phase 2.
