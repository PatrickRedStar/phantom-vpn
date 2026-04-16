---
name: Multi-origin shard design notes for v0.19+
description: How flow-level sharding reassembles traffic, why 5-IPs-on-one-VPS fails, what real multi-origin needs
type: reference
originSessionId: aaf047bc-f5b0-4288-83fd-06f31a1cdbff
---
Discussed 2026-04-11 with the user. Parked as v0.19+ work — not touching now, but the design shape is settled.

# Reassembly: flow-level, not packet-level

**Never split a single TCP flow across multiple exit servers.** NAT-mapping divergence, source-IP changes mid-stream, and DUPACK storms make it unworkable.

Granularity = one inner TCP connection.

Client holds a per-flow routing table:
```
5-tuple (src, sport, dst, dport, proto) → exit_id
```

Outbound path:
1. App opens new TCP → SYN observed from TUN → hash 5-tuple.
2. Pick exit via load balancer (weighted by health/load/capacity).
3. Write mapping into routing table.
4. All subsequent packets of that flow go to the same exit until FIN/RST or idle-expire (5 min).

Inbound path: trivially driven by dst_ip+dst_port — whichever tunnel pool receives the packet from its exit, it writes into TUN, and the kernel routes to the right app socket. No reassembly state needed on inbound.

Per-flow state: ~50 bytes (5-tuple + exit_id + timestamps). 1000 simultaneous flows = 50 KB. Cheap.

Server-side: each exit only sees its own assigned flows. No state sharing between exits — each node's `sessions_by_fp` / `sessions` IP map is independent. Keyring (clients.json) must be synchronized across nodes (rsync cron or shared KV), but traffic state is node-local.

# Why 5 IPs on one VPS doesn't work

**Defeats only the naive "volume per IP" heuristic. Fails at the next aggregation layer.**

What TSPU actually aggregates by (not IP):
- **AS number** (autonomous system) — 5 IPs at vdsina all land in AS49505, per-AS traffic rollup still shows one anomalous target.
- **BGP prefix** (/24 or smaller) — consecutive vdsina IPs sit in one netrange, groups together in NetFlow.
- **rDNS pattern** — `ovc.r133.vdsina.net` / `ovc.r134.vdsina.net` → obvious shared hoster.
- **WHOIS ownership** — one netrange owner, trivially scriptable group.
- **Traceroute path** — all 5 IPs share the last 2-3 hops on the path from the subscriber → identical upstream.
- **Geographic latency** — all 5 IPs in same DC → ±1 ms RTT from subscriber. Real CDN endpoints show 10-50 ms spread across providers.
- **Hoster reputation** — vdsina/hetzner/DO all live on public "cheap VPS AS" blocklists. Having one IP there is a flag, five is just 5× the same flag.
- **Single point of failure** — BGP-level AS block takes down all 5 at once. Real CDN resilience is distributed.

# What real multi-origin needs

Diversify at the **AS level**, not IP level. Minimum viable:

| Exit | AS | Country | Tier |
|---|---|---|---|
| A | vdsina (AS49505) | NL | cheap VPS |
| B | hetzner (AS24940) | DE | mid |
| C | digitalocean (AS14061) | FR | cloud |
| D | aws (AS16509) | IE | hyperscaler |
| E | gcp (AS15169) | BE | hyperscaler |
| F | oracle cloud free (AS31898) | UK | free tier |

Six ASes, six rDNS patterns, six BGP paths. TSPU can't block AWS/GCP prefixes wholesale — too much collateral. Hetzner blocks are point-lookups, not AS-wide. Vdsina is disposable.

## Pragmatic compromise: 2 providers × 2 IPs each

2 ASes, ~$20/month, "poor-man multi-origin". Good enough to get off the AS-rollup flag list.

**Rule:** NEVER rent two IPs in the same AS for sharding purposes. One IP in each of two different hosters > five IPs in one hoster.

## Special case: hyperscaler with multi-region

AWS Frankfurt + AWS Tokyo + AWS Sao Paulo → one AS (AS16509) but three geographic regions, three rDNS patterns (`fra`, `nrt`, `gru`). Single-AS is fine for a hyperscaler because their AS is common infrastructure — can't be blanket-flagged. Cost is the blocker here.

# Why RBT is useless without this

RBT (Rolling Burst Transport) rotates each TLS connection after ~10 KB. At 500 Mbit/s that's ~6250 new TCP connections per second. **All to one IP** = new anomaly replacing the old one. Same problem, different shape.

With multi-origin (8 exits), 6250 conn/sec → ~780 conn/sec per IP. That's within the normal range for a CDN-heavy mobile app (TikTok opens 200-500 conn/sec to Akamai edge routinely). Only then does RBT start paying its maintenance cost.

**How to apply:** when user is ready to move beyond single-exit, start with the 2-provider compromise (vdsina + one other cheap hoster in Germany or France), bring up the routing-table-based shard selector in client code, add a keyring sync mechanism across nodes. DO NOT start with RBT — ship multi-origin first, THEN add RBT on top. Other v0.19 items (in-band auth, utls) are independent and can come in any order.
