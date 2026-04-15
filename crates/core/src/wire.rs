//! Wire format: побайтовая структура пакета на проводе.
//! Формат: [4B frame_len][batch plaintext] внутри TLS stream.

use crate::error::PacketError;
use bytes::{BufMut, Bytes, BytesMut};
use rand::Rng;
use std::time::Duration;

// ─── Константы ──────────────────────────────────────────────────────────────
/// TUN MTU (conservative for TLS stream framing)
pub const QUIC_TUNNEL_MTU: usize = 1350;
/// MSS for TCP SYN clamping
pub const QUIC_TUNNEL_MSS: u16 = 1310;

/// Maximum batch plaintext (H.264 I-frame up to 50 KB + overhead)
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

/// Server-side alias retained for call-site ergonomics.
#[inline]
pub fn n_streams() -> usize {
    n_data_streams()
}

/// Map an IPv4 packet to a stream index in [0, n) using 5-tuple hash.
/// Symmetric: A→B hashes to the same index as B→A (XOR/addition are commutative).
/// Ensures packets from the same TCP flow always use the same stream.
pub fn flow_stream_idx(pkt: &[u8], n: usize) -> usize {
    if n <= 1 || pkt.len() < 20 || (pkt[0] >> 4) != 4 {
        return 0;
    }
    let ihl = ((pkt[0] & 0x0F) as usize) * 4; // IHL field: 5-15 → 20-60 bytes
    let src = u32::from_be_bytes([pkt[12], pkt[13], pkt[14], pkt[15]]);
    let dst = u32::from_be_bytes([pkt[16], pkt[17], pkt[18], pkt[19]]);
    let proto = pkt[9] as u32;
    let mut h = src.wrapping_add(dst).wrapping_add(proto);
    if pkt.len() >= ihl + 4 && (proto == 6 || proto == 17) {
        let sp = u16::from_be_bytes([pkt[ihl], pkt[ihl + 1]]) as u32;
        let dp = u16::from_be_bytes([pkt[ihl + 2], pkt[ihl + 3]]) as u32;
        h = h.wrapping_add(sp ^ dp);
    }
    h as usize % n
}


// ─── Batch format ───────────────────────────────────────────────────────────

/// Собирает batch plaintext из нескольких IP-пакетов.
///
/// Формат: [2B len1][pkt1][2B len2][pkt2]...[2B 0x0000][padding до target_size]
///
/// `target_size` — целевой размер кадра из H264Shaper для имитации H.264 паттерна.
/// Если реальные данные больше target_size — padding не добавляется.
///
/// `target_size=0` отключает padding (shaper удалён в v0.17+).
/// Параметр зарезервирован под будущую re-integration shaper-а.
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
    let total = data_size.max(target_size).min(BATCH_MAX_PLAINTEXT);
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

/// Извлекает все IP-пакеты из batch plaintext.
/// Останавливается на терминаторе 0x0000. Padding после терминатора игнорируется.
pub fn extract_batch_packets(plaintext: &[u8]) -> Result<Vec<Vec<u8>>, PacketError> {
    let mut packets = Vec::new();
    let mut offset = 0;
    loop {
        if offset + 2 > plaintext.len() {
            return Err(PacketError::TooShort(plaintext.len()));
        }
        let pkt_len = u16::from_be_bytes([plaintext[offset], plaintext[offset + 1]]) as usize;
        offset += 2;
        if pkt_len == 0 {
            break; // end-of-batch marker
        }
        if offset + pkt_len > plaintext.len() {
            return Err(PacketError::BadIpLen(pkt_len));
        }
        packets.push(plaintext[offset..offset + pkt_len].to_vec());
        offset += pkt_len;
    }
    Ok(packets)
}

// ─── Heartbeat / dummy frames (detection vector 12) ────────────────────────
//
// Idle TLS streams that go silent for 30+ seconds are a DPI tell: real mobile
// apps emit keepalive records every few seconds. Both client and server send
// dummy "heartbeat" batches at randomized intervals when a stream is idle.
//
// Dummy packets carry random bytes with `buf[0] = 0x00`, so version nibble != 4
// — all receivers' existing IPv4 filters silently drop them before tun_tx.

/// Minimum interval between consecutive heartbeats on an idle stream.
pub const HEARTBEAT_INTERVAL_MIN_SECS: u64 = 15;
/// Maximum interval between consecutive heartbeats on an idle stream.
pub const HEARTBEAT_INTERVAL_MAX_SECS: u64 = 45;
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
    let mut rng = rand::thread_rng();
    let pkt_len: usize = rng.gen_range(HEARTBEAT_PKT_MIN..=HEARTBEAT_PKT_MAX);

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

/// Single-source-of-truth filter: returns true if `pkt` should be dropped as
/// a dummy/heartbeat (or otherwise malformed non-IPv4) packet.
///
/// Both client rx (`tls_rx_loop`) and server rx (`h2_server`) call this
/// before forwarding to tun_tx.
#[inline]
pub fn is_heartbeat_packet(pkt: &[u8]) -> bool {
    pkt.is_empty() || (pkt[0] >> 4) != 4
}

