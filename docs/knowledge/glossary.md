---
updated: 2026-04-17
---

# Глоссарий

Термины и константы проекта. Алфавитный порядок. Источник правды — код в
`crates/core/src/wire.rs` и `CLAUDE.md`.

---

## Constants (wire protocol)

- **`BATCH_MAX_PLAINTEXT = 65536`** — макс. размер одного фрейма внутри TLS-стрима.
- **`MIN_N_STREAMS = 2`** — минимум параллельных TLS-стримов на клиента.
- **`MAX_N_STREAMS = 16`** — жёсткий cap. Больше нельзя (bounds stream_idx byte).
- **`QUIC_TUNNEL_MTU = 1350`** — MTU TUN интерфейса. **Legacy naming** — QUIC удалён в v0.19.4, имя осталось.
- **`QUIC_TUNNEL_MSS = 1310`** — TCP MSS clamping. Legacy naming, то же что выше.

Источник: [crates/core/src/wire.rs](../../crates/core/src/wire.rs).

---

## Protocol terms

- **`effective_n`** — количество параллельных TLS-стримов в сессии.
  Вычисляется как `client_max.clamp(MIN_N_STREAMS, MAX_N_STREAMS)` после handshake.
  Клиент и сервер считают свой `n_data_streams()` независимо
  (`available_parallelism().clamp(2, 16)`), в handshake меняются байтами, сервер
  применяет clamp.

- **`flow_stream_idx`** — hash от 5-tuple (src_ip, dst_ip, src_port, dst_port, proto),
  модуль `effective_n`. Используется для раскладки пакета в конкретный TLS-стрим.
  **Цель:** сохранить порядок внутри одного TCP-flow (нет reordering) + нет HoL
  blocking между независимыми flow'ами.

- **Handshake header** — `[1B stream_idx][1B client_max_streams]`, записывается
  атомарно (`read_exact`) в первом write каждого TLS-стрима.

- **Wire frame** — `[4B frame_len][batch]`, где batch = `[2B pkt_len][pkt]` * N + `[2B 0x0000]` (end marker) + optional padding.

- **Mimicry warmup** — после handshake сервер шлёт на stream_idx==0 четыре
  placeholder-батча (2 / 8 / 16 / 24 KB) за ~800ms, имитируя H.264 I-frame pattern.
  Клиент silently drop'ит non-IPv4 пакеты.
  Источник: [server/server/src/mimicry.rs](../../server/server/src/mimicry.rs).

- **Fakeapp** — fallback H2-сервер для соединений без валидного client cert.
  Отдаёт `/`, `/favicon.ico`, `/robots.txt`, `/api/v1/{health,status}` с
  nginx-like headers. Для active-probing резистентности.
  Источник: [server/server/src/fakeapp.rs](../../server/server/src/fakeapp.rs).

- **SNI passthrough** — режим работы RU-relay (`phantom-relay`): peek первых ~1.5 KB
  TCP, парсинг ClientHello, извлечение SNI. Если SNI == expected → raw
  `copy_bidirectional` к upstream NL (TLS не терминируется!). Иначе → fallback
  acceptor с LE cert → HTML-заглушка. Убирает двойное шифрование RU-хопа.

---

## Server internals

- **`SessionCoordinator`** — один на fingerprint клиента. Хранит
  `data_sends: Vec<Mutex<Option<mpsc::Sender<Bytes>>>>` (слот на stream_idx).
  `attach_stream` при accept, `detach_stream_if` при EOF. Сессия удаляется из
  DashMap когда `all_streams_down()`.
  Источник: [server/server/src/vpn_session.rs](../../server/server/src/vpn_session.rs).

- **`send_frame_rr`** — round-robin раскладка батчей по живым стримам в рамках
  одной сессии (TUN→client направление).

- **Passive DNS cache** — сервер перехватывает UDP пакеты с `src_port=53`
  (ответы DNS) → парсит A-записи → кэширует IP→hostname в `VpnSession.dns_cache`.
  Используется в `/api/clients/:name/logs` для hostname вместо IP.

---

## Crypto / auth

- **mTLS** — единственная аутентификация клиента (v0.18+). Self-signed PhantomVPN CA
  в `/opt/phantom-vpn/config/ca.{crt,key}`. Клиенты — per-name cert в
  `/opt/phantom-vpn/config/clients/<name>.{crt,key}`. Сервер проверяет
  fingerprint SHA-256 → lookup в keyring (`clients.json`).

- **Noise** — удалён в v0.18, заменён на mTLS. В коде больше нет.

- **Server cert (admin listener)** — self-signed для `10.7.0.1`, генерится при
  первом старте в `/opt/phantom-vpn/config/admin-server.{crt,key}`. Android
  пиннит SHA-256 (TOFU).

- **LE cert** — Let's Encrypt сертификат на `tls.nl2.bikini-bottom.com`, для
  nginx SNI-passthrough frontend на :443. Плюс используется fakeapp fallback'ом.

---

## Admin / roles

- **`is_admin`** — булево поле в `clients.json` на клиента. Не в cert'е —
  динамически меняется через `POST /api/clients/:name/admin`. Bootstrap первого
  админа через `phantom-keygen admin-grant --name <n> --enable`.

- **Two admin listeners:**
  - `listen_addr` = `10.7.0.1:8080` — HTTPS + mTLS через PhantomVPN CA, для клиентов через VPN
  - `bot_listen_addr` = `127.0.0.1:8081` — plain HTTP + Bearer token, для Telegram-бота (break-glass, same-host only)

- **conn_string** (`ghs://...`) — v0.19+ URL-формат. `userinfo` = base64url(cert_pem + "\n" + key_pem). Query: `sni`, `tun` (CIDR), `v=1`. Нет `ca`, `admin`, `insecure`. Admin status — динамический, не в строке.

---

## Client runtime (shared)

- **`client-core-runtime`** — unified tunnel runtime. Единое `run(cfg, tun, settings, status_tx, log_tx)` для Linux/iOS/Android.

- **`TunIo`** — enum, как клиент читает/пишет TUN:
  - `Uring(RawFd)` — Linux helper + CLI (`phantom_core::tun_uring`)
  - `BlockingThreads(RawFd)` — Android (два thread'а)
  - `Callback(Arc<dyn PacketIo>)` — iOS (packetFlow)

- **`supervise()` FSM** — reconnect state machine. Backoff `[3, 6, 12, 24, 48, 60, 60, 60]` секунд, 8 попыток, потом Error.

- **`StatusFrame` EMA** — telemetry каждые 250ms, exponential moving average `α=0.35` для bytes/sec. Canonical wire types в `crates/gui-ipc/`.

---

## Hosts / deployment

- **`vdsina`** = `89.110.109.128` — NL exit-нода. `tls.nl2.bikini-bottom.com`. SSH alias. phantom-server здесь.
- **RU relay** = `193.187.95.128`. `hostkey.bikini-bottom.com`. phantom-relay здесь. SNI-passthrough, не терминирует TLS.

- **nginx stream frontend** — на NL:443, `ssl_preread` модуль, SNI=`tls.nl2.bikini-bottom.com` → passthrough к `127.0.0.1:8443` (phantom-server). Остальные SNI → fallback HTML.
