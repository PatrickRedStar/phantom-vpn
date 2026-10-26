---
updated: 2026-10-26
---

# Transport — H2/TLS + SNI Routing

## Overview

Единственный режим транспорта — **HTTP/2 поверх TLS 1.3 поверх TCP** с
мульти-стрим шардингом. QUIC удалён в v0.19.4 (см.
[ADR 0001](../decisions/0001-remove-quic.md)), Noise — в v0.18 (см.
[ADR 0002](../decisions/0002-noise-to-mtls.md)). Мотивация выбора H2 как
активного транспорта и отказ от UDP/QUIC — в
[ADR 0003](../decisions/0003-h2-multistream-transport.md).

С точки зрения user-observable поведения это выглядит как N параллельных
HTTPS-соединений к одному хосту (`tls.nl2.bikini-bottom.com:443`), проходящих
через стандартный nginx stream с `ssl_preread`. Никаких UDP, никаких
нестандартных ALPN (клиент предлагает `h2, http/1.1`, как браузер), никаких
pre-amble байтов до TLS ClientHello.

## Три слоя топологии

```
Android / iOS / Linux client
  │
  │ [опциональный хоп для RU-абонентов]
  │
  ▼
RU relay (hostkey.bikini-bottom.com:443, phantom-relay)
  SNI peek → raw TCP copy_bidirectional (НЕ терминирует TLS)
  │
  ▼
NL frontend (89.110.109.128:443, nginx stream ssl_preread)
  SNI == tls.nl2 → passthrough 127.0.0.1:8443
  SNI другой    → LE cert + fallback HTML
  │
  ▼
phantom-server (127.0.0.1:8443, TLS 1.3 terminate + mTLS)
  valid client cert → VpnSession
  нет/невалидный    → fakeapp::handle
```

Полная картина handshake-а на каждом хопе — в [handshake](./handshake.md).

## Параллелизм (N streams)

На одного клиента открывается `n_data_streams() ∈ [2, 16]` независимых
TCP-соединений (см. [wire format](./wire-format.md) и
[handshake](./handshake.md)). Сервер и клиент считают свой `n` независимо
через `available_parallelism()`, клиент передаёт свой `max_streams` в
handshake-байте, сервер clamp'ает: `effective_n = client_max.clamp(MIN, MAX)`.

Пакеты раскладываются по стримам через `flow_stream_idx`:

```rust
pub fn flow_stream_idx(pkt: &[u8], n: usize) -> usize {
    // h = src_ip + dst_ip + proto + (src_port XOR dst_port)   — симметричен
    // IPv4-фрагменты: без портов (у не-первого фрагмента там данные)
    // idx = (h * 0x9E3779B1) as u64 * n >> 32                  — старшие биты
}
```

Перемешивание обязательно: Linux/Android выдают эфемерные порты одной чётности,
и голый `h % n` при чётном `n` попадал только в половину стримов. Сторонам не
нужно совпадать по хешу — каждая выбирает стрим только для своего направления, —
поэтому смена функции совместима со старыми клиентами и серверами.

Гарантии:

- **В рамках одного TCP-flow** (one `src_ip:src_port` ↔ `dst_ip:dst_port`)
  пакеты всегда идут по одному и тому же `stream_idx` ⇒ TLS + TCP обеспечивают
  FIFO ⇒ нет reordering.
- **Между разными flow'ами** HoL blocking отсутствует: packet loss в одном
  TLS-стриме не блокирует другие.

Пакеты ходят как `Bytes`; на приёме клиент копирует каждый пакет из буфера
frame'а один раз (там же MSS-clamp). На отправке всё, что накопилось в очереди
стрима за цикл, уходит одним frame'ом (см. [wire format](./wire-format.md)).

## Живучесть стримов и переподключение

Клиентское ядро (`client-core-runtime::supervise`):

- **Стримы открываются строго последовательно** (не залпом SYN'ов — DPI-признак,
  v0.27.1). Все N обязательны: без полного набора часть flow'ов уходила бы в никуда.
- **Умерший стрим переоткрывается один**, со случайной паузой 1–10 с (при
  повторных неудачах — по `BACKOFF_SECS` до 30 с). Сервер пристыковывает новое
  соединение к существующей сессии по fingerprint. Пока стрим мёртв, его flow'ы
  дропаются сразу, а UI показывает `Degraded`.
- **Вся сессия** переподключается, только если все N стримов мертвы ≥ 3 с, если
  устройство проснулось (скачок wall-clock > 60 с между секундными тиками) или
  при фатальной ошибке.
- **Мёртвый стрим** — 90 с без единого frame'а (heartbeat'ы считаются) или 30 с
  неподтверждённых данных (`TCP_USER_TIMEOUT`, на Darwin `TCP_RXT_CONNDROPTIME`;
  локальный таймер, пакетов на провод не добавляет).
- **Переподключение бесконечное** при `auto_reconnect`: пауза по категории
  ошибки (1 с после RST, 2 с после тишины, 5 с без сети) с подъёмом до 30 с и
  джиттером до +25 %; после сессии, прожившей ≥ 30 с, счётчик сбрасывается.
  `ConnState::Error` — только для фатальных ошибок (кривой профиль, серт сервера,
  отзыв доступа, неверные часы) с человекочитаемой причиной в `last_error`.
  Сразу после обрыва публикуется `Reconnecting`.
- **Диспетчер TUN→стрим**: живой, но полный стрим ждёт до 50 мс, потом пакет
  дропается (счётчик `tx_dropped` в телеметрии) — один застрявший стрим не
  клинит весь uplink.

