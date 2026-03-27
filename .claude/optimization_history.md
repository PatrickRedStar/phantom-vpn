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

## Architecture bottleneck

~125 Mbps is near the ceiling for userspace TUN-VPN over QUIC on 2 vCPU.
The remaining gap to VLESS (241 Mbps) is fundamental: TUN kernel crossings + QUIC userspace processing.
To reach 300+ Mbps need either: kernel module, more vCPU, or proxy mode (like VLESS).
