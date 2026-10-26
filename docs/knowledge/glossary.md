---
updated: 2026-10-26
---

# Глоссарий

Термины и константы проекта. Алфавитный порядок. Источник правды — код в
`crates/core/src/wire.rs` и `CLAUDE.md`.

---

## Constants (wire protocol)

- **`BATCH_MAX_PLAINTEXT = 65536`** — макс. размер одного фрейма внутри TLS-стрима.
- **`MIN_N_STREAMS = 2`** — минимум параллельных TLS-стримов на клиента.
- **`MAX_N_STREAMS = 16`** — жёсткий cap. Больше нельзя (bounds stream_idx byte).
- **`QUIC_TUNNEL_MTU = 1300`** — MTU TUN интерфейса. **Legacy naming** — QUIC удалён в v0.19.4, имя осталось.
- **`QUIC_TUNNEL_MSS = 1240`** — TCP MSS clamping. Legacy naming, то же что выше.
- **`HEARTBEAT_INTERVAL_{MIN,MAX}_SECS = 30, 60`** — интервал heartbeat клиента
  на idle-стриме. У сервера свой потолок — 30–40 с (`h2_server.rs`), пока в ходу
  клиенты v0.24–v0.26.22, которые рвут стрим после 45 с тишины; после их ухода
  поднять до 60.

Источник: [crates/core/src/wire.rs](../../crates/core/src/wire.rs).

---

## Protocol terms

- **`effective_n`** — количество параллельных TLS-стримов в сессии.
  Вычисляется как `client_max.clamp(MIN_N_STREAMS, MAX_N_STREAMS)` после handshake.
  Клиент и сервер считают свой `n_data_streams()` независимо
  (`available_parallelism().clamp(2, 16)`), в handshake меняются байтами, сервер
  применяет clamp.

- **`flow_stream_idx`** — симметричный hash от 5-tuple (src_ip, dst_ip, proto,
  src_port XOR dst_port; у IPv4-фрагментов — без портов), перемешанный умножением
  на `0x9E3779B1`, старшие биты × `effective_n`. Используется для раскладки
  пакета в конкретный TLS-стрим.
  **Цель:** сохранить порядок внутри одного TCP-flow (нет reordering) + нет HoL
  blocking между независимыми flow'ами.

- **Handshake header** — `[1B stream_idx][1B client_max_streams]` в первой
  записи каждого TLS-стрима; в той же записи клиент шлёт heartbeat-frame, чтобы
  запись не была ровно 2 байта. Сервер читает ровно 2 байта (`read_exact`).

- **Wire frame** — `[4B frame_len][batch]`, где batch = `[2B pkt_len][pkt]` * N + `[2B 0x0000]` (end marker) + optional padding.

- **Heartbeat** — dummy-batch с одним 40–200-байтным «пакетом» с первым байтом
  `0x00`, приёмник выбрасывает его IPv4-фильтром. Держит NAT и кормит таймеры
  живости. Клиент — раз в 30–60 с, сервер — раз в 30–40 с, свой таймер у каждого
  стрима в каждую сторону (синхронность — DPI-признак).

- **Паддинг первых кадров** — обе стороны добивают первые 10–20 frame'ов каждого
  стрима нулями после терминатора batch'а до случайного размера (клиент —
  64..1400 байт, сервер — 256..1400), чтобы первые записи не повторяли размеры
  SYN/ClientHello/DNS. Wire-формат не меняется. Warmup удалён —
  [ADR 0019](decisions/0019-owner-decisions-audit-2026-10.md).

- **Fakeapp** — fallback H2-сервер для соединений без client cert (серт не из
  allowlist получает алерт `certificate_revoked`). Отдаёт `/`, `/favicon.ico`,
  `/robots.txt`, `/api/v1/{health,status}` с nginx-like headers, тело запроса
  не читает, соединение — не дольше 45 с. Для active-probing резистентности.
  Источник: [server/server/src/fakeapp.rs](../../server/server/src/fakeapp.rs).

- **SNI passthrough** — режим работы RU-relay (`phantom-relay`): прочитать
  ClientHello (до 16 КБ, из нескольких TLS-записей), извлечь SNI. Если SNI ==
  expected → прочитанные байты отдаются exit'у как есть, дальше
  `copy_bidirectional` (TLS не терминируется!). Иначе → fallback на LE-серте
  реле, ответ как у стокового nginx (404/400). Убирает двойное шифрование RU-хопа.

---

## Живучесть клиента (`client-core-runtime`)

- **Stale** — 75 с без единого принятого frame'а (heartbeat считается). Только
  UI («канал замолчал»), ядро ничего не рвёт.
- **Мёртвый стрим** — 90 с без единого frame'а (`RX_IDLE_TIMEOUT_SECS`) или
  30 с неподтверждённых данных (`TCP_USER_TIMEOUT`). Любой мёртвый стрим = `Degraded`.
- **Переоткрытие одного стрима** — умерший стрим переподключается один
  (случайная пауза 1–10 с, при повторных неудачах — по `BACKOFF_SECS` до 30 с),
  сервер пристыковывает его к живой сессии по fingerprint. Вся сессия
  переподключается, только если мертвы все N (≥ 3 с), после сна устройства
  (скачок wall-clock > 60 с) или при фатальной ошибке.
- **Фатальная ошибка** — `ConnState::Error` с причиной в `last_error`: отзыв
  доступа (алерт `certificate_revoked`), истечение доступа, ошибки дат серта
  сервера (сбитые часы), кривой профиль, закрытый TUN. Остальное — сетевые
  ошибки, ретрай бесконечный. Обёртки (Kotlin/Swift/Linux GUI) туннель на
  переходных состояниях не перезапускают; Linux CLI — исключение, одна попытка
  и перезапуск за systemd — [ADR 0018](decisions/0018-rust-owns-reconnect.md).
