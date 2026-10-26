//! Wire format: побайтовая структура одного стрима (TLS-соединения).
//!
//! 1. Клиент сразу после TLS-рукопожатия шлёт 2 байта `[stream_idx, n_streams]`
//!    (`n_streams` — всегда полное N клиента, не число живых стримов). В той же
//!    TLS-записи за ними идёт обычный heartbeat-кадр — сервер читает ровно
//!    2 байта и дальше разбирает кадры как обычно.
//! 2. Дальше в обе стороны — кадры `[4B frame_len BE][batch plaintext]`,
//!    `frame_len ≤ BATCH_MAX_PLAINTEXT` (больший кадр приёмник считает ошибкой,
//!    `0` — пустой кадр).
//! 3. Batch: `[2B len][IP-пакет]...[2B 0x0000][паддинг нулями]`. Всё после
//!    терминатора игнорируется; пакеты не-IPv4 (heartbeat-заглушки с первым
//!    байтом 0x00) приёмник молча выбрасывает.

use crate::error::PacketError;
use bytes::{BufMut, Bytes, BytesMut};
use rand::Rng;
use std::time::Duration;

// ─── Константы ──────────────────────────────────────────────────────────────
/// TUN MTU (conservative for TLS stream framing).
///
/// v0.25.0: lowered 1350→1300 — на 5G NSA / некоторых mobile carriers underlying
/// link MTU = 1280, и наш 1350 приводил к фрагментации/drop. 1300 даёт запас
/// под TLS+TCP+IP headers и стабильно проходит. Потеря throughput ~5% на
/// 1500-MTU сетях, выигрыш — устойчивость на узких каналах. Bug #P1-7.
pub const QUIC_TUNNEL_MTU: usize = 1300;
/// MSS for TCP SYN clamping.
///
/// v0.25.0: lowered 1310→1240 в паре с MTU. Bug #P1-7.
pub const QUIC_TUNNEL_MSS: u16 = 1240;

/// Maximum batch plaintext in one frame; receivers reject a larger `frame_len`.
pub const BATCH_MAX_PLAINTEXT: usize = 65_536;

/// Hard cap on parallel TLS streams per VPN session, regardless of host core count.
/// Keeps wire-format stream_idx and `data_sends` vectors bounded.
pub const MAX_N_STREAMS: usize = 16;

/// Minimum parallel streams. On 1-core hosts we still want at least 2 to keep
/// TLS handshake and data write loops concurrent.
pub const MIN_N_STREAMS: usize = 2;

/// Runtime-cached number of parallel TLS-over-TCP streams per VPN session.
/// Derived from `std::thread::available_parallelism()`, clamped to
/// `[MIN_N_STREAMS, MAX_N_STREAMS]`. Computed once on first call, then cached.
///
/// Both client and server call this independently. During handshake the client
/// sends its own value as `max_streams` byte, server reads its own, and both
/// sides agree on `effective = min(client_n, server_n)`. This lets a 2-core
/// server talk to an 8-core client without either wasting slots or rejecting
/// out-of-range stream_idx.
pub fn n_data_streams() -> usize {
    use std::sync::OnceLock;
    static CACHED: OnceLock<usize> = OnceLock::new();
    *CACHED.get_or_init(|| {
        std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(MIN_N_STREAMS)
            .clamp(MIN_N_STREAMS, MAX_N_STREAMS)
    })
}

/// Resolve stream count with an optional user override. `None` preserves the
/// historical automatic CPU-derived behavior.
pub fn n_data_streams_with_override(streams: Option<usize>) -> usize {
    streams
        .map(|value| value.clamp(MIN_N_STREAMS, MAX_N_STREAMS))
        .unwrap_or_else(n_data_streams)
}

/// Server-side alias retained for call-site ergonomics.
#[inline]
pub fn n_streams() -> usize {
    n_data_streams()
}

