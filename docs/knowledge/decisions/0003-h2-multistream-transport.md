---
updated: 2026-04-17
status: accepted
---

# 0003 — H2/TLS reliable streams с мульти-стрим шардингом

## Context

В early design транспортом были **QUIC unreliable datagrams** — UDP-based,
каждый TUN packet = один QUIC datagram. Замысел: минимум latency, 0-RTT
handshake, встроенный multi-path.

На практике всплыли три проблемы:

1. **HoL blocking при batching.** При большом TUN MTU (1420) и batched
   TX/RX выходило так, что один потерянный datagram блокировал весь batch.
   QUIC datagrams — по определению unreliable, но приложение (VPN) этим
   восстановлением не занималось.
2. **UDP = DPI-маркер.** В регионах с TSPU (Россия, и т.д.) UDP traffic
   проходит через отдельный filter. VPN должен быть неотличим от обычного
   HTTPS — а HTTPS это TCP+TLS, а не UDP.
3. **Нет SNI passthrough.** Чтобы поставить RU relay перед NL exit и
   маскировать SNI под `cdn.example.com`, нужен TCP + nginx stream с
   `ssl_preread`. С QUIC это не работает — nginx не умеет SNI passthrough
   для QUIC датаграмм.

Серия commits перевела проект на TCP транспорт:

- `237eb42` (2026-03-14) — migration to reliable streams
- `a0f7b00` (2026-03-15) — N=4 parallel QUIC streams (ещё внутри QUIC)
- `1be0781` (2026-03-29) — полный переход на HTTP/2 (v0.15.4)
- `21fab98` (2026-04-11) — parallel per-stream batch loops (v0.17.2,
  download 138→625 Mbit/s)

## Decision

Транспорт = **H2 / TLS 1.3 / TCP** с мульти-стрим шардингом.

- **N = `available_parallelism().clamp(2, 16)`** параллельных TLS соединений,
  каждое — отдельный H2 connection.
- **Flow routing**: каждый TCP flow (client side) hash'уется по 5-tuple в
  `flow_stream_idx` и pinn'ится к конкретному TLS-стриму. Внутри flow — FIFO
  порядок, между разными flow — нет HoL blocking.
- **Handshake**: `[1B stream_idx][1B client_max_streams]` атомарно в первом
  write — сервер сразу знает, к какому "слоту" относится это соединение и
  сколько всего клиент поднимает.
- **Parallel batch loops**: каждый stream имеет свой TX/RX loop, несколько
  CPU-ядер работают параллельно, нет single-threaded bottleneck'а.

Активный путь с v0.15.4 (2026-03-29). Старый QUIC код формально удалён в
v0.19.4 (ADR [0001](0001-remove-quic.md)).

## Alternatives considered

1. **QUIC datagrams + multi-path.** Отклонено: UDP DPI-маркер, нет SNI
   passthrough, HoL на batching, congestion control QUIC в kernel-less
   userspace реализации давал неустойчивую throughput.

2. **Один TLS-стрим с multiplexing внутри приложения.** Отклонено: head-of-line
   blocking на уровне одного TCP flow. Packet loss на транспортном слое
   блокирует все TUN flows одновременно. Мульти-стрим как раз решает это.

3. **Множество независимых TCP без H2 framing.** Отклонено: H2 frames
   позволяют nginx / load balancer маршрутизировать по `:authority` и
   выглядеть как обычный HTTP/2 traffic. Голый TCP без HTTP framing = ровно
   такой же сигнатуры, но менее инвисибельный.

## Consequences

**Плюсы:**
- **14 → 625 Mbit/s download** за серию оптимизаций (44×). Parallel per-stream
  batch loops дали основной прирост.
- **SNI passthrough через nginx stream на RU relay** — relay не терминирует
  TLS, просто `copy_bidirectional` после `ssl_preread`. Невозможно с QUIC.
- **Standard H2 over TLS 1.3** — не детектируется как VPN, выглядит как
  обычный HTTPS.
- **Одна кодовая ветка** — QUIC удалён (ADR
  [0001](0001-remove-quic.md)), нет dual-path complexity.

**Минусы / tradeoffs:**
- **Overhead от TLS handshake × N** при первом connect. Mitigated через
  session resumption (tickets), но cold start дольше чем QUIC 0-RTT.
- **N=2..16** — некоторые слабые мобильные ядра с 1 CPU core деградируют до
  N=2, TX ceiling на них ниже. Tradeoff приемлем, большинство устройств имеют
  4+ ядер.
- **TCP head-of-line blocking между pkt внутри одного flow**. Это цена
  reliable ordering. Flow-to-stream pinning ограничивает радиус проблемы
  одним flow.

**Что открывает:**
- **RU relay SNI passthrough** — `phantom-relay` просто copy_bidirectional
  после `ssl_preread`, не знает про TLS внутри.
- **Fakeapp fallback** — если client cert невалиден, сервер проксирует в
  реальный upstream (e.g., `google.com`), DPI видит честный HTTPS.
- **Mimicry warmup** — 4 placeholder batches в начале соединения
  имитирующие H.264 I-frame size distribution, выглядит как начало видео
  stream'а.

**Что закрывает:**
- QUIC как транспорт формально удалён (см. ADR
  [0001](0001-remove-quic.md)). Возврат к UDP возможен только через новый
  ADR с явной мотивацией.

## References

- Commits:
  - `237eb42` (2026-03-14) — migration to reliable streams
  - `a0f7b00` (2026-03-15) — N=4 parallel streams
  - `1be0781` (2026-03-29) — full HTTP/2 transport (v0.15.4)
  - `21fab98` (2026-04-11) — parallel per-stream batch loops (v0.17.2)
- Связанные файлы: `crates/core/src/tls.rs`, `crates/client-common/src/handshake.rs`,
  `crates/client-core-runtime/src/tx_rx.rs`
- Связанная архитектура: [../architecture/transport.md](../architecture/transport.md),
  [../architecture/wire-format.md](../architecture/wire-format.md)
- Связанный ADR: [0001-remove-quic.md](0001-remove-quic.md) — финальное удаление
  QUIC-кода
