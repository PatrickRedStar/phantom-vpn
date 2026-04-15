# PhantomVPN Architecture & Performance

> **Current version:** v0.18.2.
> Этот документ состоит из двух частей: актуальной архитектуры (v0.17+) и исторического раздела про userspace QUIC datapath (v0.3–v0.14), который сохранён как летопись оптимизаций. Исторический раздел не переписан — он нужен чтобы понимать, откуда растут сегодняшние дизайн-решения.

---

## Часть I — Актуальная архитектура (v0.17.0 и позже)

### Транспорт

Основной активный режим — **HTTP/2 поверх TLS 1.3 поверх TCP** с мульти-стрим шардингом.

```
Телефон ──TCP/TLS──→ [N параллельных HTTP/2 стримов] ──→ phantom-server
                       POST /v1/tunnel/0..N-1
                       Content-Type: application/grpc
                       DATA frames = [4B len][batch plaintext]
```

Каждый логический VPN-коннект состоит из `N = clamp(available_parallelism, 2..16)` параллельных TLS-сокетов. Внутри каждого сокета — H/2 стримы, но по сути мы используем один стрим на сокет (per-socket read/write loops масштабируются по ядрам CPU, см. v0.17.2).

### Почему не просто QUIC

* **TSPU дросселит QUIC/UDP** на потребительских каналах до ~80 Mbps. Тот же канал VLESS+TLS даёт 560+ Mbps.
* **Сервер на 2 vCPU упирается в single-thread CPU при шифровании UDP-пачек.** TCP-TLS с N сокетами тривиально параллелится: каждый сокет — свой `tokio::task` на своём ядре. Параллельные per-stream batch loops в v0.17.2 дали **download 138 → 625 Mbit/s** на wired тесте.
* **Handshake fingerprint.** TLS 1.3 ClientHello от браузера и от `rustls` с настроенным cipher-order практически неразличимы; QUIC ClientHello — гораздо более узкий набор возможных паттернов.

QUIC полностью удалён в v0.19.x: `normalize_transport` в парсере conn_string уже принимал только `"h2"`, UDP-сокет висел впустую. Крейты `crates/core/src/quic.rs`, `crates/core/src/congestion.rs`, `crates/server/src/quic_server.rs` и Android-fallback удалены.

### Multi-stream dispatch

Внутри VPN-сессии пакеты раскладываются по стримам с помощью **5-tuple hash** (`flow_stream_idx` в `crates/core/src/wire.rs`):

```
hash = (src_ip + dst_ip + proto) ⊕ (src_port ⊕ dst_port)
stream_idx = hash % N
```

Хеш симметричен (A→B и B→A дают тот же индекс), поэтому порядок пакетов внутри одного TCP-flow сохраняется — нет reordering. Разные TCP-flow идут через разные стримы → нет Head-of-Line blocking. Один flow упирается в один стрим и не может утилизировать все N ядер — это **by design**, см. `reference_single_flow_ceiling.md` в памяти.

### Session management

`SessionCoordinator` (в `crates/server/src/session.rs`) на клиента (индекс по fingerprint в `DashMap<String, Arc<VpnSession>>`).

* `data_sends: Vec<Mutex<Option<mpsc::Sender<Bytes>>>>` — слот на каждый `stream_idx`.
* `send_frame_rr` — round-robin батчей по живым стримам.
* `attach_stream(idx, tx)` / `detach_stream_if(...)` — при accept нового TLS-коннекта открываем слот, при EOF закрываем.
* Когда все стримы отвалились (`all_streams_down()`) — сессия удаляется из `DashMap`.
* **v0.18.1:** multi-stream handshake negotiation (client шлёт `[stream_idx, max_streams]`, effective_N = `min(server_N, client_N)`) + zombie session eviction с явным generation counter.

### Wire format

```
[4B frame_len][batch]

Batch:
  [2B pkt1_len][pkt1_bytes]
  [2B pkt2_len][pkt2_bytes]
  ...
  [2B 0x0000]           ← end-of-batch marker
  [random padding]      ← до target_size от H264Shaper
```

Константы в `crates/core/src/wire.rs`:
* `BATCH_MAX_PLAINTEXT = 65536`
* `MAX_N_STREAMS = 16`, `MIN_N_STREAMS = 2`
* `QUIC_TUNNEL_MTU = 1350`, `QUIC_TUNNEL_MSS = 1310`

### DPI-маскировка (vectors 1–12)

Текущий статус detection vectors (полный список — `reference_vpn_landscape_2026.md` в памяти проекта):