/// Map an IPv4 packet to a stream index in [0, n) using 5-tuple hash.
/// Symmetric: A→B hashes to the same index as B→A (XOR/addition are commutative).
/// Ensures packets from the same TCP flow always use the same stream.
///
/// The two ends never have to agree on the index — each side only picks the
/// stream for its own direction — so changing the mix stays compatible with
/// peers running an older hash.
pub fn flow_stream_idx(pkt: &[u8], n: usize) -> usize {
    if n <= 1 || pkt.len() < 20 || (pkt[0] >> 4) != 4 {
        return 0;
    }
    let ihl = ((pkt[0] & 0x0F) as usize) * 4; // IHL field: 5-15 → 20-60 bytes
    let src = u32::from_be_bytes([pkt[12], pkt[13], pkt[14], pkt[15]]);
    let dst = u32::from_be_bytes([pkt[16], pkt[17], pkt[18], pkt[19]]);
    let proto = pkt[9] as u32;
    let mut h = src.wrapping_add(dst).wrapping_add(proto);
    // Only an unfragmented packet carries the L4 header at `ihl`; in a fragment
    // those bytes are payload (or absent), so all fragments of a datagram are
    // hashed by addresses + protocol and stay on one stream.
    let fragmented = u16::from_be_bytes([pkt[6], pkt[7]]) & 0x3FFF != 0; // MF | offset
    if !fragmented && pkt.len() >= ihl + 4 && (proto == 6 || proto == 17) {
        let sp = u16::from_be_bytes([pkt[ihl], pkt[ihl + 1]]) as u32;
        let dp = u16::from_be_bytes([pkt[ihl + 2], pkt[ihl + 3]]) as u32;
        h = h.wrapping_add(sp ^ dp);
    }
    // Fibonacci mix + high bits: Linux/Android pick ephemeral ports of one
    // parity, which pinned the low bit of `h` and made a plain `h % n` reach
    // only half of the streams for even `n`.
    ((h.wrapping_mul(0x9E37_79B1) as u64 * n as u64) >> 32) as usize
}


// ─── Batch format ───────────────────────────────────────────────────────────

/// Собирает batch plaintext из нескольких IP-пакетов.
///
/// Формат: [2B len1][pkt1][2B len2][pkt2]...[2B 0x0000][padding до target_size]
///
/// `target_size` — минимальный размер кадра: если данных меньше, хвост после
/// терминатора добивается нулями (внутри AEAD — наблюдателю не виден).
/// `target_size=0` — без паддинга. Приёмники всех версий читают до терминатора
/// и паддинг игнорируют, так что включать его можно на любой стороне независимо.
///
/// Данные больше `BATCH_MAX_PLAINTEXT` — ошибка (приёмник такой кадр отвергнет);
/// вызывающий обязан делить пакеты по батчам сам.
pub fn build_batch_plaintext(
    packets: &[&[u8]],
    target_size: usize,
    out: &mut [u8],
) -> Result<usize, PacketError> {
    if packets.is_empty() {
        return Err(PacketError::TooShort(0));
    }
    // data_size = sum(2 + pkt.len()) + 2 (terminator)
    let data_size: usize = packets.iter().map(|p| 2 + p.len()).sum::<usize>() + 2;
    if data_size > BATCH_MAX_PLAINTEXT {
        return Err(PacketError::BadIpLen(data_size));
    }
    let total = data_size.max(target_size.min(BATCH_MAX_PLAINTEXT));
    if out.len() < total {
        return Err(PacketError::BufferTooSmall);
    }
    let mut offset = 0;
    for pkt in packets {
        let pkt_len = pkt.len();
        if pkt_len > u16::MAX as usize {
            return Err(PacketError::BadIpLen(pkt_len));
        }
        if offset + 2 + pkt_len + 2 > out.len() {
            return Err(PacketError::BufferTooSmall);
        }
        out[offset..offset + 2].copy_from_slice(&(pkt_len as u16).to_be_bytes());
        out[offset + 2..offset + 2 + pkt_len].copy_from_slice(pkt);
        offset += 2 + pkt_len;
    }
    // End-of-batch marker
    out[offset..offset + 2].copy_from_slice(&0u16.to_be_bytes());
    offset += 2;
    // Zero padding (inside AEAD — content irrelevant to observer)
    if offset < total {
        out[offset..total].fill(0);
    }
    Ok(total)
}

