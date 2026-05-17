---
updated: 2026-05-09
status: accepted
---

# 0008 — Verbose debug observability: structured logging для каждого микро-события

## Context

После реализации ADR 0007 (StatusFrame pass-through на macOS) выяснилось,
что текущая система логирования крайне бедная:

- `crates/client-core-runtime/` использует `tracing` крейт, но фильтр по
  умолчанию подавляет всё ниже INFO.
- `crates/client-apple/` FFI имеет `onLog` callback, но в Rust почти
  никто его не использует — большинство событий жизненного цикла туннеля
  проходят без следа.
- `apps/macos/PacketTunnelExtension/` хранит ring buffer `recentLogFrames`
  размером 200 — теряет события при любом интенсивном дебаге.
- UI `Logs` tab показывает плоский список без фильтров, без поиска,
  без категорий.
- Файлового лога нет — нечего скормить LLM-агенту для разбора инцидента.

При smoke-тесте v0.23.3 пользователь не смог объяснить «бары моргают на
8 streams на микросекунду» — потому что логов с такой гранулярностью
не существует. Каждое расследование = живая сессия с пользователем,
который просит «сделай чтобы я не усирался в объяснениях».

## Decision

**Каждое микро-событие в системе должно генерировать структурный
`LogFrame` со временем (микросекунды), уровнем, категорией, сообщением
и опциональным набором key-value полей. Все события идут через единый
pipeline `tracing` (Rust) → `LogFrame` (gui-ipc) → Provider ring buffer
→ файл + UI.**

Главный потребитель этих логов — LLM-агент (Claude), вторичный —
разработчик в realtime через UI.

### 1. Wire format `LogFrame` v2 (`crates/gui-ipc/src/lib.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LogFrame {
    /// Legacy millisecond timestamp. Кept for backward compat with v1
    /// consumers; new code reads `ts_unix_us` when present.
    pub ts_unix_ms: u64,

    /// Microsecond Unix timestamp. New in v2. Defaults to
    /// `ts_unix_ms * 1000` if absent (handled in deserializer).
    #[serde(default)]
    pub ts_unix_us: u64,

    /// "ERR" / "WRN" / "INF" / "DBG" / "TRC". Case-sensitive 3-char.
    pub level: String,

    /// Free-form human-readable message. Required.
    pub msg: String,

    /// Logical category. New in v2. One of:
    /// "tunnel", "handshake", "stream", "packet", "telemetry", "tun",
    /// "ipc", "settings", "runtime", "ffi". `None` = uncategorized.
    #[serde(default)]
    pub category: Option<String>,

    /// Structured fields. New in v2. Small map (<10 entries typical),
    /// stringified values (`u64` → "1234", `bool` → "true").
    #[serde(default)]
    pub fields: Option<std::collections::BTreeMap<String, String>>,
}

