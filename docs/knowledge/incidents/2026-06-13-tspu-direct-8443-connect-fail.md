---
title: Android не коннектится под ТСПУ — all-or-nothing 8-stream connect на прямом foreign-IP:8443
date: 2026-06-13
type: incident
severity: high (пользователь не может подключиться без нескольких попыток)
detection: live-расследование по adb logcat + серверным логам
fixed-in: v0.27.x (concurrent-open + per-stream retry + RX-idle margin)
---

# 2026-06-13 — ТСПУ silent-drop + all-or-nothing connect

## TL;DR

Android-клиент (Samsung S25, RU-сеть) подключался к профилю `poland.bikini-bottom.com` (server `82.38.66.138:8443`, SNI `poland.bikini-bottom.com`) только **с 4-й попытки**. Каждая неудачная попытка зависала ровно на **15.000 c** на одном из 8 параллельных TLS-стримов, потом вся попытка рушилась и шёл reconnect.

**Root cause — ТСПУ, усиленный архитектурным дефектом клиента.** ТСПУ вероятностно (p≈10–20% на стрим) молча блэкхолит handshake **части** из 8 одновременных TLS-стримов к иностранному IP на нестандартном порту `:8443`. Клиент открывал стримы **последовательно** и при первом же таймауте ронял всю попытку через `?` (all-or-nothing), выбрасывая уже поднятые стримы. Вероятность провала попытки = `1−(1−p)^8` ≈ 57–83%.

Вторично: death-watcher с `RX_IDLE_TIMEOUT_SECS=45`, **равным** `HEARTBEAT_INTERVAL_MAX_SECS=45` → нулевой зазор → живой, но тихий туннель убивался по одному стриму (видно в live: `degraded 3/8`).

Профиль вдобавок ходил **напрямую на иностранный IP, минуя RU SNI-passthrough relay** (vps_balancer :443→:5443), который вся анти-DPI архитектура и существует чтобы использовать.

## Решающее доказательство (серверные логи vps_poland)

На каждой провальной попытке `phantom-server` принял **ровно столько стримов, сколько клиент успел поднять до 15-c таймаута**, а пропавшие стримы **не оставили ни одной строки** на сервере (ни `Authenticated`, ни handshake-fail, ни RST):

| Попытка (UTC) | Клиент успел | Сервер увидел | Встал на |
|---|---|---|---|
| 15:45:37 | stream 0 | только 0/8 | stream 1 (+15.0 c) |
| 15:45:56 | streams 0–6 | 7/8 | stream 7 (+15.0 c) |
| 15:46:16 | streams 0–3 | 4/8 | stream 4 (+15.0 c) |
| 15:46:37 | все 8 | 8/8 + `Session registered` | — CONNECTED |

ClientHello пропавших стримов физически не доехали → silent mid-path blackhole = подпись ТСПУ. Сервер был здоров (load 0.20, 0 рестартов, нет conntrack/OOM/rate-limit). Сервер **невиновен**.

Успешный handshake = доли секунды, провальный = ровно `HANDSHAKE_TIMEOUT` (15 c), без RST → не отказ, а чёрная дыра. Падал **каждый раз другой** стрим (1→7→4) = вероятностный дроп, не дефект индекса/серта (`mtls.cert_verify=ok` на всех завершённых). Источники приходили с трёх разных egress-IP под одним fingerprint `88bd403ea6799ea5` (см. открытые вопросы).

## Хронология live-сессии (MSK)

| Время | Событие |
|---|---|
| 18:45:37 | старт по смене сети (Wi-Fi). 4 попытки, провалы на stream 1/7/4 по +15 c, backoff 1/2/5 c |
| 18:46:39 | `h2.ready n_streams_open=8` — CONNECTED (4-я попытка) |
| 18:51:27 | `no RX for 45s — treating tunnel as dead` → kill stream 0 |
| 18:52:30 | ВСЕ стримы убиты разом: `unexpected EOF / no close_notify` (RST-подпись, активный teardown ТСПУ) → reconnect-шторм (попытки 4–7, backoff до 30 c) |
| 18:54:51 | переподключился (session b7324b21) |
| 18:56:18–18:57:32 | стримы умирают по одному по `no RX 45s` → `death watcher: degraded 3/8` |

