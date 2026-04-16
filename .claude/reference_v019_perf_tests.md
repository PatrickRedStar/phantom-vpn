---
name: v0.19 perf hypothesis testing (2026-04-12)
description: A/B test results for forwarder elimination, tun_uring writer batch, zero-copy RX — all disproven or inconclusive on hostkey
type: reference
originSessionId: 86cd0a63-4677-4164-83d8-fdbac6637377
---
Tested 2026-04-12 on hostkey (RU, 2-core) → vdsina (NL, 2-core), iperf3 through H2 tunnel.

## Hypothesis 1: Eliminate RX forwarder hop (client-linux)

Removed intermediate `rx_sink_tx → forwarder task → tun_pkt_tx` chain, replaced with direct `tls_rx_loop → tun_pkt_tx` (channel 8192).

**Result: NO measurable improvement, possible slight regression.**

| Metric | Baseline | Optimized |
|--------|----------|-----------|
| DL 4-flow avg | 687-714 Mbit/s | 664-799 Mbit/s |
| DL 1-flow avg (3 runs) | 515 Mbit/s | 475 Mbit/s |
| DL retransmits | 22K-78K | 24K-113K |

Single-flow showed -8% regression. 4-flow results within noise. **Reverted.**

## Hypothesis 2: tun_uring writer batch optimization

**NOT TESTED — Architect ruled it out pre-implementation.**

Math: at 24K pkt/s, batch ~1.5, io_uring_enter 16K/s × ~1μs = 16ms/s = 1.6% CPU. TUN writes are synchronous kernel memcpy, completions instant. Increasing batch size would reduce 1.6% overhead — unmeasurable. Red herring.

## Hypothesis 3: Zero-copy client tls_rx_loop

**NOT TESTED — expected gain too small to measure.**

`Bytes::copy_from_slice` at 24K pkt/s × 1350 bytes = 32 MB/s allocations. On modern CPU with L1/L2 hot, this is ~5-10μs per batch. Expected savings: 1-3% CPU, ~10-20 Mbit/s. On a link with 15% iperf3 variance, this is unmeasurable.

## Real bottleneck analysis (from Architect agent)

1. **TLS encryption parallelism**: 4 TLS streams on 2 cores = oversubscribed. n_data_streams() returns 2 on hostkey, so this is already optimal (MIN_N_STREAMS=2).
2. **TCP-over-TCP dynamics**: 48ms RTT, inner TCP cwnd ramp takes 8-9s to reach steady-state. Single-flow ceiling ~475 Mbit/s due to congestion feedback delay.
3. **Raw link utilization**: 700/1560 Mbit/s = 45% — tunnel overhead (TLS framing + batch wire format + retransmits) consumes 55%. This is structural for TCP-in-TLS.
4. **Server tun_tx fan-in contention**: All N tls_rx_loops share one mpsc channel. At high pps this serializes. However, this affects upload (server RX), and upload is already limited by client-side encryption.

## Conclusion

The code is near-optimal for the current 2-core-to-2-core TCP-in-TLS architecture. Further throughput gains require architectural changes:
- More cores on either end
- UDP transport (eliminates TCP-over-TCP meltdown)
- Fewer retransmits (would need QUIC datagram frames like Hysteria2)

**How to apply:** Don't chase micro-optimizations on the hot path. Focus effort on stealth (detection vectors) and UX features instead.
