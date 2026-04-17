---
updated: 2026-04-17
---

# Handshake — H2 / mTLS

## Overview

Handshake устанавливает одну VPN-сессию, которая состоит из нескольких
параллельных TLS-стримов (обычно `2..16`, см. [wire format](./wire-format.md)).
Каждый стрим — отдельный TCP/TLS connection, проходящий через nginx
(SNI-passthrough на NL:443) и попадающий на phantom-server. Handshake делится
на два этапа: (1) стандартный mTLS — сервер получает client cert,
вычисляет SHA-256 fingerprint, проверяет keyring; (2) application handshake
в 2 байта — клиент объявляет свой `stream_idx` и `client_max_streams`, сервер
фиксирует `effective_n` сессии.

## Последовательность

```
1. Client: N параллельных TCP connect → tls.nl2.bikini-bottom.com:443
   На Android каждый сокет проходит через VpnService.protect() до connect,
   чтобы собственный tun-маршрут не зациклил трафик.

2. nginx (NL :443, ssl_preread):
   SNI == tls.nl2 → stream passthrough к 127.0.0.1:8443 (phantom-server)
   SNI другой     → LE cert на frontend + HTML-заглушка

3. phantom-server: TLS 1.3 accept + mTLS
   peer_certificates — обязательное поле:
     нет cert'а      → fakeapp::handle (H2 "сайт", см. ниже)
     cert есть       → SHA-256 DER fingerprint → allow_list lookup
     fp не в allow   → connection drop (no reply body)

4. Client → Server: 2 байта атомарно в первый write каждого TLS-стрима
   [1B stream_idx][1B client_max_streams]
   Server: read_exact(2) — если клиент v0.17 (1-byte handshake) отвалится
   естественным EOF, без timeout'а.

5. Server: effective_n = client_max.clamp(MIN_N_STREAMS=2, MAX_N_STREAMS=16)
   SessionCoordinator: attach_stream(stream_idx, mpsc::Sender)
   (один SessionCoordinator на fingerprint, Vec<Mutex<Option<Sender>>>)

6. Mimicry warmup: если is_new && stream_idx == 0 → warmup_write()
   (см. ниже). Остальные стримы подключаются сразу без warmup.

7. Frame loop: [4B frame_len][batch] штатно.
```

Код: [server/server/src/h2_server.rs](../../../server/server/src/h2_server.rs)
(server-side accept), [crates/client-common/src/tls_tunnel.rs](../../../crates/client-common/src/tls_tunnel.rs)
(client-side `write_handshake`).

## Session lookup и effective_n rebinding

Ключ сессии на сервере — **SHA-256 fingerprint client cert'а**, не `stream_idx`
и не 5-tuple. Сессии хранятся в `DashMap<fingerprint, Arc<VpnSession>>` (см.
[sessions](./sessions.md)).

Если client реконнектит отдельный стрим в существующую сессию, сервер
проверяет:

- `stream_idx < existing_session.effective_n` — иначе reject;
- `client_max != existing.effective_n` или `stream_idx` выходит за рамки старой
  сессии ⇒ старая сессия принудительно закрывается (`session.close()`), и
  создаётся новая со свежим `effective_n`. Это предотвращает pinning сессии
  в `effective_n = 2` навсегда, если первый connect был слабый bastion-путь,
  а потом клиент наростил параллелизм.

## Mimicry warmup (`server/server/src/mimicry.rs`)

Чтобы не давать клиенту сразу после TLS handshake открыть full-bandwidth поток
(DPI-tell: "handshake → instant hammering"), сервер на stream_idx==0
эмитирует стадированную последовательность frame'ов под паттерн typical
mobile HTTPS page load:

| Delay (ms) | Size (KB) | "Like"  |
|---|---|---|
| 70  | 2  | HTML |
| 330 | 8  | image 1 |
| 200 | 16 | image 2 |
| 200 | 24 | bundle |