/// Итератор по пакетам batch plaintext — единый парсер для RX-циклов.
/// Останавливается на терминаторе 0x0000, на обрезанном пакете или в конце
/// буфера; всё после терминатора (паддинг) игнорируется. Пакеты не фильтрует:
/// heartbeat-заглушки отсеивает вызывающий (`is_heartbeat_packet`).
pub fn batch_packets(mut buf: &[u8]) -> impl Iterator<Item = &[u8]> {
    std::iter::from_fn(move || {
        if buf.len() < 2 {
            return None;
        }
        let len = u16::from_be_bytes([buf[0], buf[1]]) as usize;
        let rest = &buf[2..];
        if len == 0 || len > rest.len() {
            buf = &[];
            return None;
        }
        let (pkt, tail) = rest.split_at(len);
        buf = tail;
        Some(pkt)
    })
}

// ─── Heartbeat / dummy frames (detection vector 12) ────────────────────────
//
// An idle stream sends a dummy "heartbeat" batch after a random 30–60 s of
// silence, independently per stream and per direction (client and server both
// use these functions). It keeps mobile NAT entries alive and feeds the
// receivers' liveness timers: client Stale at 75 s since the last frame, dead
// stream at 90 s (`RX_IDLE_TIMEOUT_SECS`), server read idle at 150 s. The
// interval is deliberately not synchronised across streams — lock-step timers
// are a DPI tell — and kept ≥ 30 s so 8–16 streams do not keep the phone's
// radio awake.
//
// Dummy packets carry random bytes with `buf[0] = 0x00`, so version nibble != 4
// — all receivers' existing IPv4 filters silently drop them before tun_tx.

/// Minimum interval between consecutive heartbeats on an idle stream.
pub const HEARTBEAT_INTERVAL_MIN_SECS: u64 = 30;
/// Maximum interval between consecutive heartbeats on an idle stream.
/// Must stay well below the 90 s dead-stream timeout on the client.
pub const HEARTBEAT_INTERVAL_MAX_SECS: u64 = 60;
/// Min start jitter for first heartbeat after stream creation (desync streams).
pub const HEARTBEAT_START_JITTER_MIN_SECS: u64 = 5;
/// Max start jitter for first heartbeat after stream creation.
pub const HEARTBEAT_START_JITTER_MAX_SECS: u64 = 30;
/// Minimum random heartbeat packet size in bytes.
pub const HEARTBEAT_PKT_MIN: usize = 40;
/// Maximum random heartbeat packet size in bytes.
pub const HEARTBEAT_PKT_MAX: usize = 200;
/// Sentinel version nibble for dummy heartbeat packets (fails IPv4 parse on all receivers).
pub const HEARTBEAT_SENTINEL_VERSION: u8 = 0x00;

