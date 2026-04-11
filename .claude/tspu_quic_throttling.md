---
name: TSPU QUIC throttling on consumer connections
description: Verified findings about TSPU throttling QUIC/UDP on consumer (home) connections, SNI verification, and TCP bypass
type: project
---

# ТСПУ: дросселирование QUIC на потребительских каналах (март 2026)

## Подтверждённые факты

1. **ТСПУ дросселит QUIC/UDP до ~80 Mbps на потребительских каналах** (домашний интернет)
   - Телефон → vdsina напрямую через GhostStream/QUIC: 81.5/28.7 Mbps
   - `adb shell curl` через VPN: 55 Mbps download

2. **ТСПУ НЕ дросселит QUIC между датацентрами**
   - vps_balancer (Яндекс) → vdsina (Нидерланды): 700+ Mbps через GhostStream/QUIC
   - iperf3 через VPN туннель DC↔DC: 130-147 Mbps (bottleneck = серверный CPU, не ТСПУ)

3. **ТСПУ сверяет SNI с реальным IP-адресом сервера**
   - Тест: SNI `us05web.zoom.us` на IP vdsina → скорость УПАЛА с 55 до 18 Mbps
   - Несовпадение SNI и IP → ещё более жёсткое дросселирование

4. **TCP/TLS НЕ дросселируется**
   - VLESS+TLS (TCP) на том же канале: 567/691 Mbps
   - Это доказывает: bottleneck = QUIC protocol detection, не bandwidth канала

## Следствия для архитектуры

- QUIC транспорт подходит только для DC↔DC маршрутов
- Для телефон→сервер нужен TCP-based транспорт (HTTP/2, WebSocket)
- Обман через SNI spoofing невозможен (ТСПУ проверяет)
- Порт 443 vs 8443 не имеет значения для DC↔DC (тестировали: 96 vs 113 Mbps, разница в погрешности)

## Baseline замеры (2026-03-27)

| Маршрут | Транспорт | Download | Upload |
|---------|-----------|----------|--------|
| Телефон→vdsina | GhostStream QUIC | 81.5 Mbps | 28.7 Mbps |
| Телефон→vdsina | curl через VPN | 55 Mbps | - |
| DC vps_balancer→vdsina | GhostStream QUIC | 596-761 Mbps | 424-445 Mbps |
| DC iperf3 через VPN | QUIC (4 streams reverse) | 130-147 Mbps | 107 Mbps |
| Домашняя сеть | VLESS→VLESS (TCP) | 567 Mbps | 691 Mbps |
