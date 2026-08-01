//! Observes where DNS queries actually go, by looking at packets leaving the TUN.
//!
//! Why observe instead of reading configuration: the app can set DNS servers on
//! the tunnel and the phone can override them (strict Private DNS does exactly
//! that), so a resolver name taken from settings answers "what is the system
//! supposed to use", not "where did the query go". Showing the former as if it
//! were the latter is how a user ends up trusting a resolver that is not being
//! used. The data path already sees every outbound packet, so the honest answer
//! is nearly free.
//!
//! Hot path: this runs per packet. No allocation, no locking — a few atomics and
//! at most ~40 bytes of header inspection, with an early bail for anything that
//! is not a DNS-shaped destination port.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::atomic::{AtomicU16, AtomicU32, AtomicU64, AtomicU8, Ordering};

/// Plain DNS.
const PORT_DO53: u16 = 53;
/// DNS-over-TLS. Worth tracking separately: strict Private DNS uses it, and it
/// is the case where the tunnel's own DNS servers are silently bypassed.
const PORT_DOT: u16 = 853;

const FAMILY_NONE: u8 = 0;
const FAMILY_V4: u8 = 4;
const FAMILY_V6: u8 = 6;

static FAMILY: AtomicU8 = AtomicU8::new(FAMILY_NONE);
static V4: AtomicU32 = AtomicU32::new(0);
static V6_HI: AtomicU64 = AtomicU64::new(0);
static V6_LO: AtomicU64 = AtomicU64::new(0);
static PORT: AtomicU16 = AtomicU16::new(0);
static QUERIES: AtomicU64 = AtomicU64::new(0);

/// A DNS destination seen on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DnsSighting {
    pub addr: IpAddr,
    /// 53 = plain DNS, 853 = DoT.
    pub port: u16,
    /// Queries observed since the last [`reset`].
    pub queries: u64,
}

impl DnsSighting {
    pub fn is_dot(&self) -> bool {
        self.port == PORT_DOT
    }
}

/// Clear observations. Call when a tunnel starts so a previous session's
/// resolver can never be shown next to a fresh tunnel.
pub fn reset() {
    FAMILY.store(FAMILY_NONE, Ordering::Relaxed);
    V4.store(0, Ordering::Relaxed);
    V6_HI.store(0, Ordering::Relaxed);
    V6_LO.store(0, Ordering::Relaxed);
    PORT.store(0, Ordering::Relaxed);
    QUERIES.store(0, Ordering::Relaxed);
}

/// The most recent DNS destination observed, if any.
pub fn last() -> Option<DnsSighting> {
    let queries = QUERIES.load(Ordering::Relaxed);
    let port = PORT.load(Ordering::Relaxed);
    match FAMILY.load(Ordering::Relaxed) {
        FAMILY_V4 => Some(DnsSighting {
            addr: IpAddr::V4(Ipv4Addr::from(V4.load(Ordering::Relaxed))),
            port,
            queries,
        }),
        FAMILY_V6 => {
            let hi = V6_HI.load(Ordering::Relaxed) as u128;
            let lo = V6_LO.load(Ordering::Relaxed) as u128;
            Some(DnsSighting {
                addr: IpAddr::V6(Ipv6Addr::from((hi << 64) | lo)),
                port,
                queries,
            })
        }
        _ => None,
    }
}

/// Inspect one outbound IP packet. Cheap and infallible — malformed or
/// uninteresting packets are ignored.
pub fn observe(pkt: &[u8]) {
    if pkt.len() < 20 {
        return;
    }
    match pkt[0] >> 4 {
        4 => observe_v4(pkt),
        6 => observe_v6(pkt),
        _ => {}
    }
}

