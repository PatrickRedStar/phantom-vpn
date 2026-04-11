# PhantomVPN Performance Roadmap

> **Актуально на v0.18.2 (2026-04-12).**
> Документ состоит из двух частей: **Часть I** — текущий состав (v0.15–v0.18, HTTP/2 эра);
> **Часть II** — исторические замеры и оптимизации QUIC-эры (opt-v3..opt-v12), сохранены как есть.

Базовые замеры (канал без туннеля): Upload 1.15 Gbps, Download 2.30 Gbps.
vdsina raw internet: 562/902 Mbps. VLESS через тот же хост: 241/221 Mbps.

---

## Часть I — HTTP/2 era (v0.15+)

### Релизы и замеры

| Версия | Что внутри | Download | Upload | Примечание |
|---|---|---|---|---|
| v0.15.4 | Первый рабочий H2+TLS1.3 транспорт (single stream) | ~130 Mbit/s | ~80 Mbit/s | Переключение с QUIC на H2 как основной |
| v0.17.0 | Multi-stream (4 TLS-сокета per client) + SNI passthrough в RU relay | ~200 Mbit/s | ~100 Mbit/s | `flow_stream_idx`, flow-affine hash; relay стал I/O-bound |
| v0.17.1 | Checkpoint: H2 multi-stream закреплён, TX ceiling diagnosed | — | — | Выяснили: `session_batch_loop` serial → bottleneck |
| **v0.17.2** | **Parallel per-stream batch loops** | **625 Mbit/s** (wired) | — | Download 138 → 625 Mbit/s (**4.5×**); RU-relay wired потолок |
| v0.18.0 | Mimicry warmup (50KB HTML+image+bundle pattern первые ~2с) | 205 / 222 (direct/relay) | 75 / 105 | Закрыт detection vector 6 (burst pattern) |
| v0.18.1 | Multi-stream handshake negotiation + zombie session eviction | ≈ | ≈ | `effective_N = min(server_N, client_N)` + generation counter |
| **v0.18.2** | **Heartbeat frames (detection vector 12)** | ≈ | ≈ | 40–200B случайный dummy каждые 20–30с на idle стримах |

**Phone-side (Samsung Galaxy, v0.17.2+):** 205/75 Mbit/s direct to NL, 222/105 Mbit/s через RU relay.
Потолок телефона ограничен ISP edge (~400 Mbit/s на канал клиента) и single-flow hash (см. `reference_single_flow_ceiling.md`).

### Текущие узкие места (v0.18.2)

Из `reference_bottleneck_v0172.md`:

1. **`tun_uring` writer — 1 syscall/packet.** Пишет пакеты по одному, не батчит TUN writes. Самый жирный источник per-packet overhead.
2. **RX path в 3.2× хуже TX per-CPU.** Наследие serial dispatcher в `client_to_tun_loop`. TX уже распараллелен по стримам, RX — нет.
3. **Crypto — не при чём.** AES-GCM на сервере 3.3 GB/s, упираемся не сюда.

### v0.19+ roadmap

| # | Задача | Ожидаемый эффект | Приоритет |
|---|---|---|---|
| 1 | **Batch TUN writes** в `tun_uring` (collect N pkt → single writev/submit) | +20–40% throughput RX | 🔥 High |
| 2 | **Parallel RX path** по аналогии с TX (per-stream client_to_tun) | TX/RX паритет | 🔥 High |
| 3 | **Detection vector 11** (timing jitter на frame interval) | Стелс | Medium |
| 4 | **Detection vector 13** (connection migration — переоткрытие сокета через N мин) | Стелс | Medium |
| 5 | **Multi-origin sharding** (разные AS, не просто +IP) | Обход rate-limit на единую пятёрку | Low — сначала инфра |
| 6 | **Buffer pool** (BytesMut slab) | -30K alloc/s | Low |
| 7 | **Rotated SNI pool** (detection vector 2 полностью) | Стелс | Low |

### Detection vectors status (v0.18.2)

Полная таблица — `ARCHITECTURE.md` часть I. Кратко:

| Vector | Статус |
|---|---|
| 1–10 | ✅ закрыты |
| 11 (timing jitter) | ⏳ v0.20 |
| 12 (idle heartbeat) | ✅ v0.18.2 |
| 13 (connection migration) | ⏳ v0.20 |

---

## Часть II — QUIC era (v0.3–v0.14, исторические замеры)

> Сохранено как снимок времени, когда основным транспортом был QUIC/H3 и все оптимизации шли по userspace QUIC datapath. После ТСПУ-дросселирования QUIC/UDP в 2025 проект мигрировал на HTTP/2 (Часть I). Этот раздел не переписан — он объясняет, откуда растут сегодняшние решения.

