---
name: Single-flow throughput ceiling is a flow-affine dispatch feature, not a bug
description: Why ya.ru single-flow upload caps at 15-20 Mbit while Ookla multi-flow speedtest hits 100+ Mbit on the same tunnel — and why this is by design
type: reference
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
Observed on Samsung S21 through both NL-direct and RU-bastion tunnels (2026-04-11 after v0.18 round-2 hotfixes):
- ya.ru single-flow upload: 15-19 Mbit/s
- Ookla 8-stream upload: 65-124 Mbit/s
- Same gap on multiple back-to-back runs

**Root cause:** `phantom_core::wire::flow_stream_idx(pkt, n)` hashes each packet's 5-tuple (src_ip/dst_ip/src_port/dst_port/proto) into a `stream_idx`. This is what makes v0.18 **flow-affine**: every packet of the same TCP connection always lands on the same tunnel stream, preserving intra-flow ordering and avoiding DUPACK storms.

The consequence: a single TCP upload flow pins to ONE of the 8 parallel tunnel streams for its entire lifetime. That means single-flow throughput is bounded by:
1. One `stream_batch_loop` per direction
2. One TLS socket (one ChaCha20 thread on the phone, one on the server)
3. One mpsc channel between dispatcher and batch loop (`drop_full` rises under single-hot-flow bursts because other stream channels stay empty)

Ookla hits 100+ Mbit because it opens 8-16 parallel TCP flows, which hash to different `stream_idx` values and parallelize across all cores.

**Why NOT to "fix" it by breaking flow-affinity:**
- Without pinning, packets of one TCP flow interleave across N streams. Different streams have different queue depths and TLS write latencies, so packets arrive out of order on the peer.
- TCP sees the reordering as loss, sends DUPACKs, retransmits, backs off cwnd → single-flow throughput collapses to tens of kbit/s, not improves.
- This is exactly why v0.17 round-robin got replaced by flow-affine hash in v0.18 — round-robin gave 138 Mbit/s ceiling (see reference_tx_ceiling.md).

**How to apply:** when the user (or a benchmark) reports "single-flow upload is stuck at 20 Mbit while multi-flow is fine", this is working as designed. Do not touch `flow_stream_idx`. If we ever need better single-flow throughput, the right fix is **per-stream throughput** (faster crypto, larger channel depths, zero-copy TLS write path), NOT re-distribution of one flow across multiple streams.

Inspired alternative for v0.20+: dynamic rebalancing — only when a single flow dominates the channel for >N ms, temporarily fan it out via MPTCP-style subflow splitting with explicit sequence numbers in wire format. Complex; premature now.
