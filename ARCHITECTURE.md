# PhantomVPN Architecture & Performance Analysis

## Почему TUN-VPN медленнее TCP-proxy (VLESS)

### Data path сравнение

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

### Почему PhantomVPN не может догнать VLESS

1. **TUN device**: каждый пакет пересекает kernel↔userspace boundary 4 раза (2 в каждую сторону)
2. **QUIC в userspace**: quinn обрабатывает каждый пакет в userspace (framing, encryption, congestion control)
3. **Батчинг overhead**: мелкие пакеты (TCP ACK 64 байта) несут тот же overhead что и большие (1350 байт)
4. **TCP-in-QUIC**: два congestion controller конфликтуют (решено unlimited CC, но не полностью)

### Замеры реальной скорости

| Конфигурация | iperf3 (tunnel) | Speedtest (end-to-end) |
|---|---|---|
| VLESS+Reality | — | 241/221 Mbps |
| PhantomVPN opt-v7 (io_uring) | 165/173 Mbps | 98/79 Mbps |
| Raw канал (без VPN) | 1150/2300 Mbps | 562/902 Mbps |

Разница iperf3 vs speedtest: iperf3 = sustained bulk transfer (большие пакеты),
speedtest = реальный трафик (много мелких пакетов, HTTP overhead, multiple connections).

## Варианты достижения высокой скорости + DPI-стелс

### Вариант 1: AmneziaWG (ready-made)
- Модифицированный WireGuard kernel module с обфускацией
- Скорость: 500+ Mbps (kernel datapath)
- Стелс: средний (v1 заблокирован в России лето 2025, v2 пока работает)
- Усилия: 1 день
- Риск: будет заблокирован как только DPI обучится

### Вариант 2: WireGuard в QUIC-обёртке
- WireGuard шифрует в ядре, thin userspace proxy оборачивает в QUIC/H3
- Скорость: ~150-200 Mbps (двойное шифрование: WG ChaCha20 + QUIC AES-GCM)
- Стелс: высокий (настоящий QUIC/H3)
- Усилия: 2-3 недели

### Вариант 3: Kernel module + eBPF/XDP обфускация
- Свой kernel module для шифрования
- eBPF/XDP трансформирует пакеты в ядре (выглядят как QUIC)
- Скорость: 1+ Gbps
- Стелс: высокий
- Усилия: 2-3 месяца, требует kernel development опыта
- Риск: баги = kernel panic

### Вариант 4: Текущий PhantomVPN (userspace QUIC)
- TUN + QUIC streams + io_uring
- Скорость: 98 Mbps end-to-end (потолок ~200-250 Mbps с AF_XDP)
- Стелс: хороший (QUIC/H3), будет отличный с H.264 shaping
- Уникальное преимущество: H.264 traffic shaping маскирует под видеозвонок
- QUIC/H3 нельзя заблокировать без поломки интернета

## Рекомендуемая стратегия

1. **Сейчас**: AmneziaWG для скорости (пока работает)
2. **Fallback**: PhantomVPN с H.264 shaping + REALITY fallback (незаблокируемый)
3. **Долгосрочно**: Kernel module + eBPF (если нужен гигабит + стелс)

## Технические детали оптимизаций

### Что сделано
- opt-v4: убрали Noise encryption, перешли на mTLS
- opt-v5: unlimited congestion controller (128MB window, inner TCP рулит)
- opt-v6: zero-copy batch processing (in-place RX, merged TX buffer)
- opt-v7: io_uring TUN I/O (batch syscalls)

### Что ещё можно сделать
- AF_XDP для UDP (bypass kernel networking stack)
- H.264 shaping (маскировка трафика под видеозвонок)
- REALITY-style fallback (защита от active probing)
- Увеличение N_DATA_STREAMS (больше параллелизма)

### Инфраструктура
- vdsina (сервер): 89.110.109.128, 2 vCPU AMD, 3.8GB RAM, AES-GCM 3.3 GB/s
- vps_balancer (клиент): 158.160.135.140, 2 vCPU Icelake, 1.9GB RAM, AES-GCM 8.9 GB/s
- Raw канал: 1.15 Gbps up / 2.30 Gbps down
- vdsina → internet: 562/902 Mbps