- **`tx_dropped`** — счётчик пакетов, выброшенных диспетчером TUN→стрим:
  стрим мёртв или его очередь так и не освободилась за отсрочку 50 мс. Живёт в
  телеметрии ядра, пишется в лог `teardown.start`.

---

## Server internals

- **`SessionCoordinator`** — один на fingerprint клиента. Хранит
  `data_sends: Vec<Mutex<Option<mpsc::Sender<Bytes>>>>` (слот на stream_idx).
  `attach_stream` при accept, `detach_stream_if` при EOF. Сессия удаляется из
  DashMap когда `all_streams_down()`.
  Источник: [server/server/src/vpn_session.rs](../../server/server/src/vpn_session.rs).

- **`send_frame_rr`** — round-robin раскладка батчей по живым стримам в рамках
  одной сессии (TUN→client направление).

- **`release-server`** — cargo-профиль серверных бинарей (`phantom-server`,
  `phantom-keygen`, `phantom-relay`): наследует `release`, но `panic = "unwind"`
  — паника в одном соединении не роняет процесс. Бинари — в
  `target/release-server/`; клиенты остаются на `release` с `panic = "abort"`.

- **Allowlist** — включённые клиенты из `clients.json`, проверяются прямо в
  TLS-рукопожатии. Fail-closed: путь задан и список пуст — никого не пускать;
  нечитаемый файл на старте — сервер не стартует. Перечитывается раз в минуту и
  по SIGHUP.

- **Passive DNS cache** — сервер перехватывает UDP пакеты с `src_port=53`
  (ответы DNS) → парсит A-записи → кэширует IP→hostname в `VpnSession.dns_cache`.
  Используется в `/api/clients/:name/logs` для hostname вместо IP.

---

## Crypto / auth

- **mTLS** — единственная аутентификация клиента (v0.18+). Self-signed PhantomVPN CA
  в `/opt/phantom-vpn/config/ca.{crt,key}`. Клиенты — per-name cert в
  `/opt/phantom-vpn/config/clients/<name>/client.{crt,key}`. Сервер проверяет
  fingerprint SHA-256 → lookup в keyring (`clients.json`).

- **Noise** — удалён в v0.18, заменён на mTLS. В коде больше нет.

- **Server cert (admin listener)** — self-signed для `10.7.0.1`, генерится при
  первом старте в `/opt/phantom-vpn/config/admin-server.{crt,key}`. Android
  пиннит SHA-256 (TOFU).

- **LE cert** — Let's Encrypt сертификат на `tls.nl2.bikini-bottom.com`, его
  предъявляет phantom-server (и fakeapp). Сервер читает его только при старте —
  на vdsina нужен `renew_hook` с рестартом.

---

## Admin / roles

- **`is_admin`** — булево поле в `clients.json` на клиента. Не в cert'е —
  динамически меняется через `POST /api/clients/:name/admin`. Bootstrap первого
  админа через `phantom-keygen admin-grant --name <n> --enable`.

- **Two admin listeners:**
  - `listen_addr` = `10.7.0.1:8080` — HTTPS + mTLS через PhantomVPN CA, для клиентов через VPN
  - `bot_listen_addr` = `127.0.0.1:8081` — plain HTTP + Bearer token, для Telegram-бота (break-glass). Bearer принимается только от loopback-пира

- **conn_string** (`ghs://...`) — v0.19+ URL-формат. `userinfo` = base64url(cert_pem + "\n" + key_pem). Query: `sni`, `tun` (CIDR), `v=1`. Нет `ca`, `admin`, `insecure`. Admin status и подписка — динамические, из `/api/me` (`is_admin`, `enabled`, `expires_at`), не в строке.

---

## Client runtime (shared)

- **`client-core-runtime`** — unified tunnel runtime. Единое `run(cfg, tun, settings, status_tx, log_tx)` для Linux/iOS/Android.

- **`TunIo`** — enum, как клиент читает/пишет TUN:
  - `Uring(RawFd)` — Linux helper + CLI (`phantom_core::tun_uring`)
  - `BlockingThreads(RawFd)` — Android (два thread'а)
  - `Callback(Arc<dyn PacketIo>)` — iOS (packetFlow)

- **`supervise()` FSM** — reconnect state machine. При `auto_reconnect` ретраит бесконечно: пауза по категории ошибки (1 с после RST, 2 с после тишины, 5 с без сети), пол — `BACKOFF_SECS = [1, 2, 5, 10, 20, 30]`, джиттер до +25 %, счётчик сбрасывается после сессии ≥ 30 с. `Error` — только фатальные причины (см. выше).

- **`StatusFrame` EMA** — telemetry каждые 250ms, exponential moving average `α=0.35` для bytes/sec. Canonical wire types в `crates/gui-ipc/`.

---

## Hosts / deployment

- **`vdsina`** = `89.110.109.128` — NL exit-нода. `tls.nl2.bikini-bottom.com`. SSH alias. phantom-server здесь, на `:8443` (`:22` и `:443` из РФ фильтруются).
- **RU relay** = `balancer.bikini-bottom.com` (`158.160.135.140`, SSH `vps_balancer`). phantom-relay на `127.0.0.1:5443` за nginx stream (`ssl_preread`), upstream `89.110.109.128:8443`. SNI-passthrough, не терминирует TLS. Актуальная таблица хостов — `CLAUDE.md`.
