---
name: Как замерить server-side capacity phantom-vpn без мобильного клиента
description: Запустить phantom-client-linux на RU hostkey, iperf3 -c 10.7.0.1 через туннель — чистый тест phantom-server без мобильного ISP
type: reference
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
Чтобы понять где bottleneck — в phantom-server или в мобильном ISP пользователя — нужен **wired-wired тест**.

**Схема эксперимента:**
1. На vdsina (NL) уже запущен `phantom-server` и `iperf3 -s` на `:5201` (listens on *)
2. Создать временного клиента `speedtest`:
   ```
   curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '{"name":"speedtest","expires_days":1}' http://10.7.0.1:8080/api/clients
   curl -H "Authorization: Bearer $TOKEN" \
     http://10.7.0.1:8080/api/clients/speedtest/conn_string
   ```
3. Залить `target/release/phantom-client-linux` на RU hostkey через scp
4. Запустить клиент с conn-string:
   ```
   nohup /root/phantom-client-linux -v --conn-string-file /root/speedtest.conn \
     --transport h2 > /tmp/phantom-client.log 2>&1 &
   ```
5. Клиент сам настроит `tun0 10.7.0.4/24` и policy routing через `ip rule` + `table 51820`
6. Проверка туннеля: `curl https://ifconfig.me` на hostkey должен вернуть exit_ip vdsina (`91.84.109.85`)
7. Замер:
   ```
   iperf3 -c 10.7.0.1 -t 15 -P 4       # upload (server RX path)
   iperf3 -c 10.7.0.1 -t 15 -P 4 -R    # download (server TX path — user-facing)
   iperf3 -c 10.7.0.1 -u -b 500M -R    # UDP — показывает чистый PPS ceiling без TCP feedback
   ```
8. Cleanup: `pkill -9 phantom-client-linux`, `ip rule del priority 32764/32765`, `curl -X DELETE /api/clients/speedtest`

**Важные детали:**
- `phantom-client-linux` ОБЯЗАТЕЛЬНО пересобрать заново (`cargo build --release -p phantom-client-linux`) перед scp — если бинарник из прошлой эпохи, N_DATA_STREAMS мог быть другой (раньше было 8), не матчится с сервером (4) → streams 4-7 ребрасываются сервером и часть packet-хэшей уходит в никуда.
- `tls.nl2.bikini-bottom.com` резолвится в `89.110.109.128` напрямую (vdsina NL), БЕЗ relay — клиент коннектится `hostkey_ip → NL:443` через DC интернет.
- Vdsina tun интерфейс — `tun1`, не `tun0` (tun0 занят чем-то другим).
- `ip -s link show tun1` на vdsina показывает kernel TX drops на tun интерфейсе если phantom-server не успевает вычитывать из TUN fd — это прямой индикатор backpressure.

**How to apply:** Каждый раз когда пользователь жалуется на скорость и возникает подозрение "это ISP или сервер" — не гадать, прогнать эту схему за 5 минут и получить чистые server-side цифры без мобильной переменной. Если через wired-hostkey выходим на >400 Mbit/s — значит user-side bottleneck. Если ≤200 — значит server.