### QUIC/H3 замеры (2025)

| Версия | Описание | iperf3 Up/Down | Speedtest | Git tag |
|--------|----------|----------------|-----------|---------|
| opt-v3 | N=4 multi-stream + Noise | ~150/~170 | — | `opt-v3-multistream` |
| opt-v4 | Убрали Noise, mTLS, probe fix | 147/132 | 76/78 | `opt-v4-no-noise` |
| opt-v5 | Unlimited CC (без BBR) | **169/152** | — | `opt-v5-unlimited-cc` |
| opt-v6 | Zero-copy batch processing | 142/**158** | — | `opt-v6-zerocopy` |
| opt-v7 | io_uring TUN I/O | 165/**173** | 98/79 | `opt-v7-io-uring` |
| opt-v8 | H.264 traffic shaping | 164/150 | **125/110** | `opt-v8-h264-shaping` |
| opt-v9 | REALITY-style fallback | — | — | `opt-v9-reality-fallback` |
| opt-v10 | Fix packet loss in server batching | 150/148 | — | `opt-v10-fix-pkt-loss` |
| opt-v11 | Multiqueue TUN (IFF_MULTI_QUEUE) | 146/152 | 117/91 | `opt-v11-multiqueue-tun` |
| opt-v12 | ~~Pipeline collapse (3→2 hops)~~ | 140/141 | **102/85 РЕГРЕССИЯ** | reverted |

### Выполненные оптимизации (QUIC эра)

| # | Что | Результат | Git tag |
|---|-----|-----------|---------|
| 1 | **Unlimited CC** (streams + 128MB window) | +15% iperf3 | `opt-v5-unlimited-cc` |
| 2 | **Zero-copy RX**: in-place batch walk | +4% download | `opt-v6-zerocopy` |
| 3 | **Zero-copy TX**: build into buf[4..] | Included in #2 | `opt-v6-zerocopy` |
| 4 | **io_uring TUN I/O** (batch syscalls) | +10% download | `opt-v7-io-uring` |
| 5 | **H.264 shaping** (I/P-frame padding) | Маскировка, -5 Mbps | `opt-v8-h264-shaping` |
| 6 | **REALITY fallback** (optional mTLS) | Стелс | `opt-v9-reality-fallback` |
| — | ~~AF_XDP для UDP~~ | Скипнули: quinn батчит sendmmsg | — |
| — | ~~QUIC datagrams~~ | Пробовали, медленнее streams | — |

### Баг: потеря пакетов в tun_to_quic_loop (исторический, фикс в opt-v10)

В серверном `tun_to_quic_loop` при батчинге пакеты для ДРУГИХ клиентов молча выбрасывались:
```rust
if d == dst_ip { ... }  // пакет для текущего клиента — берём
// else — пакет для другого клиента ПОТЕРЯН
```
Вызывало лишние TCP retransmit. Зафиксили в `opt-v10-fix-pkt-loss` — per-session queue.

### Долгосрочные варианты (из ARCHITECTURE.md 2025)

| Вариант | Скорость | Стелс | Статус |
|---------|----------|-------|--------|
| AmneziaWG (kernel module) | 500+ Mbps | Средний | ❌ Отвергнут (v1 блокируется) |
| WG-in-QUIC wrapper | ~150–200 Mbps | Высокий | ❌ Не пробовали |
| Kernel module + eBPF | 1+ Gbps | Высокий | ❌ Риск kernel panic |
| **HTTP/2 userspace** | **625+ Mbit/s** | **Высокий** | ✅ **Реализовано в v0.15+** |

### Инфраструктура QUIC-эры

- **Сервер (vdsina):** 89.110.109.128, 2 vCPU AMD, 3.8GB RAM, AES-GCM 3.3 GB/s
- **Клиент (vps_balancer):** 158.160.135.140, 2 vCPU Icelake, 1.9GB RAM, AES-GCM 8.9 GB/s
- **Канал:** 1.15 Gbps up / 2.30 Gbps down (raw)
- **vdsina → internet:** 562/902 Mbps

---

## Связанные документы

* [ARCHITECTURE.md](ARCHITECTURE.md) — текущая архитектура + исторический контекст
* [CHANGELOG.md](CHANGELOG.md) — линейная история релизов
* [ANALYZE.md](ANALYZE.md) / [ANALYZE_RESPONSE.md](ANALYZE_RESPONSE.md) — внешний аудит 2025 + ответ
* [other_docs/PLAN_v2_transport.md](other_docs/PLAN_v2_transport.md) — план миграции с QUIC на HTTP/2
