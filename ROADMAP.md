# PhantomVPN Performance Roadmap

Базовые замеры (канал без туннеля): Upload 1.15 Gbps, Download 2.30 Gbps.
vdsina raw internet: 562/902 Mbps. VLESS через тот же хост: 241/221 Mbps.

## Текущее состояние

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

## Выполненные оптимизации

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

## Следующие оптимизации (из внешнего анализа ANALYZE.md)

| # | Что | Ожидаемый эффект | Сложность | Статус |
|---|-----|------------------|-----------|--------|
| 7 | **FIX: потеря пакетов в серверном batching** | Корректность + меньше retransmit | Низкая | 🔨 In progress |
| 8 | **Multiqueue TUN** (`IFF_MULTI_QUEUE`) | ~2x TUN throughput на 2+ CPU | Средняя | ⏳ Pending |
| 9 | ~~Схлопнуть async pipeline~~ | **Регрессия** (102/85 vs 117/91). Mutex serializes writes. | ❌ Reverted | — |
| 10 | **Buffer pool** (BytesMut slab) | -30K alloc/s | Средняя | ⏳ Pending |

### Баг #7: потеря пакетов в tun_to_quic_loop

В серверном `tun_to_quic_loop` при батчинге пакеты для ДРУГИХ клиентов молча выбрасываются:
```rust
if d == dst_ip { ... }  // пакет для текущего клиента — берём
// else — пакет для другого клиента ПОТЕРЯН
```
Вызывает лишние TCP retransmit. Фиксить: складывать чужие пакеты обратно или использовать per-session queue.

### Multiqueue TUN (#8)

Текущий код: `IFF_TUN | IFF_NO_PI` — один FD.
Нужно: `IFF_TUN | IFF_NO_PI | IFF_MULTI_QUEUE` — N FD, по одному на CPU.
Каждый FD обрабатывается своим io_uring worker.

### Async pipeline reduction (#9)

Текущий TX: `TUN → uring → mpsc → dispatcher → mpsc → batch → mpsc → write → QUIC` (4 hops)
Цель: `TUN → uring → dispatcher+batch+write → QUIC` (1 hop)

## Долгосрочные варианты (из ARCHITECTURE.md)

| Вариант | Скорость | Стелс | Усилия |
|---------|----------|-------|--------|
| AmneziaWG (kernel module) | 500+ Mbps | Средний | 1 день |
| Kernel module + eBPF | 1+ Gbps | Высокий | 2-3 мес |
| Текущий PhantomVPN (userspace) | ~125 Mbps | Высокий | Есть |

## Инфраструктура

- **Сервер (vdsina)**: 89.110.109.128, 2 vCPU AMD, 3.8GB RAM, AES-GCM 3.3 GB/s
- **Клиент (vps_balancer)**: 158.160.135.140, 2 vCPU Icelake, 1.9GB RAM, AES-GCM 8.9 GB/s
- **Канал**: 1.15 Gbps up / 2.30 Gbps down (raw)
- **vdsina → internet**: 562/902 Mbps