## NL frontend (nginx stream)

Вся публичная поверхность — port 443 TCP на NL exit'е (vdsina,
`89.110.109.128`). Nginx настроен в `stream { ... }` режиме с `ssl_preread`:
peek'ит первый ClientHello, извлекает SNI, маршрутизирует.

| SNI | Upstream | Что получает клиент |
|---|---|---|
| `tls.nl2.bikini-bottom.com` | `127.0.0.1:8443` (phantom-server) | Our TLS 1.3 + mTLS |
| Anything else | Local fallback: LE cert + HTML | "Честный" сайт |

Port 8443 на phantom-server **не публичен** — доступен только через nginx,
что исключает прямое прощупывание VPN-listener'а извне.

## RU relay (SNI Passthrough, v0.17+)

RU-нода (`phantom-relay`, `193.187.95.128:443`) выполняет **SNI passthrough
без терминации TLS**. Алгоритм:

1. Accept TCP, peek ~1.5 KB (достаточно для ClientHello record).
2. Парсинг TLS record header (ContentType=0x16), handshake header
   (HandshakeType=0x01), SNI extension (type=0x0000, name_type=0x00). Ручной
   парсер в [server/relay/src/main.rs::extract_sni](../../../server/relay/src/main.rs).
3. Если `SNI == expected_sni` (config: `tls.nl2.bikini-bottom.com`) →
   `tokio::io::copy_bidirectional` к `upstream_addr` (NL:443). TLS handshake
   идёт end-to-end между клиентом и phantom-server, relay не видит plaintext.
4. Иначе → fallback `TlsAcceptor` с LE cert (`hostkey.bikini-bottom.com`) →
   HTML-заглушка, выглядит как обычный HTTPS-сайт на этом имени.

Эта схема убирает **двойное шифрование** RU-хопа. До v0.17 relay
re-encrypted каждый байт своими rustls-сессиями — это было CPU-bound узкое
место. Теперь relay I/O-bound, пропускная способность растёт ~линейно с ядром.

С точки зрения RU DPI трафик выглядит как обычное HTTPS к российскому сайту
`hostkey.bikini-bottom.com` (обслуживаемому LE cert'ом).

## Шейпинг трафика

Модуль `shaper` удалён (см. [ADR 0001](../decisions/0001-remove-quic.md) и
историю v0.17.x). Паддинг включён только на первых 10–20 frame'ах каждого
стрима (см. [wire format](./wire-format.md)). Остальное anti-DPI строится на
других уровнях:

- **H2 multiplexing** — N стримов ⇒ размер и тайминг записей размазывается;
- **nginx SNI-passthrough** — сервер виден как стандартный HTTPS-хост;
- **Mimicry warmup** (см. [handshake](./handshake.md)) — H.264-like I-frame
  pattern в начале сессии;
- **Heartbeat'ы** (см. [wire format](./wire-format.md)) — раз в 30–60 с на
  idle-стриме, несинхронно между стримами.

## Invariants

- **Relay НЕ терминирует TLS.** End-to-end TLS handshake — от клиента до
  phantom-server. Нарушение этого инварианта (re-encrypt на RU) ломает
  mTLS-identity и возвращает CPU-bound relay.
- **Все TLS-соединения к NL одинаковы с точки зрения nginx/relay**: один SNI
  (`tls.nl2`), один upstream. Различать "клиентов" или "стримы одного
  клиента" на этом уровне нельзя — это обеспечивает privacy.
- **Нет UDP.** TUN-трафик внутри tunnel'а может содержать UDP-пакеты, но сам
  transport (wire) = TCP only. Новый UDP-режим невозможен без нового ADR.
- **VPN-путь всегда на ALPN `h2`.** Клиент предлагает `h2, http/1.1` (как
  браузер), сервер согласует только `h2`. Нет h1.1 fallback'а для VPN-пути.
- **Port на phantom-server (`8443`) — loopback-only.** Внешний доступ только
  через nginx:443 с SNI-filter'ом. Direct connection к `:8443` с любого
  external IP невозможен.
- **`flow_stream_idx` симметричен** (hash от `src + dst + proto + (sp XOR dp)`,
  затем перемешивание). Нарушение симметрии ⇒ A→B и B→A попадут в разные
  стримы: flow зависит от двух соединений вместо одного.

## Sources

- Server accept: [h2_server.rs](../../../server/server/src/h2_server.rs)
  (`run_h2_accept_loop`).
- RU relay: [server/relay/src/main.rs](../../../server/relay/src/main.rs)
  (`extract_sni`, passthrough vs fallback branch).
- Client dial: [client-common/src/tls_handshake.rs](../../../crates/client-common/src/tls_handshake.rs),
  [tls_tunnel.rs](../../../crates/client-common/src/tls_tunnel.rs).
- Константы и `flow_stream_idx`: [wire.rs](../../../crates/core/src/wire.rs).
- gitnexus: `gitnexus_query({query: "sni passthrough relay"})`,
  `gitnexus_context({name: "flow_stream_idx"})`.
- nginx конфиг и systemd unit — хост-специфично, на vdsina:
  `/etc/nginx/stream.conf`, `/etc/systemd/system/phantom-server.service`.
- Связанные страницы: [wire format](./wire-format.md),
  [handshake](./handshake.md), [sessions](./sessions.md),
  [crypto](./crypto.md), [glossary](../glossary.md).
- Related ADRs: [0001-remove-quic](../decisions/0001-remove-quic.md),
  [0003-h2-multistream-transport](../decisions/0003-h2-multistream-transport.md).