## Fix (v0.27.x, только клиентский core)

`crates/client-core-runtime/src/supervise.rs` + `lib.rs` + коммент в `telemetry.rs`:

1. **Concurrent-open** — stream 0 первым (сохранён warmup/coordinator-инвариант сервера), остальные `1..N` параллельно через `tokio::task::JoinSet`. Общее время handshake ≈ самый медленный стрим, а не сумма.
2. **Per-stream retry** — упавший стрим переоткрывается до 2× на свежем сокете с джиттером ~50–149 мс (idx подмешан для де-корреляции), вместо сноса всей попытки. Эффективный дроп p → ~p³.
3. **RX-idle margin** — `RX_IDLE_TIMEOUT_SECS 45 → 75`, строго выше `HEARTBEAT_INTERVAL_MAX=45` → живой тихий туннель не убивается ложно.
4. **M1** — raw TCP `socket.connect` на Android обёрнут в `timeout(HANDSHAKE_TIMEOUT)`: без этого при SYN-blackhole connect виснет на kernel SYN_RETRIES (~75–130 c) и ретраи бесполезны.
5. **debug_assert** на `position==stream_idx` после сборки — защита data-plane от будущего partial-quorum.

### Что НЕ делали и почему (важно)

**Partial-quorum (Connected при K<N) — отвергнут как небезопасный.** Data-plane маршрутизирует `flow_stream_idx(pkt) % n_streams → tx_senders[idx]` (блокирующий канал), а сервер хеширует обратный трафик по тому же `effective_n` и ждёт все стримы. Подняться с K<N = терять весь флоу, захешенный в отсутствующие индексы, + заморозить TX на backpressure. Это потребовало бы переписать диспетчер + сервер. **Контракт «все N обязательны на Connected» сохранён.** Quorum — возможная фаза 2 после прод-телеметрии.

**N стримов НЕ понижали** (= числу CPU-ядер): resilience решается устойчивым коннектом, не уменьшением N.

## Открытые вопросы (не доказано статикой — нужен on-device/pcap)

1. **Нестабильный egress-IP.** Стримы пришли с трёх source-IP под одним fingerprint: `153.80.241.163` (RU NAT) → `82.38.66.138` (WAN самого сервера, hairpin?!) → `158.160.135.140` (= vps_balancer relay). Почему — не объяснено.
2. **Relay реально надёжнее или повезло?** Единственный полный успех (attempt3) пришёл через `158.160.135.140`. Выборка из одного — статистически слабо.
3. **Инвариант warmup (#2) ослаблен.** stream-0-first теперь best-effort (сервер выбирает coordinator гонкой dashmap) — non-zero стрим может выиграть и пропустить DPI-warmup → сдвиг fingerprint (не разрыв). Робастный фикс — **серверный** (только `stream_idx==0` создаёт сессию), отдельной задачей.

### План pcap (dual-side)

Снять одновременно на телефоне (PCAPdroid/tcpdump через root) и на сервере (`tcpdump -i ens1 host <client> and port 8443`) во время серии Connect под реальным ТСПУ:
- подтвердить, что SYN/ClientHello пропавших стримов **уходят с телефона**, но **не приходят на ens1** (= дроп в транзите, не на клиенте);
- сравнить `:8443` vs `:443` и direct vs relay-путь на одной сессии — изолировать вклад порта/IP от вклада burst;
- проверить, реально ли ретраи срабатывают в полезном окне на Android (M1).

## Немедленный workaround (без релиза)

Перевыписать профиль `poland` через RU-relay `:443` (vps_balancer) или хотя бы перенести exit на `:443` — убирает первичный DPI-дискриминатор (иностранный IP + не-443 порт). Требует серверной стороны (relay `expected_sni` + upstream + cert-pinning под poland — сейчас relay знает только NL).

## Связанное

- ADR 0002/0003 (look-like-HTTPS, SNI passthrough), `docs/knowledge/architecture/transport.md`
- ADR 0009 (TSPU silent-drop, half-open zombie, death-watcher), ADR 0010 (docker deploy)
- Сервер warmup/coordinator: `server/server/src/h2_server.rs:181-235,255`