Total ≈ 50 KB за ≈ 800 мс. Delay и size получают jitter ±25 % / ±20 % per
session, чтобы не возникло таймингового fingerprint'а. Каждый warmup-frame —
валидный batch, содержащий один 16-байтный placeholder с `buf[0] = 0x00`
(version nibble != 4), который receiver'ы дропают через IPv4-фильтр в
`tls_rx_loop` — никаких изменений в data path не требуется.

Только первый connect сессии (stream_idx==0 и `is_new == true`) запускает
warmup; последующие стримы подключаются без warmup — суммарный warmup-бюджет
фиксирован ~60 KB на сессию.

## Fakeapp fallback (`server/server/src/fakeapp.rs`)

Если на TLS-handshake клиент не предъявил cert (или он не проходит по
allowlist), сервер не отвечает 404 / blank — это DPI-tell. Вместо этого
запускается минимальный H2-сервер, имитирующий легитимный mobile backend:

| Path | Response |
|---|---|
| `/` | 200 + минимальный HTML SPA shell |
| `/favicon.ico` | 200 + 16×16 transparent PNG |
| `/robots.txt` | 200 + `User-agent: *\nDisallow: /\n` |
| `/manifest.json` | 200 + PWA manifest |
| `/api/v1/health` | 200 + `{"status":"ok","version":"1.24.0"}` |
| `/api/v1/status` | 200 + `{"uptime":…,"region":"nl2","build":"1.24.0"}` |
| `/.well-known/*` | 404 |
| default | 404 + plain text |

Headers: `server: nginx/1.24.0`, `cache-control: public, max-age=3600`,
`x-request-id: <16 random hex>`. Connection idle timeout — 30 с.

Обнаружить fakeapp со стороны probe'а без правильного cert'а невозможно:
TLS handshake, H2 negotiation и набор endpoint'ов выглядят как честный
мобильный backend.

## Invariants

- Handshake-header = **ровно 2 байта** атомарно в первом write. Никаких
  delimiters, никаких payload-specific pre-amble. Server использует
  `read_exact(2)` — partial read ⇒ drop без ответа.
- `stream_idx ∈ [0, MAX_N_STREAMS)`. Значение ≥ `effective_n` ⇒ reject.
- `client_max_streams` проходит `clamp(MIN, MAX)` на сервере. Misbehaving
  клиент не может продавить параллелизм выше `MAX_N_STREAMS`.
- Клиент drop'ит все non-IPv4 пакеты в `tls_rx_loop` через
  `is_heartbeat_packet` (version nibble != 4). Это обеспечивает прозрачный
  фильтр для mimicry placeholder'ов и heartbeat'ов — они не попадают в TUN.
- Warmup запускается ровно один раз на сессию — на `is_new && stream_idx==0`.
  Re-connect того же stream_idx после disconnect warmup НЕ повторяет.
- Empty-cert TCP connection никогда не доходит до VPN-пути — только до
  `fakeapp::handle`.

## Sources

- Server accept loop: [server/server/src/h2_server.rs](../../../server/server/src/h2_server.rs)
  (разделы `run_h2_accept_loop`, handshake read, attach_stream).
- Client write: [client-common/src/tls_tunnel.rs](../../../crates/client-common/src/tls_tunnel.rs)
  (`write_handshake`).
- Mimicry: [mimicry.rs](../../../server/server/src/mimicry.rs) (`warmup_write`,
  `SCHEDULE`, `jittered_schedule`).
- Fakeapp: [fakeapp.rs](../../../server/server/src/fakeapp.rs) (`handle`,
  endpoint table).
- Константы `MIN_N_STREAMS`, `MAX_N_STREAMS`, `n_data_streams`:
  [wire.rs](../../../crates/core/src/wire.rs).
- gitnexus: `gitnexus_query({query: "handshake stream idx"})`,
  `gitnexus_context({name: "run_h2_accept_loop"})`.
- Связанные страницы: [wire format](./wire-format.md), [transport](./transport.md),
  [sessions](./sessions.md), [crypto](./crypto.md), [glossary](../glossary.md).
- Related ADRs: [0002-noise-to-mtls](../decisions/0002-noise-to-mtls.md),
  [0003-h2-multistream-transport](../decisions/0003-h2-multistream-transport.md).
