---
updated: 2026-04-17
---

# Sessions — SessionCoordinator

## Overview

Одна VPN-сессия = один клиент (один fingerprint) + до `effective_n`
параллельных TLS-стримов. На стороне сервера сессия представлена
`VpnSession` (она же SessionCoordinator), хранящей per-stream каналы,
per-сессионные метрики, passive DNS cache и shutdown-handle. `VpnSession`
transport-agnostic — изначально поддерживала и QUIC, и H2, сейчас только H2
(см. [transport](./transport.md)).

Сессия индексируется двумя DashMap-ами: по TUN-IP (для TUN→client dispatch)
и по fingerprint (для handshake reconnect lookup).

## Индексы и lifecycle

```
DashMap<IpAddr, Arc<VpnSession>>     ← VpnSessionMap      (TUN→client dispatch)
DashMap<String, Arc<VpnSession>>     ← SessionByFp        (handshake reconnect)

VpnSession {
    effective_n,              // negotiated stream count для этой сессии
    data_sends:  Vec<Mutex<Option<mpsc::Sender<Bytes>>>>  // client←server per stream
    attach_gen:  Vec<AtomicU64>                           // detach-race guard
    tun_pkt_txs: Mutex<Vec<Option<mpsc::Sender<Bytes>>>>  // TUN→client per stream
    close_tx:    Mutex<Option<oneshot::Sender<()>>>
    bytes_rx, bytes_tx, last_seen, created_at
    dest_log, stats_samples, dns_cache
    fingerprint: String
}
```

- **`attach_stream(stream_idx, sender)`** — при accept нового TLS-стрима.
  Атомарно инкрементирует `attach_gen[idx]` и записывает `sender` под mutex'ом.
  Возвращает generation token.
- **`detach_stream_gen(stream_idx, gen)`** — при EOF или write error. Очищает
  слот **только если** `attach_gen[idx] == gen` — защита от stale detach'а
  старого writer'а, который может побить свежий reconnect.
- **`all_streams_down()`** — все `data_sends` слоты `None`. Cleanup task
  через минуту evict'ит сессию из обоих DashMap'ов.
- **`close()`** — явное завершение: оповещает transport (`close_tx`), сбрасывает
  все senders, будит все `stream_batch_loop`'ы и дренирует per-stream каналы.

### Lookup по fingerprint для reconnect

На handshake (см. [handshake](./handshake.md)) сервер ищет существующую
сессию по fingerprint. Если найдена:

- `stream_idx >= existing.effective_n` ⇒ reject. Клиент попытается с
  меньшим idx.
- `client_max != existing.effective_n` ⇒ существующая сессия закрывается,
  создаётся новая с новым `effective_n`. Это защищает от "пина" сессии в
  `effective_n=2` навсегда из-за слабого первого соединения.

## Двунаправленный data-plane

### Client → Server (`stream_batch_loop`)

Один read loop на TLS-стрим. Читает wire-framed batch'и через `read_exact`,
парсит `extract_batch_packets`, пишет IP-пакеты в общий TUN fd. Метрики:
`bytes_rx += frame_size`, `last_seen = now`, passive DNS-cache update.

### Server → Client (TUN dispatch + per-stream batcher)

Разделено на две стадии (важная оптимизация v0.17.2):

1. **`tun_dispatch_loop(pkt_rx, sessions)`** — читает пакет из TUN, по
   `dst_ip` находит `VpnSession`, через `flow_stream_idx(pkt, effective_n)`
   выбирает `tun_pkt_txs[idx]`, делает `try_send`. Non-blocking: `Full` →
   drop с warn-метрикой, `Closed` → drop + evict session из map.
2. **`stream_batch_loop(pkt_rx, session, stream_idx)`** — один таск на
   `stream_idx`. Дренирует до `MAX_PKTS_PER_BATCH = 40` пакетов из своего
   канала, собирает wire-framed batch, пишет через
   `session.data_sends[stream_idx]` → TLS writer. Каждый стрим имеет
   собственный batcher и собственную TLS запись — "медленный" стрим не
   блокирует "быстрый".

Этот split заменил старый `send_frame_rr` round-robin: теперь нет общей точки
serialization, каждый CPU-core может обрабатывать свой стрим параллельно.
Throughput улучшился с 138 до 625 Mbit/s (v0.17.2).