/// Uniform `[HEARTBEAT_INTERVAL_MIN_SECS, HEARTBEAT_INTERVAL_MAX_SECS]` seconds.
/// Used for scheduling the next heartbeat after the first one fires or after
/// real traffic suppressed a scheduled heartbeat.
pub fn next_heartbeat_delay() -> Duration {
    let secs = rand::thread_rng()
        .gen_range(HEARTBEAT_INTERVAL_MIN_SECS..=HEARTBEAT_INTERVAL_MAX_SECS);
    Duration::from_secs(secs)
}

/// Uniform `[HEARTBEAT_START_JITTER_MIN_SECS, HEARTBEAT_START_JITTER_MAX_SECS]`
/// seconds. Used once per stream at creation time so streams desynchronize
/// instead of all firing their first heartbeat at t=20s.
pub fn first_heartbeat_delay() -> Duration {
    let secs = rand::thread_rng()
        .gen_range(HEARTBEAT_START_JITTER_MIN_SECS..=HEARTBEAT_START_JITTER_MAX_SECS);
    Duration::from_secs(secs)
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_batch_roundtrip_single() {
        let pkt = b"hello_ip_packet_data";
        let mut buf = vec![0u8; 1024];
        let n = build_batch_plaintext(&[pkt.as_ref()], 512, &mut buf).unwrap();
        assert_eq!(n, 512);
        let packets = extract_batch_packets(&buf[..n]).unwrap();
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
        let out = extract_batch_packets(&buf[..n]).unwrap();
        assert_eq!(out.len(), 3);
        assert_eq!(out[0], b"packet_one");
        assert_eq!(out[1], b"packet_two_longer");
        assert_eq!(out[2], b"pkt3");
    }

    // ─── Heartbeat tests (detection vector 12) ─────────────────────────────

    #[test]
    fn test_build_heartbeat_frame_parseable() {
        // Build a heartbeat, strip the 4B frame_len prefix, feed the body to
        // extract_batch_packets. Expect exactly one packet in [40, 200] bytes
        // with first byte == HEARTBEAT_SENTINEL_VERSION (0x00).
        for _ in 0..100 {
            let frame = build_heartbeat_frame();
            assert!(frame.len() >= 4 + 2 + HEARTBEAT_PKT_MIN + 2);
            assert!(frame.len() <= 4 + 2 + HEARTBEAT_PKT_MAX + 2);

            let body_len =
                u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
            assert_eq!(body_len, frame.len() - 4);

            let body = &frame[4..];
            let packets = extract_batch_packets(body).expect("parseable heartbeat body");
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
            assert_eq!(pkt[0] >> 4, 0, "version nibble must not be 4");
        }
    }

    #[test]
    fn test_is_heartbeat_packet_matches_built_heartbeat() {
        for _ in 0..100 {
            let frame = build_heartbeat_frame();
            let body = &frame[4..];
            let packets = extract_batch_packets(body).unwrap();
            assert!(is_heartbeat_packet(&packets[0]));
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

    // ─── Edge-case tests for extract_batch_packets (L4) ────────────────────

    #[test]
    fn test_extract_batch_empty_batch_only_terminator() {
        // Only the 0x0000 terminator — should return zero packets
        let buf = [0u8, 0];
        let packets = extract_batch_packets(&buf).unwrap();
        assert!(packets.is_empty());
    }

    #[test]
    fn test_extract_batch_truncated_pkt_len_past_buffer() {
        // pkt_len says 100 bytes but buffer only has 4 bytes after the length field
        let mut buf = Vec::new();
        buf.extend_from_slice(&100u16.to_be_bytes()); // pkt_len = 100
        buf.extend_from_slice(&[0xAA; 4]); // only 4 bytes of payload
        let err = extract_batch_packets(&buf).unwrap_err();
        match err {
            PacketError::BadIpLen(100) => {} // expected
            other => panic!("expected BadIpLen(100), got {other:?}"),
        }
    }

    #[test]
    fn test_extract_batch_no_terminator() {
        // One valid packet that consumes the entire buffer — no terminator follows.
        // After reading the packet, offset+2 > len → TooShort error.
        let payload = b"full_buffer_packet";
        let mut buf = Vec::new();
        buf.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        buf.extend_from_slice(payload);
        // No terminator appended
        let err = extract_batch_packets(&buf).unwrap_err();
        match err {
            PacketError::TooShort(_) => {} // expected
            other => panic!("expected TooShort, got {other:?}"),
        }
    }

    #[test]
    fn test_extract_batch_max_size_packet() {
        // Single packet of u16::MAX bytes
        let pkt_len: usize = u16::MAX as usize;
        let mut buf = Vec::with_capacity(2 + pkt_len + 2);
        buf.extend_from_slice(&(pkt_len as u16).to_be_bytes());
        buf.resize(2 + pkt_len, 0xBB);
        buf.extend_from_slice(&0u16.to_be_bytes()); // terminator
        let packets = extract_batch_packets(&buf).unwrap();
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0].len(), pkt_len);
    }

    #[test]
    fn test_extract_batch_first_pkt_len_zero() {
        // First length field is 0x0000 — same as terminator, so zero packets.
        // This is by design: pkt_len==0 at any position means end-of-batch.
        let buf = [0u8, 0, 0xAA, 0xBB]; // terminator + trailing garbage
        let packets = extract_batch_packets(&buf).unwrap();
        assert!(packets.is_empty());
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
