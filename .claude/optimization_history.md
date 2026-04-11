---
name: PhantomVPN optimization history and lessons learned
description: Complete record of all optimizations attempted, results, and failed experiments for PhantomVPN performance tuning
type: project
---

# PhantomVPN Optimization History (March 2026)

## Results Summary

Best speedtest.net result: **125/110 Mbps** (opt-v8, H.264 shaping)
Best iperf3 result: **169/173 Mbps** (opt-v5 upload / opt-v7 download)
VLESS comparison: 241/221 Mbps
Starting point: 76/78 Mbps

## Successful optimizations

1. **opt-v4: Remove Noise encryption** — switched to mTLS. iperf3: 147/132
2. **opt-v5: Unlimited congestion controller** — replaced BBR with 128MB static window. +15%. iperf3: 169/152
3. **opt-v6: Zero-copy batch processing** — in-place RX walk, build into buf[4..]. iperf3: 142/158
4. **opt-v7: io_uring TUN I/O** — dedicated threads for TUN read/write. iperf3: 165/173. speedtest: 98/79
5. **opt-v8: H.264 traffic shaping** — pad batches to match video frame pattern. speedtest: 125/110
6. **opt-v9: REALITY fallback** — optional mTLS, DPI probes see normal website
7. **opt-v10: Fix packet loss** — server batching now handles ALL sessions, not just first dst_ip
8. **opt-v11: Multiqueue TUN** — IFF_MULTI_QUEUE, N queues per CPU. iperf3: 146/152. speedtest: 117/91

## Failed optimizations

1. **QUIC datagrams** — tried replacing streams with datagrams. Inner TCP retransmit timeout (~200ms) much slower than QUIC stream retransmit (~42ms RTT). Result: 119 Mbps, WORSE than streams (147). Reverted.
2. **QUIC datagrams + unlimited CC** — same idea with no CC. Still 116 Mbps. Fundamental issue: datagram loss requires inner TCP to retransmit. Reverted.
3. **AF_XDP for UDP** — investigated but skipped. strace showed quinn already batches UDP via sendmmsg/recvmmsg (175 calls per 15s). Expected gain: +5 Mbps for 500+ lines of eBPF. Not worth it.
4. **Pipeline collapse (opt-v12)** — merged batch+write into single task, removed frame channel. REGRESSION: 102/85 Mbps (was 117/91). Reason: Mutex<SendStream> in server serialized ALL writes through one task. Pipeline parallelism (channel between batch and write) is essential. Reverted.

## Key lessons

- **Pipeline parallelism > fewer hops**: channel between batch and write allows concurrent work. Removing it hurts even with unlimited CC.
- **Unlimited CC is the biggest single win**: inner TCP should manage congestion, not QUIC.
- **H.264 shaping is ~free**: padding costs only ~5 Mbps but adds DPI stealth.
- **io_uring helps more for real traffic than iperf3**: small packets benefit most from batched syscalls.
- **Streams beat datagrams for TCP tunneling**: QUIC retransmit (42ms) is faster than TCP retransmit timeout (200ms+).
- **TUN multiqueue doesn't help when bottleneck is QUIC pipeline**: 2 queues on 2 vCPU, no improvement.
- **Speedtest vs iperf3**: real traffic (speedtest) is 30-40% lower than iperf3 due to small packets, HTTP overhead, multiple connections.

## Optimizations v13 (2026-03-27): Phase 1-3 speed push

9. **Per-session dispatch** — replaced single tun_to_quic_loop with tun_dispatch_loop + per-session session_batch_loop. Each session has own mpsc channel + shaper. DC speedtest: 596-761 Mbps.
10. **H.264 turbo mode** — shaper skips padding after 8 consecutive frames with data > target. Eliminates waste during bulk transfers.
11. **dest_log sampling** — log every 64th packet instead of every packet. Reduced Mutex contention.
12. **Batch limit 256, channel 512** — increased from 64/128. More packets per cycle.
13. **MTU discovery** — enabled quinn MtuDiscoveryConfig on both server and client.
14. **dns_cache → DashMap** — replaced Mutex<HashMap> with lock-free DashMap.
15. **N_DATA_STREAMS 4→8** — reduced HOL blocking from 25% to 12.5%.
16. **Bytes + write_chunk** — zero-copy through channel + quinn send buffer (server + client).

