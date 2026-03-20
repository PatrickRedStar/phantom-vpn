//! Wire format: побайтовая структура пакета на проводе.
//! Имитирует Secure RTP (SRTP) используемый в WebRTC.

use crate::error::PacketError;

// ─── Константы ──────────────────────────────────────────────────────────────
pub const SRTP_HEADER_LEN: usize = 12;
pub const INNER_LEN_FIELD: usize = 2;
pub const AEAD_TAG_LEN: usize = 16;
/// Суммарный overhead = SRTP(12) + InnerLen(2) + IP/UDP outer(28) + AEAD(16)
pub const TUNNEL_OVERHEAD: usize = SRTP_HEADER_LEN + INNER_LEN_FIELD + AEAD_TAG_LEN + 28;
/// MTU для TUN интерфейса (c запасом)
pub const TUNNEL_MTU: usize = 1380;
/// MSS для TCP SYN clamping
pub const TUNNEL_MSS: u16 = 1340;
/// Максимальный plaintext в одном UDP пакете
pub const UDP_PAYLOAD_MAX: usize = TUNNEL_MTU - SRTP_HEADER_LEN - INNER_LEN_FIELD - AEAD_TAG_LEN;

// ─── QUIC mode constants ────────────────────────────────────────────────────
/// Nonce prefix length in QUIC datagrams
pub const NONCE_LEN: usize = 8;
/// TUN MTU for QUIC mode (conservative for QUIC datagram limits)
pub const QUIC_TUNNEL_MTU: usize = 1350;
/// MSS for TCP SYN clamping in QUIC mode
pub const QUIC_TUNNEL_MSS: u16 = 1310;

/// Maximum batch plaintext (H.264 I-frame up to 50 KB + overhead)
pub const BATCH_MAX_PLAINTEXT: usize = 65_536;

/// Number of parallel QUIC data streams per connection.
/// More streams = less head-of-line blocking on packet loss.
pub const N_DATA_STREAMS: usize = 4;

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

/// Version=2, P=0, X=0, CC=0
pub const RTP_VERSION_FLAGS: u8 = 0x80;
/// Marker=0, PayloadType=97 (H.264)
pub const RTP_PT_H264: u8 = 0x61;
/// Marker=1 (конец I-frame burst), PayloadType=97
pub const RTP_PT_H264_MARKER: u8 = 0xE1;

// ─── Заголовок пакета ───────────────────────────────────────────────────────

/// Распарсенный SRTP заголовок (12 байт)
#[derive(Debug, Clone, Copy)]
pub struct SrtpHeader {
    pub seq_num:   u16,
    pub timestamp: u32,
    pub ssrc:      u32,
    pub is_last:   bool, // marker bit
}

impl SrtpHeader {
    /// Парсит первые 12 байт буфера без аллокаций
    pub fn parse(buf: &[u8]) -> Result<Self, PacketError> {
        if buf.len() < SRTP_HEADER_LEN {
            return Err(PacketError::TooShort(buf.len()));
        }
        // [0] = 0x80 (Version 2, no CSRC)
        // [1] = marker bit | payload type
        let is_last = (buf[1] & 0x80) != 0;
        let seq_num   = u16::from_be_bytes([buf[2], buf[3]]);
        let timestamp = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let ssrc      = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]);
        Ok(SrtpHeader { seq_num, timestamp, ssrc, is_last })
    }

    /// Сериализует в буфер (12 байт)
    pub fn write(&self, buf: &mut [u8]) {
        buf[0] = RTP_VERSION_FLAGS;
        buf[1] = if self.is_last { RTP_PT_H264_MARKER } else { RTP_PT_H264 };
        buf[2..4].copy_from_slice(&self.seq_num.to_be_bytes());
        buf[4..8].copy_from_slice(&self.timestamp.to_be_bytes());
        buf[8..12].copy_from_slice(&self.ssrc.to_be_bytes());
    }
}

// ─── Вычисление SSRC ────────────────────────────────────────────────────────

use hmac::{Hmac, Mac};
use sha2::Sha256;

/// Вычисляет Magic Word для SSRC поля.
/// SSRC = HMAC-SHA256(shared_secret, client_pub_key)[0..4]
pub fn compute_ssrc(shared_secret: &[u8; 32], client_public_key: &[u8; 32]) -> u32 {
    let mut mac = Hmac::<Sha256>::new_from_slice(shared_secret)
        .expect("HMAC accepts any key size");
    mac.update(client_public_key);
    let result = mac.finalize().into_bytes();
    u32::from_be_bytes([result[0], result[1], result[2], result[3]])
}