| # | Вектор | Статус |
|---|---|---|
| 1 | ALPN fingerprint | h2 (как реальный HTTPS) |
| 2 | TLS ClientHello fingerprint | rustls + заданный cipher order, rotated SNI в future work |
| 3 | Certificate chain | Let's Encrypt real cert (`tls.nl2.bikini-bottom.com`) |
| 4 | Packet size histogram | H.264 shaping (I/P-frame pattern, LogNormal padding) |
| 5 | Packet timing | Flow-affine dispatch сохраняет паттерн на per-flow базе |
| 6 | Traffic volume burst pattern | **Mimicry warmup** v0.18.0 — первые 50KB расписаны как HTML+image+image+bundle |
| 7 | Connection count per client | N сокетов вместо 1 (как gRPC / real HTTP/2 app) |
| 8 | Handshake timing | Standard TLS 1.3 1-RTT |
| 9 | Session length distribution | Стандартный TCP keepalive |
| 10 | TLS resumption patterns | Работает через rustls session cache |
| 11 | Timing jitter (frame interval) | ⏳ v0.20 roadmap |
| 12 | **Idle stream heartbeat** | ✅ v0.18.2 — каждые 20–30с случайный 40–200B dummy frame |
| 13 | Connection migration | ⏳ v0.20 roadmap |

### RU relay (SNI passthrough)

`phantom-relay` на RU-ноде `hostkey.bikini-bottom.com:443` **не терминирует TLS**:
1. Peek первые ~1.5KB TCP → парсит ClientHello → извлекает SNI
2. Если SNI == `expected_sni` → raw `tokio::io::copy_bidirectional` к NL exit (порт 443)
3. Иначе → fallback acceptor с LE cert → HTML-заглушка

TLS handshake идёт end-to-end между телефоном и phantom-server. Это убирает двойное шифрование в RU-hop — relay теперь I/O-bound, а не CPU-bound. Производительность в 222/105 Mbit/s через relay подтверждена на телефоне Galaxy.

**История:** ранее, v0.14–v0.16, relay терминировал TLS + handshake с сервером по отдельному TLS. Это упиралось в CPU RU-ноды (2 vCPU) и давало потолок ~80 Mbit/s. Переход на SNI passthrough устранил это ограничение.

### Admin HTTP API

Сервер поднимает `axum` router на `10.7.0.1:8080` (туннельный интерфейс, только через VPN). Bearer-token авторизация. Эндпоинты:
* CRUD клиентов (create/delete/enable/disable)
* Subscription management (extend/set/cancel/revoke) с автоматической проверкой каждые 60с
* Conn string export (base64url JSON)
* Time-series stats + pasive DNS dest log

Polling Android приложения обновляет UI клиентов. Telegram-бот (`tools/telegram-bot/`) — single-admin wrapper над тем же API.

### Замеры (v0.17.2, RU→NL)

| Сценарий | Download | Upload |
|---|---|---|
| Wired desktop через RU-relay | 625 Mbit/s | — |
| Samsung Galaxy → NL direct | 205 | 75 |
| Samsung Galaxy → NL через RU-relay | 222 | 105 |
| Bottleneck | ISP edge (~400 Mbit cap на canal пользователя) | — |

Узкие места по приоритету (см. `reference_bottleneck_v0172.md`):
1. `tun_uring` writer — 1 syscall/packet (не батчит)
2. RX path — 3.2× хуже TX per-CPU (наследие serial dispatcher)
3. Crypto — **не при чём**, упираемся не сюда

---

## Часть II — Исторический контекст (v0.3–v0.14, QUIC era)

> Этот раздел сохранён как есть из ранних версий документа. Описывает архитектуру и измерения времени, когда основным транспортом был QUIC и были получены базовые выводы о user/kernel overhead. Эти выводы привели к решению мигрировать на HTTP/2 в v0.15.

### Почему TUN-VPN медленнее TCP-proxy (VLESS) — анализ 2025

#### Data path сравнение

```
VLESS (TCP-proxy, ~241 Mbps):
  App → kernel TCP → socket → splice(kernel) → socket → TLS → сеть
                               ^^^^^^^^^^^^
                               ВСЁ В ЯДРЕ, 0 копий

PhantomVPN (TUN-VPN, ~98 Mbps):
  App → kernel TCP → TUN → [kernel→userspace] → batch → QUIC encrypt → [userspace→kernel] → UDP
                            ^^^ syscall+copy                            ^^^ syscall+copy

WireGuard (kernel module, 500+ Mbps):
  App → kernel TCP → TUN → [kernel module: ChaCha20 + UDP send] → сеть
                            ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                            ВСЁ В ЯДРЕ, 0 переключений в userspace
```

#### Почему PhantomVPN тогда не мог догнать VLESS

1. **TUN device**: каждый пакет пересекает kernel↔userspace boundary 4 раза (2 в каждую сторону)
2. **QUIC в userspace**: quinn обрабатывает каждый пакет в userspace (framing, encryption, congestion control)
3. **Батчинг overhead**: мелкие пакеты (TCP ACK 64 байта) несут тот же overhead что и большие (1350 байт)
4. **TCP-in-QUIC**: два congestion controller конфликтуют (решено unlimited CC, но не полностью)

