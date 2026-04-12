//! MTU management, TCP MSS clamping, IP header parsing.

use crate::error::MtuError;

pub const IP_PROTO_TCP: u8 = 6;
pub const IP_PROTO_UDP: u8 = 17;

// ─── IPv4 MSS Clamping ───────────────────────────────────────────────────────

/// Находит TCP SYN пакеты в IPv4 и переписывает MSS опцию.
/// ОБЯЗАТЕЛЬНО для корректной работы HTTPS через туннель.
pub fn clamp_tcp_mss(packet: &mut [u8], max_mss: u16) -> Result<bool, MtuError> {
    if packet.len() < 20 {
        return Err(MtuError::TooShort);
    }
    let version = packet[0] >> 4;
    match version {
        4 => clamp_mss_v4(packet, max_mss),
        6 => clamp_mss_v6(packet, max_mss),
        v => Err(MtuError::UnsupportedVersion(v)),
    }
}

fn clamp_mss_v4(packet: &mut [u8], max_mss: u16) -> Result<bool, MtuError> {
    if packet.len() < 20 {
        return Err(MtuError::TooShort);
    }
    // Длина IPv4 заголовка в байтах
    let ihl = ((packet[0] & 0x0F) as usize) * 4;
    if ihl < 20 || packet.len() < ihl + 20 {
        return Ok(false);
    }
    // Протокол = TCP?
    if packet[9] != IP_PROTO_TCP {
        return Ok(false);
    }
    let tcp = &mut packet[ihl..];
    clamp_tcp_options(tcp, max_mss)
}

fn clamp_mss_v6(packet: &mut [u8], max_mss: u16) -> Result<bool, MtuError> {
    if packet.len() < 40 {
        return Ok(false);
    }
    // Walk IPv6 extension headers to find TCP
    let mut next_header = packet[6];
    let mut offset = 40usize; // IPv6 base header length
    // Skip known extension headers: Hop-by-Hop(0), Routing(43), Fragment(44), Destination(60)
    while matches!(next_header, 0 | 43 | 44 | 60) {
        if offset + 2 > packet.len() {
            return Ok(false);
        }
        let ext_len = if next_header == 44 {
            8 // Fragment header is always 8 bytes
        } else {
            (packet[offset + 1] as usize + 1) * 8
        };
        next_header = packet[offset];
        offset += ext_len;
    }
    if next_header != IP_PROTO_TCP {
        return Ok(false);
    }
    if offset + 20 > packet.len() {
        return Ok(false);
    }
    let tcp = &mut packet[offset..];
    clamp_tcp_options(tcp, max_mss)
}

/// Перезаписывает MSS в TCP опциях если SYN установлен
fn clamp_tcp_options(tcp: &mut [u8], max_mss: u16) -> Result<bool, MtuError> {
    if tcp.len() < 20 {
        return Ok(false);
    }
    // TCP flags в байте 13 (0-indexed)
    let flags = tcp[13];
    let is_syn = (flags & 0x02) != 0;
    if !is_syn {
        return Ok(false);
    }

    // TCP data offset (верхние 4 бита байта 12), в 32-битных словах
    let doff = ((tcp[12] >> 4) as usize) * 4;
    if doff < 20 || doff > tcp.len() {
        return Err(MtuError::InvalidTcpHeader);
    }

    // Итерируемся по TCP опциям (начиная с байта 20)
    let opts = &mut tcp[20..doff];
    let mut i = 0;
    let mut modified = false;
    let mut old_mss = 0;

    while i < opts.len() {
        match opts[i] {
            0 => break, // End of options
            1 => { i += 1; } // NOP
            2 if i + 3 < opts.len() => {
                // MSS option: kind=2, len=4, value=u16
                let len = opts[i + 1] as usize;
                if len == 4 {
                    let cur_mss = u16::from_be_bytes([opts[i + 2], opts[i + 3]]);
                    if cur_mss > max_mss {
                        opts[i + 2..i + 4].copy_from_slice(&max_mss.to_be_bytes());
                        old_mss = cur_mss;
                        modified = true;
                    }
                }
                i += len.max(2);
            }
            _ => {
                // Другая опция: пропускаем
                if i + 1 >= opts.len() { break; }
                let len = opts[i + 1] as usize;
                i += len.max(2);
            }
        }
    }

    if modified {
        // Incremental TCP checksum update (RFC 1624)
        let hc = u16::from_be_bytes([tcp[16], tcp[17]]);
        let mut sum = (!hc) as u32;
        sum += (!old_mss) as u16 as u32;
        sum += max_mss as u32;
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }
        tcp[16..18].copy_from_slice(&(!sum as u16).to_be_bytes());
    }

    Ok(modified)
}

