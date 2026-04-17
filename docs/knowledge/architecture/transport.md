---
updated: 2026-04-17
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
нестандартных ALPN, никаких pre-amble байтов до TLS ClientHello.

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
    // 5-tuple hash: src_ip + dst_ip + proto + (src_port XOR dst_port)
    // Symmetric: A→B = B→A (важно, иначе порядок внутри TCP-flow ломался бы).
}
```

Гарантии:

- **В рамках одного TCP-flow** (one `src_ip:src_port` ↔ `dst_ip:dst_port`)
  пакеты всегда идут по одному и тому же `stream_idx` ⇒ TLS + TCP обеспечивают
  FIFO ⇒ нет reordering.
- **Между разными flow'ами** HoL blocking отсутствует: packet loss в одном
  TLS-стриме не блокирует другие.

Zero-copy путь на обоих направлениях через `Bytes` / `BytesMut` — нет
`.to_vec()` в hot path, пакет после TUN read до TLS write не копируется.

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

## Шейпинг трафика — отключён с v0.17

Модуль `shaper` удалён (см. [ADR 0001](../decisions/0001-remove-quic.md) и
историю v0.17.x). Padding-параметр `target_size` в `build_batch_plaintext`
зарезервирован, но всегда `= 0`. Anti-DPI строится на других уровнях:

- **H2 multiplexing** — N стримов ⇒ размер и тайминг записей размазывается;
- **nginx SNI-passthrough** — сервер виден как стандартный HTTPS-хост;
- **Mimicry warmup** (см. [handshake](./handshake.md)) — H.264-like I-frame
  pattern в начале сессии;
- **Heartbeat'ы** (см. [wire format](./wire-format.md)) — idle-стримы не
  молчат > 30 секунд, имитируя keepalive живых приложений.

## Invariants

- **Relay НЕ терминирует TLS.** End-to-end TLS handshake — от клиента до
  phantom-server. Нарушение этого инварианта (re-encrypt на RU) ломает
  mTLS-identity и возвращает CPU-bound relay.
- **Все TLS-соединения к NL одинаковы с точки зрения nginx/relay**: один SNI
  (`tls.nl2`), один upstream. Различать "клиентов" или "стримы одного
  клиента" на этом уровне нельзя — это обеспечивает privacy.
- **Нет UDP.** TUN-трафик внутри tunnel'а может содержать UDP-пакеты, но сам
  transport (wire) = TCP only. Новый UDP-режим невозможен без нового ADR.
- **Единственный выбор ALPN — `h2`.** Клиент просит h2, сервер согласует h2.
  Нет h1.1 fallback'а для VPN-пути (только для fakeapp).
- **Port на phantom-server (`8443`) — loopback-only.** Внешний доступ только
  через nginx:443 с SNI-filter'ом. Direct connection к `:8443` с любого
  external IP невозможен.
- **`flow_stream_idx` симметричен** (hash от `src + dst + proto + (sp XOR dp)`).
  Нарушение симметрии ⇒ A→B и B→A попадут в разные стримы, и порядок внутри
  flow сломается.

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