#### Замеры того периода

| Конфигурация | iperf3 (tunnel) | Speedtest (end-to-end) |
|---|---|---|
| VLESS+Reality | — | 241/221 Mbps |
| PhantomVPN opt-v7 (io_uring) | 165/173 Mbps | 98/79 Mbps |
| PhantomVPN opt-v8 (H.264 shaping) | 164/150 | 125/110 |
| Raw канал (без VPN) | 1150/2300 Mbps | 562/902 Mbps |

iperf3 = sustained bulk transfer (большие пакеты), speedtest = реальный трафик (много мелких пакетов, HTTP overhead, multiple connections).

### Варианты достижения высокой скорости + DPI-стелс (рассматривались в 2025)

#### Вариант 1: AmneziaWG (ready-made)
- Модифицированный WireGuard kernel module с обфускацией
- Скорость: 500+ Mbps (kernel datapath)
- Стелс: средний (v1 заблокирован в России лето 2025, v2 пока работает)
- **Статус:** отвергнут — ненадёжный по стелсу, проигрывает со временем

#### Вариант 2: WireGuard в QUIC-обёртке
- WireGuard шифрует в ядре, thin userspace proxy оборачивает в QUIC/H3
- Скорость: ~150–200 Mbps (двойное шифрование)
- **Статус:** не попробовали — сложность пайплайна перевесила

#### Вариант 3: Kernel module + eBPF/XDP обфускация
- Свой kernel module для шифрования, XDP трансформирует пакеты
- Скорость: 1+ Gbps
- **Статус:** слишком большой риск (kernel panic = VPS offline), отвергнут

#### Вариант 4: Остаться в userspace, сменить транспорт на HTTP/2
- Собственный `rustls` + `h2` крейт, TLS 1.3 + mTLS
- **Статус:** ✅ реализовано в v0.15+, см. `other_docs/PLAN_v2_transport.md`

### Технические оптимизации, которые дали выигрыш

| Tag | Что сделано | Эффект |
|---|---|---|
| `opt-v4-no-noise` | Убрали Noise encryption, перешли на mTLS | Упрощение стэка |
| `opt-v5-unlimited-cc` | Unlimited CC (128MB window, inner TCP рулит) | +15% iperf3 |
| `opt-v6-zerocopy` | Zero-copy batch processing (in-place RX, merged TX) | +4% download |
| `opt-v7-io-uring` | io_uring TUN I/O (batch syscalls) | +10% download |
| `opt-v8-h264-shaping` | H.264 shaping (I/P-frame pattern) | Маскировка, −5 Mbps |
| `opt-v9-reality-fallback` | REALITY fallback (optional mTLS) | Стелс |
| `opt-v10-fix-pkt-loss` | Fix: packet loss in server batching | Корректность |
| `opt-v11-multiqueue-tun` | IFF_MULTI_QUEUE TUN | ~2× TUN throughput |
| `opt-v12-pipeline-collapse` | ~~Pipeline collapse 3→2 hops~~ | ❌ Регрессия, reverted |

### Инфраструктура того периода

* **vdsina (сервер):** 89.110.109.128, 2 vCPU AMD, 3.8GB RAM, AES-GCM 3.3 GB/s
* **vps_balancer (клиент, DC):** 158.160.135.140, 2 vCPU Icelake, 1.9GB RAM, AES-GCM 8.9 GB/s
* **Raw канал:** 1.15 Gbps up / 2.30 Gbps down
* **vdsina → internet:** 562/902 Mbps

---

## Часть III — Текущая инфраструктура (2026)

| Роль | Хост | DNS | Железо |
|---|---|---|---|
| NL exit | 89.110.109.128 (vdsina) | `tls.nl2.bikini-bottom.com` | 2 vCPU, 3.8GB RAM |
| RU relay | 193.187.95.128 (hostkey) | `hostkey.bikini-bottom.com` | 2 vCPU |

* sysctl-тюнинг BBR + fq + 16MB buffers на обоих хостах (`/etc/sysctl.d/99-phantom-net.conf`, см. memory `project_sysctl_tuning.md`).
* Серверный `phantom-server.service` под systemd, автоперезапуск.
* RU-relay — systemd + `sni-router.conf` на `phantom-relay`.

---

## Связанные документы

* [ROADMAP.md](ROADMAP.md) — таблица версий с замерами
* [CHANGELOG.md](CHANGELOG.md) — линейная история релизов
* [other_docs/PLAN_v2_transport.md](other_docs/PLAN_v2_transport.md) — исторический план миграции с QUIC на HTTP/2 (QUIC полностью удалён в v0.19.x)
* [ANALYZE.md](ANALYZE.md) / [ANALYZE_RESPONSE.md](ANALYZE_RESPONSE.md) — внешний аудит 2025 + наш ответ
