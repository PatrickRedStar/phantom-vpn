---
name: v0.17.2 measured bottlenecks (2026-04-11)
description: Real throughput/CPU/syscall measurements that locate GhostStream bottlenecks to tun_uring writer syscall rate and per-packet RX pipeline, not crypto
type: reference
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
Measured 2026-04-11 with phantom-client-linux on RU hostkey (193.187.95.128) talking directly to NL vdsina phantom-server via iperf3 inside tunnel.

## Throughput

| Path | Raw RU↔NL | Through tunnel | Tunnel overhead |
|---|---|---|---|
| Upload (client→server) | 1260 Mbit/s | 314 Mbit/s | **4.0×** |
| Download (server→client) | 1610 Mbit/s | 580 Mbit/s | 2.8× |

Baseline ratio (D/U) through tunnel is **2.07×** but raw is 1.28× → tunnel itself is asymmetric in CPU efficiency.

## CPU efficiency

- TX-path (TLS write, download): **~11.6 Mbit/s per 1% server CPU**
- RX-path (TLS read + TUN write, upload): **~3.6 Mbit/s per 1% server CPU** — 3.2× worse
- Client-side during download: one `tun-uring-write` thread hits 31–51% single-core, that's the client cap
- Server was at 100% CPU during upload (both tokio workers pegged)

## Syscall profile (server during 262 Mbit/s upload, 22s window)

- `io_uring_enter`: **353,186 (16,054/s)**
- `recvfrom`: 50,234
- `write`: 65,928
- Packet rate: ~24k pkts/s → **~0.67 io_uring_enter per packet**
  (writer_loop designed for batch=32, achieves batch≈1.5 in practice because TX drain is starved)

## Crypto is NOT the bottleneck

OpenSSL bench on NL server (KVM, AES-NI + AVX2):
- AES-128-GCM: 28.7 Gbit/s per core
- AES-256-GCM: 26.6 Gbit/s per core
- ChaCha20-Poly1305: 14.0 Gbit/s per core

Current TLS negotiates `TLS13_AES_256_GCM_SHA384`. AEAD ceiling ~50 Gbit/s on 2 cores, we're 80× below it.

## Code hotspots identified

1. `crates/core/src/tun_uring.rs:98-99` — reader copies io_uring buffer into fresh BytesMut per packet (not zero-copy despite comment)
2. `crates/core/src/tun_uring.rs:150-162` — writer submits **one Write opcode per IP packet**, then `submit_and_wait(pending.len())`. No `writev`/`IORING_OP_WRITEV`. This is the largest single cost on both sides for RX path.
3. `crates/core/src/tun_uring.rs:219-230` — multiqueue dispatcher is **round-robin**, not flow-hashed. Packets from one TCP flow can hit different TUN queues → reorder inside kernel → extra retransmits.
4. `crates/server/src/h2_server.rs:226` `tls_rx_loop` — sends each decoded IP packet as separate `tun_tx.send(pkt_bytes).await` mpsc message. No batched `send_many`.
5. `N_DATA_STREAMS = 4` on 2-core KVM box → 4 TLS decoders compete for 2 cores. Should cap to `min(N, nproc)`.

## What's NOT a bottleneck

- Crypto (see above)
- TCP_NODELAY (set on both server and client)
- Net buffers (rmem/wmem_max = 16 MB, plenty for 49 ms RTT)
- BBR/fq qdisc (already enabled on both boxes)
- AES-NI (present on both KVM hosts)

## Retransmit rate (TCP-over-TCP meltdown signal)

- Upload: 30,774 retr / 20s = 1,540/s (baseline 1% loss visible)
- Download: 52,833 retr / 20s = 2,640/s
- Raw non-tunneled upload: 2,200 retr / 15s = 147/s
  → tunneled retr rate is 10× raw → inner TCP is double-retransmitting