/// Builds a fully-framed dummy heartbeat ready to `write_all` into a TLS stream.
///
/// Layout: `[4B frame_len BE][2B pkt_len BE][pkt_bytes][2B 0x0000]`
///
/// The inner packet is `uniform(HEARTBEAT_PKT_MIN, HEARTBEAT_PKT_MAX)` random bytes
/// with `buf[0] = HEARTBEAT_SENTINEL_VERSION` so receivers' IPv4 filters drop it.
pub fn build_heartbeat_frame() -> Bytes {
    let hb = crate::policy::current().heartbeat.clone();
    let mut rng = rand::thread_rng();
    let pkt_len: usize = rng.gen_range(hb.pkt_min..=hb.pkt_max);

    // frame body = [2B pkt_len][pkt_bytes][2B 0x0000]
    let body_len = 2 + pkt_len + 2;
    let mut buf = BytesMut::with_capacity(4 + body_len);

    // 4B frame_len (big-endian, body length only — excludes the 4B prefix itself)
    buf.put_u32(body_len as u32);

    // 2B pkt_len
    buf.put_u16(pkt_len as u16);

    // pkt_len random bytes, first byte forced to sentinel
    let start = buf.len();
    buf.resize(start + pkt_len, 0);
    rng.fill(&mut buf[start..start + pkt_len]);
    buf[start] = HEARTBEAT_SENTINEL_VERSION;

    // 2B end-of-batch marker
    buf.put_u16(0x0000);

    buf.freeze()
}

/// Returns true if `pkt` should be dropped as a dummy/heartbeat (or otherwise
/// non-IPv4) packet.
#[inline]
pub fn is_heartbeat_packet(pkt: &[u8]) -> bool {
    pkt.is_empty() || (pkt[0] >> 4) != 4
}

/// Uniform `[interval_min_secs, interval_max_secs]` of the active policy
/// (default `[HEARTBEAT_INTERVAL_MIN_SECS, HEARTBEAT_INTERVAL_MAX_SECS]`).
/// Used for scheduling the next heartbeat after the first one fires or after
/// real traffic suppressed a scheduled heartbeat.
pub fn next_heartbeat_delay() -> Duration {
    let hb = crate::policy::current().heartbeat.clone();
    let secs = rand::thread_rng().gen_range(hb.interval_min_secs..=hb.interval_max_secs);
    Duration::from_secs(secs)
}

