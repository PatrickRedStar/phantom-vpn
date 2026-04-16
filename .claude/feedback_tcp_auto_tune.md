---
name: Не выставлять SO_SNDBUF/SO_RCVBUF руками на high-BDP TCP-relay путях
description: setsockopt SO_SNDBUF/SO_RCVBUF отключает kernel TCP auto-tuning и зажимает окно, на phantom-relay это дало регресс 68→15 Mbit/s
type: feedback
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
Никогда не вызывать `setsockopt(fd, SOL_SOCKET, SO_SNDBUF|SO_RCVBUF, …)` в коде relay/proxy на Linux. Только TCP_NODELAY — его можно.

**Why:** 2026-04-11 в phantom-relay я добавил `tune_tcp_socket(fd)` который ставил SO_SNDBUF/SO_RCVBUF=4MB «для запаса». После рестарта скорость через RU-relay упала с 68/130 Mbit/s (предыдущая версия) до 15/15. Причина: как только приложение задаёт эти buffer size явно, kernel **отключает auto-tuning** и фиксирует окно на заданном значении. На high-BDP пути (RU↔NL, 48 ms RTT, physical link 1.5 Gbit/s) фиксированные 4 MiB — хуже, чем динамический auto-tune, который свободно растёт до `tcp_{r,w}mem[2]` (16 MiB) по мере того, как BBR нащупывает BDP. Убрал оба setsockopt → скорость через relay восстановилась до 138/71.

**How to apply:** В любом TCP-forwarding коде (relay, proxy, `copy_bidirectional`) трогать только TCP_NODELAY. Для управления максимальным окном — поднимать sysctl `net.core.{r,w}mem_max` и `net.ipv4.tcp_{r,w}mem[2]`, а auto-tune всё остальное сделает сам. Это правило распространяется на оба конца (accepted client socket и outbound upstream socket).