impl LogFrame {
    /// v2 constructor. Existing `LogFrame::now` continues to work as v1.
    pub fn structured(
        level: &str,
        category: &str,
        msg: impl Into<String>,
        fields: impl IntoIterator<Item = (String, String)>,
    ) -> Self { ... }
}
```

Backward compat: старые consumers видят `ts_unix_ms` + `level` + `msg`,
новые поля игнорируют. Новые consumers читают всё.

### 2. Канонические события (Rust core)

Все события в системе должны соответствовать нижеуказанному списку.
Новые добавлять — только через PR + обновление этого ADR.

| Category | Event | Level | Поля (`fields`) |
|---|---|---|---|
| `tunnel` | `start` | INF | `profile_id`, `server`, `sni`, `streams` |
| `tunnel` | `connected` | INF | `session_id`, `negotiated_streams` |
| `tunnel` | `disconnect` | INF | `reason` |
| `tunnel` | `error` | ERR | `phase`, `error` |
| `tunnel` | `reconnect.scheduled` | WRN | `attempt`, `delay_secs` |
| `tunnel` | `reconnect.attempt` | INF | `attempt` |
| `tunnel` | `reconnect.giveup` | ERR | `attempts`, `last_error` |
| `handshake` | `tcp.connect` | DBG | `peer`, `local` |
| `handshake` | `tls.client_hello` | DBG | `sni`, `alpn` |
| `handshake` | `tls.alpn_negotiated` | DBG | `proto` |
| `handshake` | `mtls.cert_verify` | DBG | `result`, `subject` |
| `handshake` | `h2.settings_sent` | DBG | `max_concurrent`, `initial_window` |
| `handshake` | `h2.settings_acked` | DBG | — |
| `handshake` | `h2.ready` | INF | `n_streams_open` |
| `stream` | `open` | DBG | `stream_id`, `priority` |
| `stream` | `first_packet_tx` | TRC | `stream_id`, `bytes` |
| `stream` | `first_packet_rx` | TRC | `stream_id`, `bytes` |
| `stream` | `idle_threshold` | TRC | `stream_id`, `idle_ms` |
| `stream` | `close` | DBG | `stream_id`, `reason`, `lifetime_ms` |
| `stream` | `kill` | WRN | `stream_id`, `error` |
| `packet` | `tx.batch` | TRC | `n_pkts`, `bytes` (sampled 1/N) |
| `packet` | `rx.batch` | TRC | `n_pkts`, `bytes` (sampled 1/N) |
| `telemetry` | `publish` | TRC | `n_streams`, `streams_up`, `rate_rx_bps`, `rate_tx_bps` |
| `tun` | `created` | INF | `name`, `mtu`, `addr` |
| `tun` | `torn_down` | INF | `name` |
| `ipc` | `request` | DBG | `op` |
| `ipc` | `response` | DBG | `op`, `status` |
| `settings` | `profile.loaded` | INF | `name`, `server`, `sni` |
| `settings` | `routes.computed` | INF | `direct_n`, `vpn_n` |
| `runtime` | `shutdown.start` | INF | — |
| `runtime` | `shutdown.complete` | INF | `duration_ms` |
| `ffi` | `callback.status` | TRC | `state`, `n_streams`, `streams_up` |
| `ffi` | `callback.log` | (само событие) | — |

**Sampling**: `packet.tx.batch` и `packet.rx.batch` — 1 из 100 (default,
конфигурируемо через env `GHOSTSTREAM_PACKET_LOG_SAMPLE=N`).

### 3. Уровни и гейтинг

Уровни (от менее к более verbose):

| Level | str | OSLog | Когда |
|---|---|---|---|
| Error | "ERR" | `.error` | Видимая для пользователя ошибка / fatal |
| Warn | "WRN" | `.error` | Аномалия, но recovery возможен |
| Info | "INF" | `.info` | Lifecycle event, видимый для оператора |
| Debug | "DBG" | `.debug` | Внутреннее состояние, нужно для разбора инцидента |
| Trace | "TRC" | `.debug` | Каждое микро-событие (packet, telemetry tick) |

Гейтинг через приоритет (**первое совпадение побеждает**):

1. **env `GHOSTSTREAM_LOG`** — стандартный `tracing_subscriber::EnvFilter`
   формат, например `info,client_core_runtime=trace`.
2. **UserDefaults `verboseLog: Bool`** — toggle в Settings → Advanced.
   `true` ⇒ TRACE для всех categories, `false` ⇒ INFO+.
3. **Build config default**:
   - Debug build: `info,client_core_runtime=debug,client_common=debug`
   - Release build: `info`

`tracing` crate выполняет фильтрацию **до** evaluation полей — выключенный
TRACE имеет нулевой overhead на hot path.

**Known limitation** (post-architect review): `client-apple::apply_log_filter`
вызывает `logsink::set_level(spec)` для **bare** spec ("trace" / "debug" /
"info" / "warn" / "error"). Default debug spec
(`"info,client_core_runtime=debug,client_common=debug,..."`) под условие
не попадает — он применяется только при первом `init()` и не reload'ится.
В практике это безопасно: macOS NEPacketTunnelProvider убивается между
`stopTunnel` и `startTunnel`, так что фильтр всегда инициализируется
заново. Если в будущем потребуется реактивно менять filter без рестарта
extension'а — нужен `EnvFilter` reload через `tracing_subscriber::Handle`.

Также: `std::env::set_var("RUST_LOG", spec)` в `apply_log_filter`
безопасно только пока крейт на edition 2021. Edition 2024 переведёт
эту операцию в `unsafe` (race с другими потоками, читающими `getenv`).
Текущая реализация полагается на то, что singleton runtime ставится
один раз и потом не меняется.

### 4. Файловый лог

Путь: **App Group container** —
`~/Library/Group Containers/group.com.ghoststream.client/Logs/runtime.log`.

Это **единственный** путь — host UI (SettingsView, TailView reveal-
buttons) и extension `LogFileWriter` оба резолвят через
`PhantomKit.LogPathResolver.defaultRuntimeLogURL()`. NEPacketTunnelProvider
запускается как root, и `~/Library/Logs/...` от него ведёт в
`/var/root/Library/Logs/` — невидимо пользователю. App Group container
доступен и юзеру, и root по одному пути.

Fallback'и (только если App Group по какой-то причине недоступен):
1. `~/Library/Logs/GhostStream/` (user-domain library) — для host app OK,
   из extension всё равно root home.
2. `$TMPDIR/GhostStream/` — последний fallback.

Формат: NDJSON (одна `LogFrame`-сериализация в JSON на строку).

Ротация: при первом write нового дня старый файл переименовывается в
`runtime.log.YYYY-MM-DD`, новый создаётся пустым. Хранятся последние 7
файлов, остальные удаляются.

Размер: capped at 100 MB (current day). При превышении — текущий файл
переименовывается в `runtime.log.YYYY-MM-DD.N` (N инкрементируется),
новый создаётся.

Writer — в Provider, на отдельной serial DispatchQueue (не блокирует
runtime callback).

Этот файл — **главный артефакт для отдачи Claude**. Юзер делает
`tail -n 1000 ~/Library/Logs/GhostStream/runtime.log` или жмёт «Export
last 5 minutes» в UI и пейстит мне.

### 5. Provider (Swift)

Изменения в `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift`:

- `recentLogFrames` ring buffer **10 000** (было 200).
- При получении LogFrame через FFI `onLog`:
  1. Append в ring buffer (под `runtimeStateLock`).
  2. Записать в OSLog с правильной category и level (mapped).
  3. Записать в `runtime.log` через `LogFileWriter` (новый класс).
- Добавить state-only события самим Provider'ом: `start`, `connected`,
  `disconnect` (с `reason`) — чтобы UI/файл видел Swift-side тоже.

Новый файл `apps/macos/PacketTunnelExtension/LogFileWriter.swift`:
serial queue + daily/size rotation + NDJSON encoding.

### 6. App UI — Logs tab (`apps/macos/GhostStream/UI/Logs/TailView.swift`)

Текущий TailView расширяется до полноценной log-viewer'а:

- **Header**: search input, level dropdown (≥ERR / ≥WRN / ≥INF / ≥DBG /
  ≥TRC), category multi-select (chip-style), follow-tail toggle, pause
  toggle.
- **List**: Lazy VStack рендерит до 5000 видимых rows. Каждая row —
  `[HH:MM:SS.mmm] [LVL] [category]` `<msg>` `{key=val key2=val2}`.
  - Click on row → копирует JSON в clipboard.
  - Hover → подсветка.
  - Цвет по level (ERR/WRN — оранжевый/красный, INF — bone, DBG —
    textDim, TRC — textFaint).
- **Footer**: Counters (N events, M filtered), Copy Selected, Export
  to file (saves last 5 min as NDJSON to ~/Downloads/), Clear (wipes
  ring buffer + file? — no, just buffer), Reveal Log File in Finder.
- **Auto-scroll**: если `follow tail = on`, новый event → scroll to
  bottom. Если юзер скроллит вверх вручную → follow auto-pauses.

### 7. Settings UI

Новая секция в `apps/macos/GhostStream/UI/Settings/SettingsView.swift`
"Advanced":

- Toggle "Verbose logging (TRACE level)". Persist в `PreferencesStore`
  под ключом `verboseLog`. Подсказка: "Records every packet batch and
  micro-event. Adds ~10 MB/min to ~/Library/Logs/GhostStream/. Reduce
  if disk-constrained."
- Кнопка "Reveal log file in Finder" → `NSWorkspace.shared.activateFileViewerSelecting(...)`.
- Кнопка "Open log directory" → `~/Library/Logs/GhostStream/`.

UserDefaults `verboseLog` читается Provider'ом при старте — пробрасывается
в Rust runtime через FFI (новый параметр в start payload или env override).

### 8. Performance constraints

- **Hot path overhead** при `verboseLog=false`: < 0.1% (только level
  check, без allocation). Достигается за счёт `tracing::enabled!` macro.
- **TRACE on**: ожидаемо ~10 MB/min лог-файл, ~5% CPU overhead — допустимо
  для дебага.
- File writer **никогда** не блокирует runtime callback — append
  всегда non-blocking через DispatchQueue.async.
- Ring buffer overflow → drop oldest (FIFO), never block producer.

### 9. Cross-platform

В этом ADR реализуется **только macOS**. iOS использует тот же
`crates/client-apple/` — FFI и Rust runtime изменения автоматически
получит при следующей iOS-сборке. UI в iOS — отдельная задача
(не входит в этот ADR).

Android (`crates/client-android/`) и Linux GUI получат аналогичную
систему отдельным ADR — JNI callback и Linux file path требуют отдельной
работы.

## Alternatives considered

1. **Использовать только OSLog без файла**: отклонено. OSLog требует
   `log show --predicate ...` для извлечения, формат не NDJSON, не
   удобно скармливать LLM. Файл проще копировать/пейстить.

2. **Внешний log aggregator (Sentry / Datadog)**: отклонено. Privacy-
   sensitive (VPN), нужно полное локальное логирование. Aggregator
   — отдельная задача после.

3. **Только увеличить `recentLogFrames` до 10k без файла и UI-фильтров**:
   отклонено. Юзер не сможет скопировать 10k строк в чат, и без
   фильтров найти нужное событие нереально.

4. **Расширить wire format несовместимо (LogFrame v2 как новая структура)**:
   отклонено. Backward compat через `#[serde(default)]` дешевле и не
   ломает Linux/Android клиенты, которые пока не получают новых полей.

