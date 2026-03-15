# PhantomVPN Performance Roadmap

Базовые замеры (канал без туннеля): Upload 1.15 Gbps, Download 2.30 Gbps.

## Текущее состояние

| Версия | Описание | Upload | Download | Git tag |
|--------|----------|--------|----------|---------|
| opt-v3 | N=4 multi-stream + Noise | ~150 Mbps | ~170 Mbps | `opt-v3-multistream` |
| opt-v4 | Убрали Noise, mTLS, probe fix | 147 Mbps | 132 Mbps | `opt-v4-no-noise` |
| opt-v5 | Unlimited CC (без BBR) + streams | **169 Mbps** | **152 Mbps** | `opt-v5-unlimited-cc` |

## Roadmap оптимизаций

| # | Что | Ожидаемый прирост | Статус | Git tag |
|---|-----|-------------------|--------|---------|
| 1 | ~~QUIC datagrams~~ → **Unlimited CC** (streams + no BBR) | +15% ✅ (169/152 Mbps) | ✅ Done | `opt-v5-unlimited-cc` |
| 2 | **Zero-copy RX**: `extract_batch_packets` → `Vec<&[u8]>` | +10-15% | ⏳ Pending | `opt-v6-zerocopy` |
| 3 | **Zero-copy TX**: убрать frame alloc, писать в reusable buf | +5-10% | ⏳ Pending | `opt-v6-zerocopy` |
| 4 | **Включить H.264 shaping** (сейчас target_size=0) | Маскировка, не скорость | ⏳ Pending | `opt-v7-shaping` |
| 5 | **REALITY-style fallback** (unknown client → proxy to real site) | Стелс, не скорость | ⏳ Pending | `opt-v8-reality` |
| 6 | **Нарастить железо** (если упрёмся в CPU после 1-3) | Линейный рост | ⏳ Pending | — |

## Архитектурные проблемы и как решаем

### TCP-in-QUIC HoL blocking (решает #1)
QUIC reliable stream гарантирует порядок и доставку. Когда QUIC теряет пакет,
ВСЕ туннелированные TCP-потоки стоят пока QUIC не ретрансмитнет. Это ~40-50% потерь.
QUIC datagrams = unreliable, unordered. Внутренний TCP сам разберётся с потерями.

### 3x memcpy per packet (решает #2, #3)
- TUN read: `buf[..n].to_vec()` — копия 1
- Batch build: `copy_from_slice` в pt_buf — копия 2
- Frame alloc: `vec![0u8; 4+len]` + copy — копия 3
Цель: 1 копия (TUN read → pre-allocated buf → QUIC send).

### Allocator pressure (решает #2)
`extract_batch_packets()` делает `to_vec()` на каждый пакет в батче.
64 пакета = 64 malloc. Нужно возвращать `&[u8]` ссылки в frame_buf.

## Инфраструктура

- **Сервер (vdsina)**: 89.110.109.128, 2 vCPU AMD, 3.8GB RAM, AES-GCM 3.3 GB/s
- **Клиент (vps_balancer)**: 158.160.135.140, 2 vCPU Icelake, 1.9GB RAM, AES-GCM 8.9 GB/s
- **Канал**: 1.15 Gbps up / 2.30 Gbps down (raw)