## Architecture bottleneck (updated)

DC↔DC throughput is now **700+ Mbps** — CPU is no longer the bottleneck.
The real bottleneck is **ТСПУ throttling QUIC/UDP to ~80 Mbps on consumer connections**.
TCP/TLS is not throttled (VLESS proves 567 Mbps on same connection).
Next step: add HTTP/2 transport for phone→server path (see v2_transport_plan.md).

## H2 Transport: Optimization History

### v0.15.1 (baseline): 34/34 Mbps iperf3 (DC-to-DC)
- Phase 1+2 applied (TCP_NODELAY, zero-copy RX, no H264 shaping, batch by bytes)

### v0.15.2: **44.7 / 36.7 Mbps** speedtest (Android phone, TSPU path)

### v0.15.3 regression: 40.7 / 8.31 Mbps
- Upload regressed to 8 Mbps: root cause was missing TCP_NODELAY on CLIENT TCP socket
- TCP Nagle at 1ms RTT limits single-stream to ~7.5 Mbps
- Fix: add tcp.set_nodelay(true) in do_connect_and_handshake (h2_handshake.rs)

### v0.15.3 SO_RCVBUF mistake: download 68→19.5 Mbps
- Added setsockopt(SO_RCVBUF, 4MB) to client AND server sockets
- VPS rmem_max = 208KB → explicit setsockopt DISABLES TCP auto-tuning
- Auto-tuning would reach 6MB (from tcp_rmem max=6MB). Explicit set = capped at 208KB
- Fix: REMOVE SO_RCVBUF/SO_SNDBUF setsockopt. Keep TCP_NODELAY only.

### v0.15.4 (current): DC-to-DC results after all Phase 1-4
- Upload single-stream: **57.6 Mbps** (was 7.5 Mbps — 7.7× improvement!)
- Upload 4-parallel: **89 Mbps**
- Download single-stream: **66.9 Mbps**
- Download 4-parallel: **118 Mbps**
- Android phone test: PENDING (APK built, phone not connected)

### Phase 3/4 changes applied (v0.15.3-v0.15.4)
- io_uring RING_SIZE 64→256, N_READ_BUFS 16→64
- worker_threads 4→6 (Android)
- poll timeout 100ms→10ms (Android TUN reader, both H2 and QUIC paths)
- Per-stream channel 512→2048
- Pre-allocate stream_batches on server
- h2_stream_write_loop drains 15 extra frames per wakeup
- Fixed Linux H2 tunnel immediate exit bug

## Key lesson: SO_RCVBUF on VPS with small rmem_max
NEVER call setsockopt(SO_RCVBUF/SO_SNDBUF) on a socket without checking rmem_max.
On VPS (DigitalOcean, Yandex Cloud) rmem_max is typically 208KB.
Explicit setsockopt disables Linux TCP auto-tuning, capping at rmem_max instead of tcp_rmem max (6MB).
Result: auto-tuning → 6MB buffer; explicit set → 208KB → 3× lower throughput.

## Known issues / TODO (2026-03-29)

1. Admin panel создаёт только HTTP/2 подключения — нужно добавить QUIC опцию
2. `python3 keys.py` сломан — нужно исправить
3. H2 single-stream still 57 Mbps vs QUIC 96 Mbps — per-stream batching bottleneck

## v0.17.0 (2026-04-11): Multi-stream + SNI passthrough + zero-copy