fn observe_v4(pkt: &[u8]) {
    let ihl = ((pkt[0] & 0x0f) as usize) * 4;
    if ihl < 20 || pkt.len() < ihl + 4 {
        return;
    }
    // Only the first fragment carries the transport header; later fragments
    // would give us a garbage "port".
    let frag_off = u16::from_be_bytes([pkt[6], pkt[7]]) & 0x1fff;
    if frag_off != 0 {
        return;
    }
    let proto = pkt[9];
    if proto != 17 && proto != 6 {
        return;
    }
    let dport = u16::from_be_bytes([pkt[ihl + 2], pkt[ihl + 3]]);
    if !is_dns_port(dport) {
        return;
    }
    let addr = u32::from_be_bytes([pkt[16], pkt[17], pkt[18], pkt[19]]);
    V4.store(addr, Ordering::Relaxed);
    FAMILY.store(FAMILY_V4, Ordering::Relaxed);
    PORT.store(dport, Ordering::Relaxed);
    QUERIES.fetch_add(1, Ordering::Relaxed);
}

fn observe_v6(pkt: &[u8]) {
    if pkt.len() < 44 {
        return;
    }
    // Deliberately no extension-header walking: DNS in practice sits directly
    // behind the fixed header, and this runs per packet.
    let next_header = pkt[6];
    if next_header != 17 && next_header != 6 {
        return;
    }
    let dport = u16::from_be_bytes([pkt[42], pkt[43]]);
    if !is_dns_port(dport) {
        return;
    }
    let mut hi = [0u8; 8];
    let mut lo = [0u8; 8];
    hi.copy_from_slice(&pkt[24..32]);
    lo.copy_from_slice(&pkt[32..40]);
    V6_HI.store(u64::from_be_bytes(hi), Ordering::Relaxed);
    V6_LO.store(u64::from_be_bytes(lo), Ordering::Relaxed);
    FAMILY.store(FAMILY_V6, Ordering::Relaxed);
    PORT.store(dport, Ordering::Relaxed);
    QUERIES.fetch_add(1, Ordering::Relaxed);
}

#[inline]
fn is_dns_port(port: u16) -> bool {
    port == PORT_DO53 || port == PORT_DOT
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// The observer is process-global by design (one tunnel per process), so the
    /// tests must not run concurrently against it — otherwise one test's `reset`
    /// wipes another's sighting and failures look random.
    static SERIALIZE: Mutex<()> = Mutex::new(());

    /// Minimal IPv4 + UDP packet with the given destination and port.
    fn v4_udp(dst: [u8; 4], dport: u16) -> Vec<u8> {
        let mut p = vec![0u8; 28];
        p[0] = 0x45; // version 4, IHL 5
        p[9] = 17; // UDP
        p[16..20].copy_from_slice(&dst);
        p[22..24].copy_from_slice(&dport.to_be_bytes());
        p
    }

    #[test]
    fn records_plain_dns_destination() {
        let _g = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        observe(&v4_udp([8, 8, 8, 8], 53));
        let s = last().expect("sighting");
        assert_eq!(s.addr, "8.8.8.8".parse::<IpAddr>().unwrap());
        assert_eq!(s.port, 53);
        assert!(!s.is_dot());
        assert_eq!(s.queries, 1);
    }

    #[test]
    fn records_dot_separately() {
        let _g = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        observe(&v4_udp([1, 1, 1, 1], 853));
        assert!(last().unwrap().is_dot());
    }

    /// Bulk traffic must never be mistaken for DNS — otherwise the UI would
    /// name a random web server as the resolver.
    #[test]
    fn ignores_non_dns_traffic() {
        let _g = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        observe(&v4_udp([93, 184, 216, 34], 443));
        assert!(last().is_none());
        assert!(!pkt_too_short_panics());
    }

    fn pkt_too_short_panics() -> bool {
        observe(&[0x45, 0x00]);
        observe(&[]);
        observe(&[0x60; 30]); // v6 header claimed but truncated
        false
    }

    /// A later IP fragment has no transport header; bytes at the port offset
    /// are payload and could read as 53 by chance.
    #[test]
    fn ignores_non_first_fragments() {
        let _g = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        let mut p = v4_udp([8, 8, 8, 8], 53);
        p[6] = 0x00;
        p[7] = 0x10; // fragment offset != 0
        observe(&p);
        assert!(last().is_none());
    }

    #[test]
    fn reset_clears_previous_session() {
        let _g = SERIALIZE.lock().unwrap_or_else(|e| e.into_inner());
        reset();
        observe(&v4_udp([8, 8, 8, 8], 53));
        assert!(last().is_some());
        reset();
        assert!(last().is_none());
    }
}