/// Стандартный internet checksum (RFC 1071)
pub fn internet_checksum(data: &[u8]) -> u16 {
    let mut sum: u32 = 0;
    let mut i = 0;
    while i + 1 < data.len() {
        sum += u16::from_be_bytes([data[i], data[i + 1]]) as u32;
        i += 2;
    }
    if i < data.len() {
        sum += (data[i] as u32) << 8;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

// ─── IP пакет helpers ────────────────────────────────────────────────────────

/// Возвращает длину IP пакета (из заголовка)
pub fn ip_packet_len(packet: &[u8]) -> Option<usize> {
    if packet.len() < 4 {
        return None;
    }
    match packet[0] >> 4 {
        4 if packet.len() >= 20 => {
            Some(u16::from_be_bytes([packet[2], packet[3]]) as usize)
        }
        6 if packet.len() >= 40 => {
            let payload_len = u16::from_be_bytes([packet[4], packet[5]]) as usize;
            Some(40 + payload_len)
        }
        _ => None,
    }
}

// ─── Тесты ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_syn_packet(mss: u16) -> Vec<u8> {
        // IPv4 (IHL=5, 20 bytes) + TCP (doff=6, 24 bytes) = 44 bytes
        let mut pkt = vec![0u8; 44];
        // IPv4 header
        pkt[0] = 0x45; // Version 4, IHL 5
        pkt[2..4].copy_from_slice(&44u16.to_be_bytes()); // total length
        pkt[9] = 6;    // Protocol TCP
        // TCP header (начинается с байта 20)
        pkt[32] = 0x60; // Data offset = 6 (24 байта = 20 + 4 опции)
        pkt[33] = 0x02; // SYN flag
        // MSS option (at TCP offset 20, i.e. byte 40)
        pkt[40] = 2; // kind
        pkt[41] = 4; // len
        pkt[42..44].copy_from_slice(&mss.to_be_bytes());
        pkt
    }

    #[test]
    fn test_mss_clamping_reduces_value() {
        let mut pkt = make_syn_packet(1460);
        let result = clamp_tcp_mss(&mut pkt, 1340).unwrap();
        assert!(result);
        // Проверяем что MSS изменился
        let mss = u16::from_be_bytes([pkt[42], pkt[43]]);
        assert_eq!(mss, 1340);
    }

    /// Build an IPv6 packet with a Routing extension header before TCP SYN.
    fn make_ipv6_syn_with_ext_header(mss: u16) -> Vec<u8> {
        // IPv6 base (40B) + Routing ext header (8B) + TCP (24B, doff=6) = 72 bytes
        let mut pkt = vec![0u8; 72];
        // IPv6 header
        pkt[0] = 0x60; // Version 6
        let payload_len: u16 = 8 + 24; // ext header + TCP
        pkt[4..6].copy_from_slice(&payload_len.to_be_bytes());
        pkt[6] = 43; // Next Header = Routing (extension header)
        // Routing extension header at offset 40 (8 bytes: next_hdr, len=0 → (0+1)*8=8)
        pkt[40] = 6;  // Next Header = TCP
        pkt[41] = 0;  // Hdr Ext Len = 0 → 8 bytes total
        // TCP header at offset 48
        let tcp_off = 48;
        pkt[tcp_off + 12] = 0x60; // Data offset = 6 (24 bytes)
        pkt[tcp_off + 13] = 0x02; // SYN flag
        // MSS option at tcp_off + 20
        pkt[tcp_off + 20] = 2; // kind
        pkt[tcp_off + 21] = 4; // len
        pkt[tcp_off + 22..tcp_off + 24].copy_from_slice(&mss.to_be_bytes());
        pkt
    }

    #[test]
    fn test_mss_clamping_ipv6_with_extension_header() {
        let mut pkt = make_ipv6_syn_with_ext_header(1460);
        let result = clamp_tcp_mss(&mut pkt, 1340).unwrap();
        assert!(result, "should clamp MSS through extension header");
        let mss = u16::from_be_bytes([pkt[70], pkt[71]]);
        assert_eq!(mss, 1340);
    }

    #[test]
    fn test_mss_clamping_ipv6_ext_header_skips_if_smaller() {
        let mut pkt = make_ipv6_syn_with_ext_header(1000);
        let result = clamp_tcp_mss(&mut pkt, 1340).unwrap();
        assert!(!result);
    }

    #[test]
    fn test_mss_clamping_skips_if_smaller() {
        let mut pkt = make_syn_packet(1000); // меньше max_mss
        let result = clamp_tcp_mss(&mut pkt, 1340).unwrap();
        assert!(!result); // не изменяли
        let mss = u16::from_be_bytes([pkt[42], pkt[43]]);
        assert_eq!(mss, 1000);
    }
}
