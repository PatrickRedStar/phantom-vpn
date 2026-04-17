---
updated: 2026-04-17
---

# Wire Format

Формат данных внутри одного TLS-стрима после handshake.

## Overview

Внутри каждого TLS-стрима идёт последовательность **frame**'ов; каждый frame
содержит один **batch** из одного или нескольких IP-пакетов. Batch-ы собираются
на стороне отправителя из пакетов, попавших в данный `stream_idx` через
`flow_stream_idx` (см. [transport](./transport.md)), и парсятся на стороне
получателя в `extract_batch_packets`.

Формат спроектирован под три задачи: (1) атомарное чтение через `read_exact`
без промежуточных буферов; (2) поддержка пакетов до 65535 байт (больше TCP MSS
и typical TUN MTU); (3) amortization TLS-записей — много мелких IP-пакетов
объединяются в один `write_all`, уменьшая overhead per-packet.

## Frame layout

```
[4B frame_len BE][batch]
```

`frame_len` — длина `batch`-плейлоада (без учёта самих 4 байт префикса). BE
byte order чтобы совпадать с `u32::to_be_bytes`; 4 байта — не varint — для
детерминированного `read_exact(4)` без дополнительного парсинга.

### Batch layout

```
[2B pkt1_len BE][pkt1_bytes]
[2B pkt2_len BE][pkt2_bytes]
...
[2B 0x0000]              ← end-of-batch marker
[optional padding]       ← zero-fill до target_size (v0.17+ выключено)
```

2 байта на `pkt_len` ⇒ максимум 65535 байт на пакет. `BATCH_MAX_PLAINTEXT =
65536` — sum всех pkt + overhead. Терминатор — zero-length packet (`0x0000`) —
работает корректно, поскольку реальный IP-пакет длиной 0 невозможен; никакого
явного счётчика пакетов не нужно.

## Константы (`crates/core/src/wire.rs`)

| Имя | Значение | Назначение |
|---|---|---|
| `BATCH_MAX_PLAINTEXT` | `65_536` | Максимум на один frame (включая терминатор и padding). |
| `MIN_N_STREAMS` | `2` | Минимум параллельных TLS-стримов на сессию. |
| `MAX_N_STREAMS` | `16` | Жёсткий cap — bounds `stream_idx` byte и размер `data_sends`. |
| `QUIC_TUNNEL_MTU` | `1350` | MTU TUN-интерфейса. Legacy naming — QUIC удалён в v0.19.4 ([ADR 0001](../decisions/0001-remove-quic.md)). |
| `QUIC_TUNNEL_MSS` | `1310` | TCP MSS clamping на TUN интерфейсе. Legacy naming. |

```rust
pub fn n_data_streams() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(MIN_N_STREAMS)
        .clamp(MIN_N_STREAMS, MAX_N_STREAMS)
}
```

Клиент и сервер вызывают `n_data_streams()` независимо; в [handshake](./handshake.md)
обмениваются байтом `client_max_streams`, `effective_n = client_max.clamp(MIN,
MAX)` фиксируется на всю жизнь сессии.

## Heartbeat frames

Idle TLS-стрим, молчащий 30+ секунд, — DPI-tell (реальные мобильные приложения
шлют keepalive-записи каждые несколько секунд). Клиент и сервер оба шлют
dummy "heartbeat"-batch'и на idle-стримах со случайными интервалами:

- `HEARTBEAT_INTERVAL_MIN_SECS = 15`, `HEARTBEAT_INTERVAL_MAX_SECS = 45`
- `HEARTBEAT_START_JITTER_MIN_SECS = 5`..`30` — первый hb после создания стрима,
  чтобы N стримов не fire'или heartbeat синхронно
- Packet size uniform `[40, 200]` байт
- Первый байт `= 0x00` (sentinel) — version nibble != 4 ⇒ receiver'ы дропают
  через `is_heartbeat_packet` / IPv4-фильтр в `tls_rx_loop`

Heartbeat = валидный batch с одним packet'ом — парсится штатным
`extract_batch_packets`, отфильтровывается на уровне приложения, не ломает
схему.

## Padding — отключён с v0.17+

`build_batch_plaintext(packets, target_size, buf)` всё ещё принимает
`target_size` — если задано, zero-fill добавляется после терминатора до этого
размера. В production `target_size = 0`, padding не добавляется. Anti-DPI
теперь строится на других уровнях: H2 mux, [SNI passthrough через
nginx/relay](./transport.md), natural H.264-like бёрсты от mimicry warmup
(см. [handshake](./handshake.md)). Shaper-модуль удалён — параметр остался
зарезервированным под future re-integration.

## Invariants

- Внутри одного TLS-стрима порядок batch'ей строгий (TLS гарантирует FIFO).
- `pkt_len > 0` всегда; первое встреченное `pkt_len == 0` — конец batch'а.
- Отдельный pkt не превышает `u16::MAX = 65535` байт (иначе
  `PacketError::BadIpLen`).
- Sum `(2 + pkt_len for each pkt) + 2` ≤ `BATCH_MAX_PLAINTEXT`. На практике
  `stream_batch_loop` ограничивает batch до `MAX_PKTS_PER_BATCH = 40` при MTU
  1350 — заведомо под 55 KB < 64 KB.
- После терминатора допустим любой мусор (padding / хвост AEAD) — парсер
  `extract_batch_packets` останавливается на `0x0000`.
- `flow_stream_idx` должен возвращать значение в `[0, effective_n)`, иначе
  `tun_dispatch_loop` писал бы в неинициализированный слот.

## Sources

- Код: [wire.rs](../../../crates/core/src/wire.rs) (`build_batch_plaintext`,
  `extract_batch_packets`, `build_heartbeat_frame`, `flow_stream_idx`).
- Тесты roundtrip и граничных случаев — там же в модуле `tests`.
- gitnexus: `gitnexus_query({query: "wire batch encode"})`,
  `gitnexus_context({name: "build_batch_plaintext"})`.
- Связанные страницы: [handshake](./handshake.md), [transport](./transport.md),
  [sessions](./sessions.md), [glossary](../glossary.md).
- Related ADRs: [0001-remove-quic](../decisions/0001-remove-quic.md) (legacy
  naming `QUIC_TUNNEL_*`), [0003-h2-multistream-transport](../decisions/0003-h2-multistream-transport.md).