**Problem:** Speedtest с телефона упирался в ~100 Mbps.
Architect + Dev-Server + Dev-Android + relay agent параллельно идентифицировали
5 причин и применили фиксы одним сквозным изменением wire-контракта.

### Root causes
1. **Single TLS stream = single CPU core** для шифрования (tokio-rustls).
   Даже с N_DATA_STREAMS=8 фактически использовался один стрим на весь клиент.
2. **Двойной TLS через RU-relay**: phone→TLS→relay→TLS→NL. Relay платил
   CPU за decrypt + reencrypt каждого байта.
3. **Аллокации в горячем пути**: `.to_vec()`, `Vec<u8>::clone` — лишние копии
   между TUN, TLS и mpsc каналами.
4. **Head-of-line blocking**: при одном TLS-стриме ретрансмит одного пакета
   блокировал весь поток.
5. **Blocking write to TUN**: `sleep(1ms)` на EAGAIN вместо `poll(POLLOUT, 10ms)`.

### Fixes (v0.17.0)

17. **N_DATA_STREAMS=4 + flow_stream_idx sharding** — клиент открывает 4 TCP/TLS
    к серверу, каждый сокет защищён `VpnService.protect()`. 5-tuple хэш
    `src_ip/dst_ip/src_port/dst_port/proto` раскладывает пакеты по стримам так,
    что порядок сохраняется внутри одного TCP flow, но разные flow параллелятся.
    Каждый TLS-стрим = свой CPU core для шифрования.
18. **1-byte stream_idx handshake** — после TLS handshake первый байт
    каждого стрима несёт `stream_idx: u8 < N_DATA_STREAMS`. Сервер
    `attach_stream(idx, sender)` на `SessionCoordinator`.
19. **SessionCoordinator + DashMap<fingerprint>** — на клиента один координатор
    с `Vec<Mutex<Option<mpsc::Sender<Bytes>>>>`. `send_frame_rr` — round-robin
    раскладка батчей. При EOF `detach_stream_if`; если все стримы down →
    сессия удаляется.
20. **SNI passthrough relay** — `phantom-relay` полностью переписан:
    peek ClientHello → парсинг SNI → если match → `tokio::io::copy_bidirectional`
    (raw TCP, без decrypt). Иначе fallback acceptor с LE-cert HTML-заглушкой.
    Удалены `upstream_sni`, `ca_cert_path`, `relay_cert_path`, `relay_key_path`,
    `upstream_insecure`. Добавлен `expected_sni`. Ручной парсер ClientHello,
    3 unit-теста. 64KB буферы в io::copy каждого направления.
21. **Zero-copy Bytes pipeline** — по всей цепочке `Bytes`/`BytesMut`:
    TUN reader → `BytesMut → .freeze() → Bytes`, dispatcher, per-stream
    batcher, TLS writer. `split_to(len).freeze()` на frame/packet.
    MSS-clamping через `try_into_mut()` с fallback. `.to_vec()` удалены.
22. **Non-blocking TUN writer** — `libc::poll(POLLOUT, 10ms)` на EAGAIN
    вместо `sleep(1ms)`. POLLHUP/POLLERR/POLLNVAL → `BrokenPipe`.

### Deployed
- `phantom-server` → `/opt/phantom-vpn/phantom-server` (vdsina, systemd)
- `phantom-relay` → `193.187.95.128:/opt/phantom-relay/phantom-relay`
  (config: `expected_sni = "tls.nl2.bikini-bottom.com"`)
- APK v0.17.0 (versionCode 40) → R5CR102X85M (Samsung S21)
- R3GL207YE8P ожидает переподключения adb для установки

### Notes
- Все 3 агента собрались чистыми (0 warnings в `cargo build --release`)
- `relay-ru` клиент в keyring больше не используется (relay делает passthrough,
  не открывает TLS к серверу от своего имени) — можно удалить при уборке
- Speedtest результаты — pending (ждём отзыва пользователя после теста)
