---
updated: 2026-04-17
status: accepted
---

# 0005 — Унифицированный tunnel runtime через `client-core-runtime`

## Context

До v0.22 каждый клиент (android / linux / apple) имел **свой собственный
оркестратор** — копипаст ~600 строк Rust на платформу:

- handshake по [wire format](../architecture/wire-format.md)
- telemetry (EMA RX/TX bps, RTT, attempt counter)
- supervise FSM (backoff, max attempts, exit policy)
- log broadcast (ring buffer + listener)
- TX/RX loops (batched packet IO в TUN)

Последствия дублирования:

- **Дрейф логики.** iOS получал фичи позже, Android и Linux — в разное время.
  Telemetry формулы различались (разные EMA alpha).
- **Баги чинились трижды.** Один и тот же race (например, supervise не
  снимал pending reconnect при manual disconnect) ловился на Android, фикс
  портировался на Linux через неделю, на iOS — через месяц.
- **Тестирование.** Каждая платформа нуждалась в отдельных integration
  tests для одних и тех же сценариев.

К моменту Phase 12 (iOS full parity) стало невозможно продолжать без
унификации — iOS требовал +400 строк нового "оркестрационного" кода, а это
четвёртая копия того же самого.

## Decision

Извлечь **`crates/client-core-runtime`** — единый async runtime для всех
клиентов:

```rust
pub async fn run(
    cfg: RuntimeConfig,
    tun: TunIo,
    settings: TunnelSettings,
    status_tx: broadcast::Sender<StatusFrame>,
    log_tx: broadcast::Sender<LogFrame>,
) -> Result<ExitReason>
```

Различия платформ вынесены в **enum `TunIo`**:

- `Uring(RawFd)` — Linux, io_uring для zero-copy batched IO
- `BlockingThreads(RawFd)` — Android, blocking read/write threads через JNI
- `Callback(Arc<dyn PacketIo>)` — iOS, packet flow через
  `NEPacketTunnelProvider` callback

**Канонические wire types** — `StatusFrame`, `ConnState`, `LogFrame`,
`TunnelSettings`, `ConnectProfile` — живут в `crates/gui-ipc` и используются
**всеми тремя** клиентскими крейтами (android / apple / linux).

Консолидация по фазам:

- `1b5266c` — extract `client-core-runtime` (Phase 1)
- `aeb1fde` — linux migration (Phase 2)
- `8753a8f` — apple migration (Phase 3)
- `7f44240` — android migration (Phase 4)
- `6b7c00a` — v0.22.0 consolidation, iOS feature parity (2026-04-17)

## Alternatives considered

1. **Trait-based abstraction с одной backend функцией.** Отклонено: generics
   раздувают compile time (особенно Android, где каждый target — monomorphized
   копия). FFI overhead при передаче generic type через cbindgen / UniFFI —
   нетривиальный.

2. **Keep duplication, share via copy-paste + линтер.** Отклонено: любой
   линтер детектирует **что** скопировано, но не гарантирует что при изменении
   всё обновят. Дрейф неизбежен через 2-3 коммита.

3. **Переписать всё на async trait + `dyn`-диспатч в hot path.** Отклонено:
   iOS не любит dynamic dispatch в TX/RX hot loop (measured 5-7% регрессия
   latency в early prototype). Компромисс — `Arc<dyn PacketIo>` только на
   iOS через `TunIo::Callback`, где это уже оправдано системой (NEPacketTunnel
   сам callback-based).

## Consequences

**Плюсы:**
- **Одна реализация telemetry** — 250ms tick, EMA α=0.35, одна формула для
  всех платформ. StatusFrame канонический (см.
  [../architecture/wire-format.md](../architecture/wire-format.md)).
- **Одна FSM `supervise`** — BACKOFF=[3,6,12,24,48,60,60,60], 8 attempts,
  одинаковый exit policy (manual disconnect → не reconnect, crash →
  reconnect).
- **Push-based listener pattern** — Android через JNI
  `PhantomListener.onStatusFrame` / iOS через FFI callbacks. Нет poll
  loop'а в UI, нет polling overhead.
- **Linux GUI и CLI идентичны** — одна и та же функция `run()`, только
  презентация разная.
- **iOS feature parity с Android** (v0.22.0) — split routing, admin, logs,
  telemetry работают одинаково.

**Минусы / tradeoffs:**
- **`Arc<dyn PacketIo>` на iOS** — ~3% virtual call overhead в TX path
  (measured vs inline). Acceptable, система всё равно callback-based.
- **Любой баг в core-runtime сразу ломает 3 платформы.** Плюс: ломает
  одинаково (не randomly), и фиксится один раз. Минус: нужна более
  аккуратная CI — integration tests на Linux обязательны перед releasom на
  Android / iOS.
- **FFI код на apple + android теперь тонкий** — считай thin glue.
  Понимать FFI отдельно уже не особо смысл, любой новый разработчик
  начинает сразу с core-runtime.

**Что открывает:**
- **Следующие платформы почти бесплатно.** Windows wintun — нужен
  `TunIo::Wintun(HANDLE)`. macOS network extension (отдельное от iOS) —
  reuse `TunIo::Callback`. OpenWrt — уже на Linux через
  `TunIo::BlockingThreads` (io_uring не везде доступен).
- **Фичи автоматически cross-platform.** Split routing, custom DNS,
  killswitch — пишется один раз в core-runtime, видна всем клиентам.

**Что закрывает:**
- Platform-specific оркестрация ≠ норма. Новый код для конкретной платформы
  допустим только в `TunIo` adapter слое или в UI. Логика connect /
  supervise / telemetry / logging — только в core-runtime.

## References

- Commits:
  - `1b5266c` — extract `client-core-runtime` (Phase 1)
  - `aeb1fde` — linux migration (Phase 2)
  - `8753a8f` — apple migration (Phase 3)
  - `7f44240` — android migration (Phase 4)
  - `6b7c00a` — v0.22.0 consolidation (2026-04-17)
- Связанные крейты: `crates/client-core-runtime/`, `crates/gui-ipc/`,
  `crates/client-{android,apple,linux}/`
- Связанная архитектура: [../architecture/transport.md](../architecture/transport.md),
  [../architecture/wire-format.md](../architecture/wire-format.md)
- Связанные платформы: [../platforms/ios.md](../platforms/ios.md),
  [../platforms/android.md](../platforms/android.md),
  [../platforms/linux.md](../platforms/linux.md)
