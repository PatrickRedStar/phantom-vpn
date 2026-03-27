---
name: DPI evasion and tunneling research (March 2026)
description: Comprehensive analysis of Russian TSPU/DPI capabilities, protocol detection rates, VLESS/Reality internals, performance techniques (splice, io_uring, eBPF), emerging threats (cross-layer RTT fingerprinting), and PhantomVPN architecture comparison
type: reference
---

# DPI Evasion & High-Performance Tunneling Research (March 2026)

## Russian TSPU Capabilities

- Hardware: EcoFilter Balancer (Barefoot Tofino ASICs, 3.2 Tbps), Intel Xeon Gold 6212 filter nodes
- Blocking cycle: 5-15 minutes from detection to enforcement
- 60 billion rubles budget 2025-2027, AI-enhanced blocking planned

### Detection rates (late 2025)
- OpenVPN: 100% (handshake fingerprint)
- WireGuard: 100% (type field 0x01 + timing patterns)
- Shadowsocks: ~95% (encrypted traffic heuristics)
- Trojan: ~90% (active probing)
- VMess: ~80% (packet structure)
- VLESS+Reality: <5% (currently most resistant)

### Detection techniques
1. Protocol fingerprinting (handshake opcodes)
2. Statistical traffic analysis (packet size distributions, timing — ML models 80-95% accuracy)
3. TLS fingerprinting (JA3/JA4 — non-browser fingerprints flagged)
4. Active probing (connecting to suspected servers)
5. Encrypted traffic pattern matching ("client sends 3+ packets of 411+ bytes, server sends more frequently")
6. On-the-fly packet modification (Nov 2025 — flipping bits in ClientHello)
7. Port-priority filtering (port 443 most scrutinized, high ports 80% pass-through)
8. Cross-layer RTT fingerprinting (NDSS 2025 — 95% detection, passive, protocol-agnostic)

## Why VLESS+Reality is fast
- XTLS Vision detects TLS 1.3 in payload → stops double-encrypting
- splice(2) moves data socket→socket in kernel space, bypassing userspace
- uTLS fingerprint = Chrome browser
- REALITY: failed auth → proxy to real website (active probing defense)

## Performance techniques
- **splice(2)**: 30-70% improvement, kernel-space data movement, Go uses automatically with io.Copy between TCPConn
- **SOCKMAP/eBPF**: zero syscalls, zero copies, but stability issues (Cloudflare 2019: "not ready")
- **XDP/AF_XDP**: fastest L3/L4, not for L7 proxy with TLS
- **io_uring zero-copy** (Linux 6.15+): saturated 200Gbps from single core, tokio-uring for Rust
- **tokio-splice2**: async splice for Rust

## PhantomVPN bottleneck analysis
- 3-4 copies per packet in TX path (TUN read → batch → frame alloc → QUIC)
- 64 allocations per RX batch (extract_batch_packets to_vec per packet)
- TCP-in-QUIC congestion interference (fundamental)
- Dead H264Shaper code on server
- Mutex lock per packet for session registration

## Emerging threats
- Cross-layer RTT fingerprinting (NDSS 2025): transport RTT vs application RTT discrepancy reveals proxy
- Encapsulated TLS fingerprinting (USENIX 2024): inner TLS handshake size/timing visible through outer encryption
- Packet modification attacks: DPI flips bits, strict protocols self-destruct

## Key protocols
- MASQUE/RFC 9484: VPN over standard HTTP/3, CDN-compatible
- AmneziaWG 2.0: modified WireGuard with header randomization
- ECH (Encrypted Client Hello): hides SNI, Firefox/Chrome default

## Language comparison (proxy workload)
- Rust: best tail latency, memory efficiency, crypto speed, io_uring/splice integration
- Go: splice automatic for TCP, faster ecosystem iteration for anti-censorship
- Key insight: xray-core fast because of splice, not because of Go
