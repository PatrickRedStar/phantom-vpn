//! Wire format: побайтовая структура пакета на проводе.
//! Формат: [4B frame_len][batch plaintext] внутри TLS stream.

use crate::error::PacketError;

// ─── Константы ──────────────────────────────────────────────────────────────
/// TUN MTU (conservative for TLS stream framing)
pub const QUIC_TUNNEL_MTU: usize = 1350;
/// MSS for TCP SYN clamping
pub const QUIC_TUNNEL_MSS: u16 = 1310;

/// Maximum batch plaintext (H.264 I-frame up to 50 KB + overhead)
pub const BATCH_MAX_PLAINTEXT: usize = 65_536;

/// Number of parallel TLS-over-TCP streams per VPN session (h2_server path).
/// Each stream is a separate TCP connection aggregated via SessionCoordinator,
/// selected by the client with a single `stream_idx` byte after TLS handshake.
/// 4 parallel TCP connections → каждая получает свой CPU core для rustls.
/// Client и server должны использовать одну и ту же константу, иначе сервер
/// отвергает stream_idx >= N_DATA_STREAMS.
pub const N_DATA_STREAMS: usize = 4;

/// Alias used by server-side code paths (h2_server, vpn_session, quic_server).
/// Same value as N_DATA_STREAMS — держим два имени только из-за наследованных
/// use-импортов, это единая контрольная точка.
pub const N_STREAMS: usize = N_DATA_STREAMS;

/// Map an IPv4 packet to a stream index in [0, n) using 5-tuple hash.
/// Symmetric: A→B hashes to the same index as B→A (XOR/addition are commutative).
/// Ensures packets from the same TCP flow always use the same stream.
pub fn flow_stream_idx(pkt: &[u8], n: usize) -> usize {
    if n <= 1 || pkt.len() < 20 || (pkt[0] >> 4) != 4 {
        return 0;
    }
    let src = u32::from_be_bytes([pkt[12], pkt[13], pkt[14], pkt[15]]);
    let dst = u32::from_be_bytes([pkt[16], pkt[17], pkt[18], pkt[19]]);
    let proto = pkt[9] as u32;
    let mut h = src.wrapping_add(dst).wrapping_add(proto);
    if pkt.len() >= 24 && (proto == 6 || proto == 17) {
        let sp = u16::from_be_bytes([pkt[20], pkt[21]]) as u32;
        let dp = u16::from_be_bytes([pkt[22], pkt[23]]) as u32;
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
}
