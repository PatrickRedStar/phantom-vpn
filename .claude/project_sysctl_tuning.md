---
name: sysctl-тюнинг BBR+16MB на vdsina (NL) и hostkey (RU)
description: оба хоста phantom-vpn переведены с cubic+fq_codel+208KB на bbr+fq+16MB — конфиг в /etc/sysctl.d/99-phantom-net.conf
type: project
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
Оба хоста проекта (`89.110.109.128` — NL exit vdsina, `193.187.95.128` — RU relay hostkey) имеют постоянный network tuning:

```
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536  16777216
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
```

Файл: `/etc/sysctl.d/99-phantom-net.conf` на обоих хостах. Переживает ребут.

**Why:** 2026-04-11 при отладке скорости через RU-relay выяснилось, что дефолт VPS-шаблона — `net.core.{r,w}mem_max = 212992` (208 KB, ванильный Linux). На длинном линке client→RU→NL (RTT 48 ms) это физически зажимает TCP window до ~20 Mbit/s. Поднятие до 16 MB + переход на BBR (BBR меряет BDP pacing'ом и не глохнет от потерь, как cubic) вместе с отключением моих ручных SO_RCVBUF clamp'ов вернуло скорость с 15 до 138/71 Mbit/s через relay. Физический RU↔NL линк: iperf3 = 1.2/1.5 Gbit/s, RTT 48 ms — запас огромный, sysctl важнее, чем code optimizations.

**How to apply:** Если создаётся новая RU/NL-нода проекта — сразу копировать `/etc/sysctl.d/99-phantom-net.conf` и `sysctl -p`. Без этого любая relay-оптимизация в Rust бессмысленна — упрётся в 208 KB. Проверить можно одной командой: `sysctl net.core.rmem_max net.ipv4.tcp_congestion_control net.core.default_qdisc`.