/// Uniform `[HEARTBEAT_START_JITTER_MIN_SECS, HEARTBEAT_START_JITTER_MAX_SECS]`
/// seconds. Used once per stream at creation time so streams desynchronize
/// instead of all firing their first heartbeat at t=20s.
pub fn first_heartbeat_delay() -> Duration {
    let hb = crate::policy::current().heartbeat.clone();
    let secs = rand::thread_rng().gen_range(hb.start_jitter_min_secs..=hb.start_jitter_max_secs);
    Duration::from_secs(secs)
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stream_override_preserves_automatic_default_when_absent() {
        assert_eq!(n_data_streams_with_override(None), n_data_streams());
    }

    #[test]
    fn stream_override_is_clamped_to_supported_range() {
        assert_eq!(n_data_streams_with_override(Some(1)), MIN_N_STREAMS);
        assert_eq!(n_data_streams_with_override(Some(12)), 12);
        assert_eq!(n_data_streams_with_override(Some(99)), MAX_N_STREAMS);
    }

    fn parse(buf: &[u8]) -> Vec<Vec<u8>> {
        batch_packets(buf).map(|p| p.to_vec()).collect()
    }

    #[test]
    fn test_batch_roundtrip_single() {
        let pkt = b"hello_ip_packet_data";
        let mut buf = vec![0u8; 1024];
        let n = build_batch_plaintext(&[pkt.as_ref()], 512, &mut buf).unwrap();
        assert_eq!(n, 512);
        let packets = parse(&buf[..n]);
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0], pkt);
    }

    #[test]
    fn test_batch_roundtrip_multi() {
        let pkts: Vec<Vec<u8>> = vec![
            b"packet_one".to_vec(),
            b"packet_two_longer".to_vec(),
            b"pkt3".to_vec(),
        ];
        let refs: Vec<&[u8]> = pkts.iter().map(|p| p.as_slice()).collect();
        let mut buf = vec![0u8; 8192];
        let n = build_batch_plaintext(&refs, 4096, &mut buf).unwrap();
        assert_eq!(n, 4096);
        let out = parse(&buf[..n]);
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], b"packet_one");
        assert_eq!(out[1], b"packet_two_longer");
        assert_eq!(out[2], b"pkt3");
    }

    /// Data that cannot fit one frame is an error, never a silently truncated
    /// frame; an oversized padding target is capped instead.
    #[test]
    fn test_batch_oversized_is_error_and_target_is_capped() {
        let big = vec![0x45u8; 40_000];
        let mut buf = vec![0u8; BATCH_MAX_PLAINTEXT + 16];
        assert!(build_batch_plaintext(&[&big, &big], 0, &mut buf).is_err());
        let n = build_batch_plaintext(&[b"x".as_ref()], 1_000_000, &mut buf).unwrap();
        assert_eq!(n, BATCH_MAX_PLAINTEXT);
    }

    // ─── Heartbeat tests (detection vector 12) ─────────────────────────────

    #[test]
    fn test_build_heartbeat_frame_parseable() {
        // Build a heartbeat, strip the 4B frame_len prefix, feed the body to
        // batch_packets. Expect exactly one packet in [40, 200] bytes
        // with first byte == HEARTBEAT_SENTINEL_VERSION (0x00).
        for _ in 0..100 {
            let frame = build_heartbeat_frame();
            assert!(frame.len() >= 4 + 2 + HEARTBEAT_PKT_MIN + 2);
            assert!(frame.len() <= 4 + 2 + HEARTBEAT_PKT_MAX + 2);

            let body_len =
                u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
            assert_eq!(body_len, frame.len() - 4);

            let packets = parse(&frame[4..]);
            assert_eq!(packets.len(), 1, "heartbeat must contain exactly one pkt");

            let pkt = &packets[0];
            assert!(
                pkt.len() >= HEARTBEAT_PKT_MIN && pkt.len() <= HEARTBEAT_PKT_MAX,
                "pkt.len()={} out of range",
                pkt.len()
            );
            assert_eq!(
                pkt[0], HEARTBEAT_SENTINEL_VERSION,
                "first byte must be sentinel 0x00"
            );
            assert!(is_heartbeat_packet(pkt));
        }
    }

    #[test]
    fn test_is_heartbeat_packet_rejects_real_ipv4() {
        // Minimal IPv4 header: version=4, IHL=5 → first byte 0x45.
        let mut ipv4 = vec![0u8; 20];
        ipv4[0] = 0x45;
        assert!(!is_heartbeat_packet(&ipv4));

        // Any 0x4X first byte counts as IPv4 for our filter.
        ipv4[0] = 0x4F;
        assert!(!is_heartbeat_packet(&ipv4));
    }

    #[test]
    fn test_is_heartbeat_packet_rejects_empty() {
        assert!(is_heartbeat_packet(&[]));
    }

    #[test]
    fn test_next_heartbeat_delay_within_bounds() {
        let lo = Duration::from_secs(HEARTBEAT_INTERVAL_MIN_SECS);
        let hi = Duration::from_secs(HEARTBEAT_INTERVAL_MAX_SECS);
        for _ in 0..100 {
            let d = next_heartbeat_delay();
            assert!(d >= lo && d <= hi, "next_heartbeat_delay out of bounds: {d:?}");
        }
    }

    // ─── Edge cases for batch_packets ──────────────────────────────────────

    #[test]
    fn test_batch_only_terminator_yields_nothing() {
        assert!(parse(&[0u8, 0]).is_empty());
    }

    #[test]
    fn test_batch_truncated_packet_stops_parsing() {
        // pkt_len says 100 bytes but buffer only has 4 bytes after the length field
        let mut buf = Vec::new();
        buf.extend_from_slice(&3u16.to_be_bytes());
        buf.extend_from_slice(b"abc");
        buf.extend_from_slice(&100u16.to_be_bytes());
        buf.extend_from_slice(&[0xAA; 4]);
        assert_eq!(parse(&buf), vec![b"abc".to_vec()]);
    }

    #[test]
    fn test_batch_without_terminator_yields_complete_packets() {
        let payload = b"full_buffer_packet";
        let mut buf = Vec::new();
        buf.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        buf.extend_from_slice(payload);
        assert_eq!(parse(&buf), vec![payload.to_vec()]);
    }

    #[test]
    fn test_batch_max_size_packet() {
        let pkt_len: usize = u16::MAX as usize;
        let mut buf = Vec::with_capacity(2 + pkt_len + 2);
        buf.extend_from_slice(&(pkt_len as u16).to_be_bytes());
        buf.resize(2 + pkt_len, 0xBB);
        buf.extend_from_slice(&0u16.to_be_bytes()); // terminator
        let packets = parse(&buf);
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0].len(), pkt_len);
    }

    #[test]
    fn test_batch_padding_after_terminator_is_ignored() {
        // pkt_len==0 at any position means end-of-batch; the rest is padding.
        let buf = [0u8, 1, 0x45, 0, 0, 0xAA, 0xBB, 0, 1, 0x45];
        assert_eq!(parse(&buf), vec![vec![0x45u8]]);
    }

    // ─── Flow hash ─────────────────────────────────────────────────────────

    fn tcp_pkt(src: [u8; 4], dst: [u8; 4], sp: u16, dp: u16) -> Vec<u8> {
        let mut p = vec![0u8; 40];
        p[0] = 0x45;
        p[9] = 6;
        p[12..16].copy_from_slice(&src);
        p[16..20].copy_from_slice(&dst);
        p[20..22].copy_from_slice(&sp.to_be_bytes());
        p[22..24].copy_from_slice(&dp.to_be_bytes());
        p
    }

    #[test]
    fn test_flow_hash_is_symmetric() {
        for sp in 40_000..40_200u16 {
            let a = tcp_pkt([10, 7, 0, 2], [1, 2, 3, 4], sp, 443);
            let b = tcp_pkt([1, 2, 3, 4], [10, 7, 0, 2], 443, sp);
            for n in 2..=MAX_N_STREAMS {
                assert_eq!(flow_stream_idx(&a, n), flow_stream_idx(&b, n));
            }
        }
    }

    /// Same-parity source ports (what Linux/Android hand out) must still reach
    /// every stream, not just half of them.
    #[test]
    fn test_flow_hash_spreads_same_parity_ports() {
        for n in [2usize, 4, 8, 16] {
            let mut seen = vec![false; n];
            for sp in (40_000..42_000u16).step_by(2) {
                let idx = flow_stream_idx(&tcp_pkt([10, 7, 0, 2], [1, 2, 3, 4], sp, 443), n);
                assert!(idx < n);
                seen[idx] = true;
            }
            assert!(seen.iter().all(|s| *s), "n={n}: not every stream used");
        }
    }

    #[test]
    fn test_flow_hash_fragments_ignore_ports() {
        let mut first = tcp_pkt([10, 7, 0, 2], [1, 2, 3, 4], 40_000, 443);
        first[6] = 0x20; // MF, offset 0
        let mut later = tcp_pkt([10, 7, 0, 2], [1, 2, 3, 4], 0xDEAD, 0xBEEF); // payload bytes
        later[7] = 0xB9; // offset != 0
        for n in 2..=MAX_N_STREAMS {
            assert_eq!(flow_stream_idx(&first, n), flow_stream_idx(&later, n));
        }
    }

    #[test]
    fn test_first_heartbeat_delay_within_bounds() {
        let lo = Duration::from_secs(HEARTBEAT_START_JITTER_MIN_SECS);
        let hi = Duration::from_secs(HEARTBEAT_START_JITTER_MAX_SECS);
        for _ in 0..100 {
            let d = first_heartbeat_delay();
            assert!(d >= lo && d <= hi, "first_heartbeat_delay out of bounds: {d:?}");
        }
    }
}
