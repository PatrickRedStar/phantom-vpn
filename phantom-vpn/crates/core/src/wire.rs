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
}
