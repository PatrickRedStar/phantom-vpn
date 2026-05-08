---
updated: 2026-05-09
status: accepted
---

# 0007 — macOS PacketTunnel должен пробрасывать StatusFrame от runtime, а не строить свой

## Context

На macOS `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift` имел **два независимых пути публикации `StatusFrame`** в shared snapshot, который читает GUI:

1. **Runtime callback** ([provider:200](../../../apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift)) — `onStatus(frame)` от Rust FFI (`crates/client-apple/src/lib.rs:186-197` → JSON → Swift). Источник — `client-core-runtime::telemetry::spawn_telem_task` (250 мс tick): `bytes_*`, EWMA `rate_*_bps` в **bits/sec** (α=0.35), реальный `streams_up`, per-stream activity с floor 0.12.

2. **Provider 1-Hz таймер** (`startProviderTelemetryLoop` + `makeProviderStatusFrame`) — каждую секунду перезаписывал кадр своими значениями: `rttMs: nil`, `streamsUp = streamCount` (из профиля), `streamActivity` — одинаковый float для всех стримов, `rate_*_bps` — сырая дельта **bytes/sec без EWMA**.

В shared `lastStatusFrame` побеждал последний writer. Видимые баги (скриншот пользователя 2026-05-09):

- `MUX · STREAMS 10 ↑ 10` — `streamsUp == nStreams` всегда (фейк, не отражает поднятые стримы).
- 8 баров S01..S08 при N≠8 — `barCount: 8` и `ForEach(1...8)` захардкожены в `DashboardView.swift`.
- `RTT —` — `rttMs: nil` захардкожен в provider'е (RTT никем не считается; out of scope).
- `RX/TX` скакал и был **в 8× меньше реального** — двойная проблема: (а) сырая дельта без EWMA, (б) контракт `gui-ipc::StatusFrame::rate_*_bps` это bits/sec, а UI делил `/1024` сразу как будто bytes/sec.

## Decision

**Источник истины — Rust runtime telemetry.** PacketTunnelExtension прекращает строить собственный `StatusFrame` для `.connected` состояния. Конкретно:

1. Удалены в `PacketTunnelProvider.swift`: `startProviderTelemetryLoop`, `makeProviderStatusFrame`, `publishProviderStatusFrame`, `providerStreamCount`, `addRxBytes`/`addTxBytes`, `resetProviderTelemetry` + 11 telemetry properties и `telemetryLock`. Все callsite `addRxBytes/TxBytes` (в `onInbound` и `outboundLoop`) тоже удалены.
2. Введён `makeStateOnlyFrame(state:profile:)` — минимальный кадр для `.connecting/.reconnecting/.error/.disconnected`: только `state`, `tunAddr`, `serverAddr`, `sni`, `lastError`. Telemetry в нулях/nil.
3. UI fix: `barCount` биндится к `frame.nStreams` через `TelemetryDisplayHelpers.barCountFromStreams(_:)` (clamp 1..16), `ForEach` — динамический. Сделано и в `DashboardView.swift`, и в `MenuBarPopover.swift`.
4. bits→bytes конверсия: новый pure-helper `TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(_:)` (sanitize + `/8`) применяется **один раз** в точке потребления — в `TrafficSeriesStore.resolvedRate` и в Dashboard/MenuBar fallback `displayRx/TxRateBps`. `splitRate`/`formatRate` оставлены как есть (получают bytes/sec, делят на 1024). Wire format остаётся в bits/sec.
5. Минимальный рефакторинг runtime: извлечены `pub(crate) compute_ema(prev, inst, alpha)` и `pub(crate) compute_activity(deltas, alive)` для unit-тестируемости, поведение bit-exact идентично.
6. **Bonus fix** — обнаружен и пофикшен старый continuation-leak в `outboundLoop()`. Прежний код использовал `withCheckedContinuation` без cancellation handler: при `outboundTask.cancel()` (любой stopTunnel) `packetFlow.readPackets` не имел способа быть отменённым, continuation никогда не resume'ился, Swift логировал `SWIFT TASK CONTINUATION MISUSE: outboundLoop() leaked its continuation`. Leak оставлял extension в полу-зависшем состоянии — последующие `startTunnel` requests блокировались. Переписано на `AsyncStream<[Data]>`: `for await` корректно прерывается на cancel, поздние callback'и `readPackets` становятся no-op через `continuation.yield(...) == .terminated`. Не входит в формальный scope ADR, но непосредственно мешал валидации и затрагивал тот же файл — попал в этот же релиз.

