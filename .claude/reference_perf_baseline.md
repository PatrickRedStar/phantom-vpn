---
name: Baseline скорости phantom-vpn (обновлено 2026-04-11 вечер, v0.17.2)
description: iperf3 RU↔NL, wired hostkey через туннель, end-to-end через телефон — цифры «здорового» состояния после parallel per-stream batch loops fix
type: reference
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
Все замеры 2026-04-11 после sysctl-тюнинга BBR+fq+16MB **И** server TX fix (v0.17.2).

**Физический линк RU(hostkey)↔NL(vdsina):**
- iperf3 RU→NL: 1.22 Gbit/s (peak 1.32)
- iperf3 RU←NL: 1.56 Gbit/s (peak 1.77)
- RTT: 48.0 ms

**Wired server-side через phantom-vpn (hostkey client → vdsina server, direct, без мобильного ISP):**
- Upload TCP ×4: 254 Mbit/s
- **Download TCP ×4: 625 Mbit/s** (было 138 до v0.17.2)
- Download TCP ×1: 542 Mbit/s
- Download UDP 500M: 441 Mbit/s (recv), 12% loss

**End-to-end через телефон Galaxy S21 (spongebob client, SM-G991B):**
- **Direct NL (v0.17.2): 205/75 Mbit/s** (было ~125/124 до фикса)
- **Через RU relay (v0.17.2), speedtest.net: 250/117 Mbit/s** ← current best на мобильном ISP
- **Через RU relay, ya.ru/internet: 287/33 Mbit/s** — upload 3.5× просадка vs speedtest
- Reference без VPN (ya.ru/internet): **500+ / 500+ Mbit/s** (RAN uplink здоровый)

**Upload asymmetry speedtest vs ya.ru — НЕ баг сервера.** Проверено 2026-04-11 вечер:
tls_rx_loop × 4 параллельных streams → single `tun_tx` mpsc (4096 depth) → dispatch
thread round-robin → N io_uring TUN writer threads. Funnel + dispatch это refcount
clone `Bytes`, не CPU-bound. Узкое место НЕ в phantom-server.

Причина — **TCP-in-TCP meltdown на single-stream тестах**: speedtest.net поднимает
8-16 параллельных TCP streams, ya.ru/internet — 1-2. Inner CC (cubic/bbr на phone)
видит outer tunnel jitter как loss → cwnd схлопывается → upload в 1 stream упирается
в ~30 Mbit. 117/4 ≈ 30 ≈ 33 — соотношение параллельных stream'ов совпадает.
Проявляется сильнее на upload потому что mobile RAN uplink имеет higher jitter/burst.

Вылечить можно только сменой транспорта на **UDP-datagram (QUIC datagram frames
как в Hysteria2/WG)** — архитектурный ход, не фикс. В рамках TCP-туннеля это потолок.

**Что это значит для оценки регрессий:**
- Wired server может выдать 625, телефон выдаёт ~250 → 375 Mbit/s съедает мобильный ISP пользователя. Это НЕ наш bottleneck.
- Если телефон упадёт ниже ~200 на speedtest через relay — проверять свою сторону. Если упадёт wired hostkey bench ниже 500 Mbit/s — искать регресс в `crates/server/src/vpn_session.rs` (особенно в области per-stream batch loops).
- Relay через hostkey (250/117) на speedtest **выше** direct (205/75) на download — потому что RU-хоп ближе к пользовательскому ISP, а до NL путь длиннее. Это ожидаемо на RU-мобильном.
- **НЕ делать регрессионные выводы по ya.ru/internet upload** — у него single-stream методика, любой TCP туннель там упирается в ~30-40 Mbit. Для регрессий смотреть на speedtest (parallel streams).

**How to apply:** При отладке скорости всегда сначала смотреть на эти цифры. Если все 4 числа упали одновременно — проверить sysctl (`sysctl net.core.rmem_max net.ipv4.tcp_congestion_control`). Если упало только через relay — phantom-relay или RU-node. Если только direct — phantom-server.
