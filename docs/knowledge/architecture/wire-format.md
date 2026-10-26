---
updated: 2026-10-26
---

# Wire Format

Формат данных внутри одного TLS-стрима после handshake.

## Overview

Стрим начинается с 2-байтного заголовка клиента (см. [handshake](./handshake.md)),
дальше в обе стороны идёт последовательность **frame**'ов; каждый frame содержит
один **batch** из одного или нескольких IP-пакетов. Batch-ы собираются на стороне
отправителя из пакетов, попавших в данный `stream_idx` через `flow_stream_idx`
(см. [transport](./transport.md)), и разбираются на стороне получателя итератором
`batch_packets`.

Формат спроектирован под три задачи: (1) атомарное чтение через `read_exact`
без промежуточных буферов; (2) поддержка пакетов до 65535 байт (больше TCP MSS
и typical TUN MTU); (3) amortization TLS-записей — всё, что накопилось в очереди
стрима за один цикл TX, уходит одним frame'ом и одним `write_all` (TLS режет его
на записи ≤16 КБ), а не записью на пакет.

## Начало стрима

```
[1B stream_idx][1B n_streams][heartbeat-frame]      ← одна TLS-запись
```

Клиент дописывает обычный heartbeat-frame в ту же запись, что и 2 байта
заголовка: иначе первая клиентская запись каждого стрима была бы ровно 2 байта
plaintext — фиксированный размерный признак. Сервер читает ровно 2 байта
(`read_exact`) и дальше разбирает frame'ы как обычно — heartbeat выбрасывается
штатным фильтром, поэтому это совместимо с сервером любой версии.

## Frame layout

```
[4B frame_len BE][batch]
```

`frame_len` — длина `batch`-плейлоада (без учёта самих 4 байт префикса). BE
byte order чтобы совпадать с `u32::to_be_bytes`; 4 байта — не varint — для
детерминированного `read_exact(4)` без дополнительного парсинга.
`frame_len ≤ BATCH_MAX_PLAINTEXT` — больший frame приёмник считает ошибкой и
рвёт стрим; `frame_len = 0` — пустой frame, допустим.

### Batch layout