Принято и внедрено в commit `<TBD>` (v0.23.3 build 14, 2026-05-09).

## Alternatives considered

1. **Оставить provider-телеметрию как fallback на случай зависшего runtime callback.** Отклонено: за 6 месяцев работы такого кейса не было; race с runtime создавал реальные UI-баги *прямо сейчас*. Если потребуется watchdog — отдельный механизм с явным `.error` переходом.

2. **`barCount = max(8, nStreams)` — всегда минимум 8 ради эстетики.** Отклонено: пустые бары вводят в заблуждение. Если у пользователя 1 поток — пусть видит 1.

3. **Поправить bits-vs-bytes в Rust runtime (`* 8.0` → `/ 8.0`).** Отклонено: сломает Linux/Android, контракт IPC ясно говорит bits/sec. Чинить на стороне UI.

4. **Объединить с RTT-имплементацией.** Отклонено: RTT требует H2 PING-frame measurement в `client-common`, ~неделя работы. Этот ADR — узкая, дешёвая правка. RTT — отдельный ADR.

## Consequences

**Плюсы:**
- Один источник правды — runtime telemetry, та же реализация что на Linux/Android (consistency).
- Реальные значения `streamsUp` (показывает поднятые vs целевые при handshake/reconnect).
- Per-stream activity bars двигаются по-разному — видно нагруженный стрим vs idle.
- Бары ≡ количество потоков, нет «фантомных» S05–S08 при N=4.
- ~150 строк удалённого provider-кода.
- Цифры RX/TX больше не врут в 8 раз и не дрожат на каждом тике.

**Минусы / tradeoffs:**
- Если Rust runtime callback падает молча — UI замораживается на последнем кадре. Митигация: `.disconnected/.error` приходят от системы (NETunnelProvider events), пользователь увидит обрыв.
- Runtime telemetry tick = 250 мс — в 4× чаще чем provider 1Hz. Нагрузка незначительная (atomics + EMA), проверено в Validator.

**Что закрывает:**
- Провайдер больше не строит «свою телеметрию» — единая модель.

**Что открывает:**
- Чистый путь добавить `rtt_ms` в Rust runtime — UI уже готова потреблять.
- iOS Dashboard может переиспользовать те же `TelemetryDisplayHelpers` (PhantomKit shared между apple-платформами).

## References

- Связанные файлы (Swift): [PacketTunnelProvider.swift](../../../apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift), [DashboardView.swift](../../../apps/macos/GhostStream/UI/Dashboard/DashboardView.swift), [MenuBarPopover.swift](../../../apps/macos/GhostStream/UI/MenuBar/MenuBarPopover.swift), [TrafficSeriesStore.swift](../../../apps/macos/GhostStream/Service/TrafficSeriesStore.swift)
- Новый shared helper: `apps/ios/Packages/PhantomKit/Sources/PhantomKit/Models/TelemetryDisplayHelpers.swift`
- Wire format (не изменён): [crates/gui-ipc/src/lib.rs](../../../crates/gui-ipc/src/lib.rs)
- Producer (не изменён по поведению): [crates/client-core-runtime/src/telemetry.rs](../../../crates/client-core-runtime/src/telemetry.rs)
- FFI (не изменён): `crates/client-apple/src/lib.rs:102-197`
- Связан с: ADR [0005](0005-client-core-runtime.md) (унифицированный runtime), ADR [0006](0006-layered-macos-vpn-routing.md) (macOS routing)
- Не закрывает: RTT measurement (отдельный ADR будет)