## Detached-slot policy

`stream_batch_loop` каждую итерацию **заново** снимает snapshot
`data_sends[stream_idx]`. Если слот `None` (текущее соединение отвалилось):

- frame дропается (DROP; НЕ буферится) — нельзя блокировать pipeline в
  ожидании reconnect, остальные стримы живые и должны продолжать;
- если `all_streams_down() && pkt_rx.disconnected` — loop exit'ится;
- иначе continue — reconnect может attach'нуть новый `Sender` в этот слот.

Metrics: `drop_detached` логируется на 1-ый, затем каждый 1024-ый drop —
иначе warn-storm на flapping соединениях.

## Passive DNS cache

Сервер перехватывает UDP-ответы DNS (src_port == 53) в `tun_dispatch_loop`:
парсит header, answers, вытаскивает A-record'ы, пишет в
`VpnSession.dns_cache`:

- `lru::LruCache<Ipv4Addr, (String, Instant)>` с capacity 2048
- TTL 5 минут — entry expire'ится на read через `dns_lookup`, expired не
  promote'ится
- Защита от compression loop'ов: `dns_skip_name` / `dns_read_name` имеют
  limit 128 / 16 jumps соответственно

Используется в `/api/clients/:name/logs` (см. [admin API](./admin-api.md))
для отображения hostname'а вместо голого IP.

## Cleanup task

`cleanup_task(sessions, sessions_by_fp, idle_secs, hard_timeout_secs)` —
ходит раз в 60 секунд:

- `is_idle(idle_secs)` — `last_seen` старше threshold ⇒ evict + close +
  reap_session_fp.
- `is_hard_expired(hard_timeout_secs)` — `created_at` старше `hard_timeout`
  (обычно сутки) ⇒ evict независимо от активности.
- Иначе — snapshot `bytes_rx/tx` в `stats_samples` (rolling 60 samples, одна
  точка в минуту) для `/api/clients/:name/stats`.

`reap_session_fp` важен: просто evict из `VpnSessionMap` оставит "зомби" в
`SessionByFp`, и reconnect создаст handshake-path'ом stale coordinator
с уже убитыми batch loops (регрессия v0.18).

## Invariants

- `data_sends.len() == tun_pkt_txs.len() == effective_n` на всём протяжении
  жизни сессии. `effective_n` **не меняется** — при необходимости расширения
  сессия закрывается и создаётся новая.
- `flow_stream_idx(pkt, session.effective_n)` в `tun_dispatch_loop`. Использовать
  `MAX_N_STREAMS` вместо `effective_n` — бaг (пакет попадёт в несуществующий
  слот).
- TUN→client drop никогда не блокирует pipeline. `try_send` + drop-with-metric.
- Detach race: `detach_stream_gen` сверяет `attach_gen[idx]` с token'ом.
  Старый writer exit'ящийся после reconnect не должен обнулять свежий slot.
- Session identity = **fingerprint**, не 5-tuple и не TUN-IP. Rename клиента
  в `clients.json` fingerprint не меняет.
- `close()` сбрасывает все senders — это wake'ит каждый `stream_batch_loop`
  через `pkt_rx.recv() == None`, он exit'ится, иначе получили бы leak taskов.
- DNS-cache eviction by TTL происходит **на read**. Periodical sweep не нужен —
  LRU capacity 2048 сама ограничивает размер.

## Sources

- Основной код: [vpn_session.rs](../../../server/server/src/vpn_session.rs)
  (`VpnSession`, `new_coordinator`, `attach_stream`, `detach_stream_gen`,
  `close`, `tun_dispatch_loop`, `stream_batch_loop`, `cleanup_task`,
  `dns_parse_response`).
- Accept / session creation: [h2_server.rs](../../../server/server/src/h2_server.rs).
- gitnexus: `gitnexus_context({name: "VpnSession"})`,
  `gitnexus_query({query: "tun dispatch batch"})`.
- Связанные страницы: [handshake](./handshake.md), [transport](./transport.md),
  [wire format](./wire-format.md), [admin API](./admin-api.md)
  (метрики и DNS в endpoint'ах), [glossary](../glossary.md).
- Related ADRs: [0003-h2-multistream-transport](../decisions/0003-h2-multistream-transport.md).