5. **Сделать packet logging без sampling**: отклонено. На 100 Mbit/s
   получается 50k packet/sec, лог-файл вырастет до GB за минуту.
   Sampling 1/100 даёт нормальную картину при разумном размере.

## Consequences

**Плюсы:**
- LLM-агент получает полный сценарий инцидента из одного `tail -n N`.
- Каждое микро-изменение наблюдаемо: handshake stages, per-stream
  lifecycle, telemetry ticks, packet batches.
- UI становится debug-инструментом: фильтры, follow tail, экспорт.
- Файловый лог — артефакт для постмортемов.
- Backward compat — Linux/Android не ломаются.

**Минусы / tradeoffs:**
- ~150-300 строк нового кода в Rust + Swift.
- Verbose ON = 10 MB/min disk write. Достаточно agressive rotation.
- Performance overhead 0% off / 5% on — приемлемо.
- Wire format расширяется: новые поля — потенциал serialization drift
  в будущем (мы знаем все позиции).

**Что закрывает:**
- Расследование UI-багов теперь можно делать офлайн (логи + ADR).
- «Логи хуёвые» как user complaint.

**Что открывает:**
- Auto-postmortem: если runtime crash'ится с `tunnel.error` — в файле
  есть полный путь к ошибке.
- Future: send subset of logs to server-side analytics (после opt-in).

## References

- Wire format: `crates/gui-ipc/src/lib.rs::LogFrame`
- Producer (tracing): `crates/client-core-runtime/`, `crates/client-common/`
- FFI: `crates/client-apple/src/lib.rs::onLog`
- Provider: `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift`,
  `apps/macos/PacketTunnelExtension/LogFileWriter.swift` (new)
- UI: `apps/macos/GhostStream/UI/Logs/TailView.swift`,
  `apps/macos/GhostStream/UI/Settings/SettingsView.swift`
- Связан с: ADR [0007](0007-macos-statusframe-passthrough.md)
  (общий source of truth — runtime), ADR [0005](0005-client-core-runtime.md)
  (унифицированный runtime).
- Не закрывает: Android/iOS UI, RTT measurement (отдельные ADR).