```
[2B pkt1_len BE][pkt1_bytes]
[2B pkt2_len BE][pkt2_bytes]
...
[2B 0x0000]              ← end-of-batch marker
[optional padding]       ← zero-fill до target_size, приёмник игнорирует
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
| `QUIC_TUNNEL_MTU` | `1300` | MTU TUN-интерфейса (снижен с 1350 в v0.25.0 под 5G NSA). Legacy naming — QUIC удалён в v0.19.4 ([ADR 0001](../decisions/0001-remove-quic.md)). |
| `QUIC_TUNNEL_MSS` | `1240` | TCP MSS clamping на TUN интерфейсе. Legacy naming. |
| `HEARTBEAT_INTERVAL_{MIN,MAX}_SECS` | `30`, `60` | Интервал heartbeat на idle-стриме. |

```rust
pub fn n_data_streams() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(MIN_N_STREAMS)
        .clamp(MIN_N_STREAMS, MAX_N_STREAMS)
}
```

Клиент и сервер вызывают `n_data_streams()` независимо; в [handshake](./handshake.md)
клиент шлёт байт `n_streams` (всегда своё полное N, не число живых стримов),
`effective_n = client_max.clamp(MIN, MAX)` фиксируется на всю жизнь сессии.

## Heartbeat frames

Клиент и сервер оба шлют dummy "heartbeat"-batch'и на idle-стримах: держат
NAT-записи мобильных операторов и кормят таймеры живости приёмника.

- Интервал — случайный `[30, 60]` с, **свой у каждого стрима в каждую сторону**,
  реальный трафик откладывает ближайший heartbeat. Синхронизации между стримами
  нет намеренно — синхронные таймеры = DPI-признак (убраны в v0.27.1). Нижняя
  граница 30 с — чтобы 8–16 стримов не держали радиомодуль телефона проснувшимся.
- Сервер: первый hb после создания стрима через `HEARTBEAT_START_JITTER` 5..30 с.
  Клиент: первый hb уходит сразу, в одной записи с заголовком стрима.
- Packet size uniform `[40, 200]` байт; первый байт `= 0x00` (sentinel) —
  version nibble != 4 ⇒ receiver'ы дропают его IPv4-фильтром.
- Значения пушабельны через policy (ADR 0014), но зажимаются: интервал 1..60 с,
  размер 20..1200 байт.

Таймеры живости, которые heartbeat обязан опережать:

| Где | Порог | Что |
|---|---|---|
| Клиент, Stale | 75 с без любого принятого frame'а (heartbeat считается) | UI «канал замолчал», без действий |
| Клиент, мёртвый стрим | 90 с (`RX_IDLE_TIMEOUT_SECS`) | стрим закрывается и переоткрывается один |
| Сервер, idle чтения | 150 с | сервер закрывает стрим |

Heartbeat = валидный batch с одним packet'ом — разбирается штатным
`batch_packets`, отфильтровывается на уровне приложения, не ломает схему.

## Padding — первые frame'ы стрима

`build_batch_plaintext(packets, target_size, buf)` добивает batch нулями после
терминатора до `target_size` (внутри AEAD — наблюдатель видит только размер).
Приёмники всех версий читают до терминатора, поэтому паддинг каждая сторона
включает у себя независимо, wire-формат не меняется.

Клиент добивает **первые 10–20 frame'ов каждого стрима** (число случайное на
стрим) до случайного размера 64..1400 байт: иначе первые записи соединения
повторяют размеры внутренних пакетов (SYN, ClientHello, DNS) — классический
признак туннеля. Дальше паддинг выключен (кроме пушабельного policy-floor,
ADR 0014). Сервер делает то же на своей стороне.

## Invariants

- Внутри одного TLS-стрима порядок batch'ей строгий (TLS гарантирует FIFO).
- `pkt_len > 0` всегда; первое встреченное `pkt_len == 0` — конец batch'а.
- Отдельный pkt не превышает `u16::MAX = 65535` байт (иначе
  `PacketError::BadIpLen`).
- Sum `(2 + pkt_len for each pkt) + 2` ≤ `BATCH_MAX_PLAINTEXT`.
  `build_batch_plaintext` на большее возвращает ошибку (раньше молча резал
  frame); клиентский TX переносит невлезший пакет в следующий frame, серверный
  `stream_batch_loop` ограничивает batch до `MAX_PKTS_PER_BATCH = 40`.
- После терминатора допустим любой мусор (padding) — `batch_packets`
  останавливается на `0x0000`, на обрезанном пакете или в конце буфера.
- `flow_stream_idx` должен возвращать значение в `[0, effective_n)`, иначе
  `tun_dispatch_loop` писал бы в неинициализированный слот.

## Sources

- Код: [wire.rs](../../../crates/core/src/wire.rs) (`build_batch_plaintext`,
  `batch_packets`, `build_heartbeat_frame`, `flow_stream_idx`),
  [tls_tunnel.rs](../../../crates/client-common/src/tls_tunnel.rs) (клиентские
  TX/RX-циклы, `write_handshake`).
- Тесты roundtrip и граничных случаев — там же в модуле `tests`.
- gitnexus: `gitnexus_query({query: "wire batch encode"})`,
  `gitnexus_context({name: "build_batch_plaintext"})`.
- Связанные страницы: [handshake](./handshake.md), [transport](./transport.md),
  [sessions](./sessions.md), [glossary](../glossary.md).
- Related ADRs: [0001-remove-quic](../decisions/0001-remove-quic.md) (legacy
  naming `QUIC_TUNNEL_*`), [0003-h2-multistream-transport](../decisions/0003-h2-multistream-transport.md).