// ─── Сборка пакета ──────────────────────────────────────────────────────────

/// Собирает готовый UDP payload (без шифрования — plaintext для передачи в snow)
///
/// Layout зашифрованного plaintext:
/// [0..2]     = inner_ip_len (u16 BE)
/// [2..2+N]   = ip_packet
/// [2+N..end] = random padding
pub fn build_plaintext(
    ip_packet: &[u8],
    target_size: usize,
    out: &mut [u8],
) -> Result<usize, PacketError> {
    let ip_len = ip_packet.len();
    let total = 2 + ip_len;
    if total > target_size {
        return Ok(total); // без padding если пакет больше цели
    }
    if out.len() < target_size {
        return Err(PacketError::BufferTooSmall);
    }
    // Inner IP length (2 байта, BE)
    out[0..2].copy_from_slice(&(ip_len as u16).to_be_bytes());
    // IP пакет
    out[2..2 + ip_len].copy_from_slice(ip_packet);
    // Random padding
    let pad_start = 2 + ip_len;
    let pad_end = target_size;
    use rand::RngCore;
    rand::thread_rng().fill_bytes(&mut out[pad_start..pad_end]);
    Ok(target_size)
}

/// Извлекает IP пакет из расшифрованного plaintext
pub fn extract_ip_packet(plaintext: &[u8]) -> Result<&[u8], PacketError> {
    if plaintext.len() < 2 {
        return Err(PacketError::TooShort(plaintext.len()));
    }
    let ip_len = u16::from_be_bytes([plaintext[0], plaintext[1]]) as usize;
    if ip_len == 0 || 2 + ip_len > plaintext.len() {
        return Err(PacketError::BadIpLen(ip_len));
    }
    Ok(&plaintext[2..2 + ip_len])
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

// ─── Фрагментация I-frame ───────────────────────────────────────────────────

/// Информация об одном UDP-фрагменте кадра
pub struct FrameFragment {
    pub plaintext_size: usize, // размер plaintext (до шифрования)
    pub is_last:        bool,
}

/// Нарезает целевой размер кадра на фрагменты по UDP_PAYLOAD_MAX
pub fn compute_fragments(target_bytes: usize, ip_pkt_len: usize) -> Vec<FrameFragment> {
    let total_plaintext = std::cmp::max(target_bytes, 2 + ip_pkt_len);
    let mut fragments = Vec::new();
    let mut remaining = total_plaintext;
    while remaining > 0 {
        let chunk = remaining.min(UDP_PAYLOAD_MAX);
        remaining -= chunk;
        fragments.push(FrameFragment {
            plaintext_size: chunk,
            is_last: remaining == 0,
        });
    }
    fragments
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_srtp_header_roundtrip() {
        let hdr = SrtpHeader {
            seq_num: 1234,
            timestamp: 90000,
            ssrc: 0xDEADBEEF,
            is_last: true,
        };
        let mut buf = [0u8; 12];
        hdr.write(&mut buf);
        let parsed = SrtpHeader::parse(&buf).unwrap();
        assert_eq!(parsed.seq_num, 1234);
        assert_eq!(parsed.timestamp, 90000);
        assert_eq!(parsed.ssrc, 0xDEADBEEF);
        assert!(parsed.is_last);
    }

    #[test]
    fn test_compute_ssrc_deterministic() {
        let secret = [1u8; 32];
        let pubkey = [2u8; 32];
        let ssrc1 = compute_ssrc(&secret, &pubkey);
        let ssrc2 = compute_ssrc(&secret, &pubkey);
        assert_eq!(ssrc1, ssrc2);
        // Разные ключи — разный SSRC
        let ssrc3 = compute_ssrc(&[3u8; 32], &pubkey);
        assert_ne!(ssrc1, ssrc3);
    }

    #[test]
    fn test_build_and_extract_plaintext() {
        let ip_pkt = b"fake_ip_packet_data_here_1234567890";
        let target = 512;
        let mut buf = vec![0u8; target];
        let size = build_plaintext(ip_pkt, target, &mut buf).unwrap();
        assert_eq!(size, target);
        let extracted = extract_ip_packet(&buf[..size]).unwrap();
        assert_eq!(extracted, ip_pkt.as_ref());
    }

    #[test]
    fn test_srtp_too_short() {
        let buf = [0u8; 5];
        assert!(SrtpHeader::parse(&buf).is_err());
    }

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
