---
updated: 2026-10-27
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
HTTPS-соединений к одному адресу (реле, `:443`, SNI `tls.nl2.bikini-bottom.com`),
проходящих через стандартный nginx stream с `ssl_preread`. Никаких UDP, никаких
нестандартных ALPN (клиент предлагает `h2, http/1.1`, как браузер), никаких
pre-amble байтов до TLS ClientHello.

## Три слоя топологии

```
Android / iOS / macOS / Linux / OpenWrt client
  │  TCP :443, SNI = tls.nl2.bikini-bottom.com
  ▼
RU relay (balancer.bikini-bottom.com, 158.160.135.140:443)
  nginx stream ssl_preread → phantom-relay (127.0.0.1:5443)
  SNI == tls.nl2 → сырой passthrough (НЕ терминирует TLS)
  SNI другой    → ответ как у nginx на fallback-серте
  │
  ▼
phantom-server (NL exit 89.110.109.128:8443, TLS 1.3 terminate + mTLS)
  серт из allowlist     → VpnSession
  серт не из allowlist  → TLS-алерт certificate_revoked
  без серта             → fakeapp::handle
```

Без реле клиент ходит прямо на `89.110.109.128:8443` — из РФ этот путь режется
(см. [dpi-tspu](./dpi-tspu.md)), поэтому боевые профили идут через реле.

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
поэтому смена функции совместима со старыми клиентами и серверами. Цена
смешанных версий: два направления одного flow едут по разным стримам, и flow
зависит от двух соединений. Старым клиентам, которые не умеют переоткрывать
один стрим, это примерно вдвое увеличивает число flow'ов, зависающих при смерти
стрима, — сервер с новым хешем лучше выкатывать после обновления клиентов.

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
  `ConnState::Error` — только для фатальных ошибок (кривой профиль, отзыв или
  истечение доступа, неверные часы, закрытый TUN-интерфейс) с человекочитаемой
  причиной в `last_error`. Чужой серт сервера (captive portal, fallback-серт
  реле) не фатален — переподключение идёт, пока сеть не починится. Сразу после
  обрыва публикуется `Reconnecting`.
- **Диспетчер TUN→стрим**: живой, но полный стрим получает одну отсрочку до
  50 мс. Если очередь за это время не освободилась, стрим считается застрявшим:
  его пакеты дропаются без ожидания (счётчик `tx_dropped` в телеметрии), пока
  очередь снова не примет пакет. Диспетчер общий, так что замёрзший или
  задушенный стрим не клинит uplink остальных.

## NL exit: `:8443`

phantom-server слушает `0.0.0.0:8443` на vdsina (`89.110.109.128`). Порт
публичен: на него ходит реле, потому что `:443` этого IP из РФ фильтруется.
Перед `:443` vdsina стоит nginx stream (`ssl_preread`, SNI `tls.nl2` →
`127.0.0.1:8443`, остальное — LE-сайт), но в боевом тракте он не участвует.
Скан `:8443` без нашего клиентского серта видит только fakeapp («сайт» за
nginx по h2 и HTTP/1.1, 404 — nginx-овая страница), с отозванным сертом — алерт
`certificate_revoked`.

## SNI passthrough relay

RU-нода (`phantom-relay` на `balancer.bikini-bottom.com`, за nginx stream)
выполняет **SNI passthrough без терминации TLS**. Алгоритм:

1. Accept TCP, прочитать ClientHello целиком (до 16 КБ, склеивая несколько
   TLS-записей). Ручной парсер SNI в
   [server/relay/src/main.rs](../../../server/relay/src/main.rs) (`extract_sni`).
2. Если `SNI == expected_sni` (`tls.nl2.bikini-bottom.com`) → connect к
   `upstream_addr` (exit `:8443`), прочитанные байты отдаются как есть, дальше
   `copy_bidirectional`. TLS handshake идёт end-to-end между клиентом и
   phantom-server, relay не видит plaintext.
3. Иначе → fallback: TLS на LE-серте реле и ответ как у стокового nginx
   (404 на HTTP, 400 на мусор, HEAD без тела). Без fallback-серта (режим за
   nginx) соединение просто закрывается.

Эта схема убирает **двойное шифрование** RU-хопа. До v0.17 relay
re-encrypted каждый байт своими rustls-сессиями — это было CPU-bound узкое
место. Теперь relay I/O-bound, пропускная способность растёт ~линейно с ядром.
Лимиты, таймауты и деплой реле — в [platforms/server.md](../platforms/server.md).

## Шейпинг трафика

Модуль `shaper` удалён (см. [ADR 0001](../decisions/0001-remove-quic.md) и
историю v0.17.x). Паддинг включён только на первых 10–20 frame'ах каждого
стрима (см. [wire format](./wire-format.md)). Остальное anti-DPI строится на
других уровнях:

- **H2 multiplexing** — N стримов ⇒ размер и тайминг записей размазывается;
- **nginx SNI-passthrough** — сервер виден как стандартный HTTPS-хост;
- **Паддинг первых 10–20 кадров** каждого стрима (обе стороны) — первые
  записи не повторяют размеры внутренних пакетов (warmup удалён —
  [ADR 0019](../decisions/0019-owner-decisions-audit-2026-10.md));
- **Heartbeat'ы** (см. [wire format](./wire-format.md)) — на idle-стриме
  клиент раз в 30–60 с, сервер раз в 30–40 с, несинхронно между стримами.

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
  браузер), сервер предлагает `h2, http/1.1` и с клиентом согласует `h2`. Нет
  h1.1 fallback'а для VPN-пути: `http/1.1` — только для проб без серта
  (fakeapp отвечает как nginx).
- **VPN-путь на `:8443` — только с сертом из allowlist.** Порт публичен (на
  него ходит реле); без серта — fakeapp, с отозванным — алерт
  `certificate_revoked`.
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
