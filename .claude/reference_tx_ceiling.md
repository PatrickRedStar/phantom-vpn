---
name: phantom-server TX ceiling — fix истории (138→625 Mbit/s, v0.17.2)
description: Download path был зажат в 138 Mbit/s TCP из-за serial session_batch_loop; v0.17.2 разделил на N параллельных stream_batch_loop → 625 Mbit/s (4.5×)
type: reference
originSessionId: 35119652-fb27-4de2-ab65-d503064ae911
---
**До фикса (v0.17.1, 2026-04-11 утро):** wired hostkey(RU) → vdsina(NL) iperf3 через phantom-vpn:

| Направление | iperf3 mode | throughput | retrans/loss |
|---|---|---|---|
| Upload (client→server, server RX) | TCP -P 4 | 265 Mbit/s | 32k/20s |
| **Download (server→client, server TX)** | **TCP -P 4 -R** | **138 Mbit/s** | **58k/20s** |
| Download | TCP -P 1 -R | 172 Mbit/s | 46k |
| Download | UDP 500M -R | 201 Mbit/s (recv) | **60% loss** |

CPU сервера в тесте: ~30% (tokio workers 7%×2 + tun-mq 2-5%×5). Физ. линк 1.5 Gbit/s. Значит **не CPU и не сеть** — именно TX pipeline.

**Корневая причина:** `crates/server/src/vpn_session.rs::session_batch_loop` был **одним serial async task на сессию**, читавшим из одного `mpsc::Receiver<Bytes>` и ребрасывавшим батчи round-robin через `send_frame_rr` по 4 TLS-стримам. При await на `frame_tx[idx].send()` медленного стрима ВСЯ сессия блокировалась → HoL blocking, retrans, backpressure до TUN kernel → drops. Архитектурная асимметрия: клиент имел **N параллельных TX loops** + flow_hash dispatcher, а сервер — один task.

**Фикс (commit 21fab98, v0.17.2):**
1. `VpnSession::tun_pkt_tx: mpsc::Sender` → `tun_pkt_txs: Mutex<Vec<Option<Sender>>>` — по слоту на каждый stream_idx
2. Удалён `rr_counter` и `send_frame_rr`
3. `session_batch_loop(pkt_rx, session)` → **`stream_batch_loop(pkt_rx, session, stream_idx)`** — один task на каждый stream, обслуживает только свой `data_sends[stream_idx]`
4. `tun_dispatch_loop` теперь хэширует пакет через `flow_stream_idx` и шлёт его в `tun_pkt_txs[idx]` (по 5-tuple), что сохраняет порядок внутри TCP-flow
5. `h2_server.rs` / `quic_server.rs` при handshake создают `N_STREAMS` channels и спавнят N параллельных `stream_batch_loop`
6. `max_pkts_per_batch` снижен с 256 до 40 (40×1350=54KB влезает в `BATCH_MAX_PLAINTEXT=65536`) — меньше latency на формирование батча, лучше заполнение BBR pipe

**Результат (тот же wired hostkey benchmark, 2026-04-11 вечер):**

| Test | До (v0.17.1) | После (v0.17.2) | Прирост |
|---|---|---|---|
| Upload TCP ×4 (control) | 265 Mbit/s | 254 Mbit/s | стабильно ✓ |
| **Download TCP ×4 (user-facing)** | **138 Mbit/s** | **625 Mbit/s** | **4.5×** 🎯 |
| Download TCP ×1 | 172 Mbit/s | 542 Mbit/s | 3.2× |
| Download UDP 500M loss% | 60% (201 recv) | 12% (441 recv) | 5× меньше loss |

Upload не улучшился (и не должен был — RX path не трогали). Download асимметрия убрана.

**How to apply:** Если в будущих замерах download снова упадёт в ~140 — первым делом `git log crates/server/src/vpn_session.rs` и проверить, не откатили ли per-stream loops. Если кто-то думает про ещё одну перестановку session code — помнить: **symmetric client/server = key property**, не вводить обратно serial pipelines.

**Commit:** `21fab98 feat(server): parallel per-stream batch loops — download 138→625 Mbit/s (v0.17.2)`
