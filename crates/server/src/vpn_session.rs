//! Transport-agnostic VPN session types.
//! Shared between QUIC and HTTP/2 transports.

use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use dashmap::DashMap;
use tokio::sync::{mpsc, RwLock};

// ─── Session types ──────────────────────────────────────────────────────────

/// One logged destination visit (client → server direction).
#[derive(Clone)]
pub struct DestEntry {
    pub ts:       u64,
    pub dst_ip:   Ipv4Addr,
    pub dst_host: Option<String>,
    pub dst_port: u16,
    pub proto:    u8,   // 6=TCP, 17=UDP, 1=ICMP, else raw
    pub bytes:    u32,
}

/// One time-series sample (snapshot every 60 s).
#[derive(Clone)]
pub struct StatsSample {
    pub ts:       u64,
    pub bytes_rx: u64,
    pub bytes_tx: u64,
}

/// Transport-agnostic VPN session.
/// Works with both QUIC and HTTP/2 transports.
pub struct VpnSession {
    /// Session creation timestamp (unix seconds) for hard lifetime expiry.
    pub created_at:    u64,
    /// Per-stream frame senders (batched frames → transport write loop)
    pub data_sends:    Vec<mpsc::Sender<Bytes>>,
    /// Per-session channel for TUN→transport packets (fed by tun_dispatch_loop)
    pub tun_pkt_tx:    mpsc::Sender<Vec<u8>>,
    /// Transport-agnostic shutdown: send () to close the underlying connection
    pub close_tx:      std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    pub last_seen:     AtomicU64,
    pub bytes_rx:      AtomicU64,
    pub bytes_tx:      AtomicU64,
    pub dest_log:      std::sync::Mutex<std::collections::VecDeque<DestEntry>>,
    pub stats_samples: std::sync::Mutex<std::collections::VecDeque<StatsSample>>,
    /// Passive DNS cache: IPv4 → hostname, populated from DNS responses (src_port=53)
    pub dns_cache:     DashMap<Ipv4Addr, String>,
    /// Counter for dest_log sampling (log every 64th packet to reduce mutex contention)
    pub log_counter:   AtomicU64,
}

impl VpnSession {
    pub fn touch(&self) {
        self.last_seen.store(now_unix_secs(), Ordering::Relaxed);
    }

    pub fn is_idle(&self, idle_secs: u64) -> bool {
        let now = now_unix_secs();
        now.saturating_sub(self.last_seen.load(Ordering::Relaxed)) > idle_secs
    }

    pub fn is_hard_expired(&self, hard_timeout_secs: u64) -> bool {
        let now = now_unix_secs();
        now.saturating_sub(self.created_at) > hard_timeout_secs
    }

    /// Signal the transport layer to close the underlying connection.
    pub fn close(&self) {
        if let Ok(mut guard) = self.close_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(());
            }
        }
    }
}

#[inline]
fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

pub type VpnSessionMap = Arc<DashMap<IpAddr, Arc<VpnSession>>>;

pub fn new_session_map() -> VpnSessionMap {
    Arc::new(DashMap::new())
}

/// Register tunnel IP to session, atomically replacing previous mapping.
/// If a different previous session existed for this IP, it is closed immediately.
/// Returns `true` when a different session was replaced.
pub fn register_session_ip(
    sessions: &VpnSessionMap,
    tunnel_ip: IpAddr,
    new_session: Arc<VpnSession>,
) -> bool {
    if let Some(old_session) = sessions.insert(tunnel_ip, new_session.clone()) {
        if !Arc::ptr_eq(&old_session, &new_session) {
            old_session.close();
            return true;
        }
    }
    false
}

// ─── Client allowlist (fingerprint-based) ───────────────────────────────────

/// Set of allowed client certificate SHA-256 fingerprints (hex, lowercase).
/// Empty set = allow all authenticated clients (no filtering).
/// Wrapped in RwLock for hot-reload via SIGHUP.
pub type ClientAllowList = Arc<RwLock<HashSet<String>>>;

pub fn new_allow_list() -> ClientAllowList {
    Arc::new(RwLock::new(HashSet::new()))
}

/// Load allowed fingerprints from clients.json.
pub fn load_allow_list(path: &Path) -> anyhow::Result<HashSet<String>> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("Failed to read {}: {}", path.display(), e))?;
    let val: serde_json::Value = serde_json::from_str(&content)
        .map_err(|e| anyhow::anyhow!("Failed to parse {}: {}", path.display(), e))?;

    let mut fps = HashSet::new();
    if let Some(clients) = val.get("clients").and_then(|c| c.as_object()) {
        for (name, info) in clients {
            if info.get("enabled").and_then(|e| e.as_bool()).unwrap_or(true) {
                if let Some(fp) = info.get("fingerprint").and_then(|f| f.as_str()) {
                    fps.insert(fp.to_lowercase());
                    tracing::debug!("Allowed client: {} (fp={}…)", name, &fp[..8.min(fp.len())]);
                }
            }
        }
    }
    Ok(fps)
}

/// Extract SHA-256 fingerprint from a DER-encoded X.509 certificate.
pub fn cert_fingerprint(cert_der: &[u8]) -> String {
    use sha2::{Sha256, Digest};
    let hash = Sha256::digest(cert_der);
    hash.iter().map(|b| format!("{:02x}", b)).collect()
}

// ─── TUN → per-session dispatch (transport-agnostic) ────────────────────────

pub async fn tun_dispatch_loop(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    sessions:   VpnSessionMap,
) -> anyhow::Result<()> {
    tracing::info!("TUN→transport dispatch loop started");
    let mut drop_full = 0u64;
    let mut drop_closed = 0u64;

    loop {
        let pkt = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        if pkt.len() < 20 { continue; }

        let dst = IpAddr::V4(Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]));

        if let Some(session_ref) = sessions.get(&dst) {
            let session = session_ref.value().clone();
            // Intercept DNS responses (src_port=53) for passive hostname cache
            if pkt.len() >= 28 && pkt[9] == 17 {
                let ihl = ((pkt[0] & 0x0F) as usize) * 4;
                if ihl + 8 <= pkt.len() {
                    let src_port = u16::from_be_bytes([pkt[ihl], pkt[ihl + 1]]);
                    if src_port == 53 {
                        dns_parse_response(&pkt[ihl + 8..], &session);
                    }
                }
            }

            match session.tun_pkt_tx.try_send(pkt) {
                Ok(()) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Full(_pkt)) => {
                    drop_full += 1;
                    if drop_full == 1 || drop_full % 1024 == 0 {
                        tracing::warn!(
                            "TUN dispatch queue full for {} (dropped_full={})",
                            dst,
                            drop_full
                        );
                    }
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_pkt)) => {
                    drop_closed += 1;
                    if drop_closed == 1 || drop_closed % 128 == 0 {
                        tracing::warn!(
                            "TUN dispatch channel closed for {} (dropped_closed={})",
                            dst,
                            drop_closed
                        );
                    }
                    if sessions.remove_if(&dst, |_, current| Arc::ptr_eq(current, &session)).is_some() {
                        session.close();
                        tracing::info!("Removed closed session mapping for tunnel IP {}", dst);
                    }
                }
            }
        }
    }

    Ok(())
}

// ─── Cleanup task ───────────────────────────────────────────────────────────

pub async fn cleanup_task(sessions: VpnSessionMap, idle_secs: u64, hard_timeout_secs: u64) {
    #[derive(Copy, Clone)]
    enum ExpireReason {
        Idle,
        HardTimeout,
    }

    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
    loop {
        interval.tick().await;

        let mut to_remove: Vec<(IpAddr, ExpireReason)> = Vec::new();
        let now_ts = now_unix_secs();
        for entry in sessions.iter() {
            if entry.value().is_idle(idle_secs) {
                to_remove.push((*entry.key(), ExpireReason::Idle));
            } else if entry.value().is_hard_expired(hard_timeout_secs) {
                to_remove.push((*entry.key(), ExpireReason::HardTimeout));
            } else {
                let bytes_rx = entry.value().bytes_rx.load(Ordering::Relaxed);
                let bytes_tx = entry.value().bytes_tx.load(Ordering::Relaxed);
                if let Ok(mut samples) = entry.value().stats_samples.lock() {
                    if samples.len() >= 60 { samples.pop_front(); }
                    samples.push_back(StatsSample { ts: now_ts, bytes_rx, bytes_tx });
                }
            }
        }

        let mut removed_idle = 0usize;
        let mut removed_hard = 0usize;
        for (ip, reason) in to_remove {
            let removed = sessions.remove_if(&ip, |_, v| match reason {
                ExpireReason::Idle => v.is_idle(idle_secs),
                ExpireReason::HardTimeout => v.is_hard_expired(hard_timeout_secs),
            });
            if let Some((_, session)) = removed {
                session.close();
                match reason {
                    ExpireReason::Idle => {
                        removed_idle += 1;
                        tracing::info!("Session expired (idle): tunnel IP {}", ip);
                    }
                    ExpireReason::HardTimeout => {
                        removed_hard += 1;
                        tracing::info!("Session expired (hard-timeout): tunnel IP {}", ip);
                    }
                }
            }
        }

        let removed_total = removed_idle + removed_hard;
        if removed_total > 0 {
            tracing::info!(
                "Cleanup: removed {} sessions (idle={}, hard={}), {} active",
                removed_total,
                removed_idle,
                removed_hard,
                sessions.len()
            );
        }
    }
}

// ─── Passive DNS cache helpers ──────────────────────────────────────────────

/// Parse a DNS response packet and insert any A-record mappings into the session's dns_cache.
pub fn dns_parse_response(data: &[u8], session: &VpnSession) {
    if data.len() < 12 { return; }
    let flags = u16::from_be_bytes([data[2], data[3]]);
    if flags & 0x8000 == 0 || flags & 0x000F != 0 { return; }

    let qdcount = u16::from_be_bytes([data[4], data[5]]) as usize;
    let ancount = u16::from_be_bytes([data[6], data[7]]) as usize;
    if ancount == 0 { return; }

    let mut pos = 12;
    for _ in 0..qdcount {
        if !dns_skip_name(data, &mut pos) { return; }
        pos += 4;
    }

    if session.dns_cache.len() > 4096 { session.dns_cache.clear(); }

    for _ in 0..ancount {
        let name_start = pos;
        if !dns_skip_name(data, &mut pos) { return; }
        let _ = name_start;

        if pos + 10 > data.len() { return; }
        let rtype  = u16::from_be_bytes([data[pos], data[pos + 1]]);
        let rdlen  = u16::from_be_bytes([data[pos + 8], data[pos + 9]]) as usize;
        pos += 10;

        if pos + rdlen > data.len() { return; }

        if rtype == 1 && rdlen == 4 {
            let ip = Ipv4Addr::new(data[pos], data[pos + 1], data[pos + 2], data[pos + 3]);
            let mut name_pos = pos - rdlen - 10;
            if let Some(hostname) = dns_read_name(data, &mut name_pos) {
                if !hostname.is_empty() {
                    session.dns_cache.insert(ip, hostname);
                }
            }
        }
        pos += rdlen;
    }
}

fn dns_skip_name(data: &[u8], pos: &mut usize) -> bool {
    let mut jumps = 0;
    loop {
        if *pos >= data.len() { return false; }
        let b = data[*pos];
        if b == 0 { *pos += 1; return true; }
        if b & 0xC0 == 0xC0 {
            if *pos + 1 >= data.len() { return false; }
            *pos += 2;
            return true;
        }
        *pos += 1 + b as usize;
        jumps += 1;
        if jumps > 128 { return false; }
    }
}

// ─── Per-session batch loop (transport-agnostic) ────────────────────────────

/// Reads TUN packets from per-session channel, groups by flow hash,
/// builds wire-format batches with H.264 shaping, and sends Bytes
/// through per-stream frame channels to the transport write loops.
pub async fn session_batch_loop(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    session:    Arc<VpnSession>,
    mut shaper: phantom_core::shaper::H264Shaper,
    use_shaper: bool,
) {
    use phantom_core::wire::{build_batch_plaintext, flow_stream_idx, BATCH_MAX_PLAINTEXT};

    let buf_size = 4 + BATCH_MAX_PLAINTEXT + 16;
    let mut frame_buf = vec![0u8; buf_size];
    let n_streams = session.data_sends.len();

    // Pre-allocate to avoid per-iteration heap allocation
    let mut stream_batches: Vec<Vec<Vec<u8>>> = (0..n_streams).map(|_| Vec::with_capacity(64)).collect();

    loop {
        let first = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        // Clear per-stream batches without reallocating
        for b in stream_batches.iter_mut() { b.clear(); }

        let idx = flow_stream_idx(&first, n_streams);
        stream_batches[idx].push(first);

        // Drain more (up to 256)
        let mut collected = 1usize;
        while collected < 256 {
            match pkt_rx.try_recv() {
                Ok(pkt) => {
                    let idx = flow_stream_idx(&pkt, n_streams);
                    stream_batches[idx].push(pkt);
                    collected += 1;
                }
                Err(_) => break,
            }
        }

        // Build and send batch per stream
        for (idx, batch) in stream_batches.iter().enumerate() {
            if batch.is_empty() { continue; }

            let refs: Vec<&[u8]> = batch.iter().map(|p| p.as_slice()).collect();
            let target_bytes = if use_shaper {
                let data_size: usize = refs.iter().map(|p| 2 + p.len()).sum::<usize>() + 2;
                let frame = shaper.next_frame();
                shaper.report_data_size(data_size, frame.target_bytes);
                frame.target_bytes
            } else {
                0 // H2: no padding (TCP/TLS hides packet structure from DPI)
            };
            let pt_len = match build_batch_plaintext(&refs, target_bytes, &mut frame_buf[4..]) {
                Ok(n) => n,
                Err(_) => continue,
            };

            frame_buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());

            let frame = Bytes::copy_from_slice(&frame_buf[..4 + pt_len]);
            if session.data_sends[idx].send(frame).await.is_err() {
                return; // session closed
            }
            session.bytes_tx.fetch_add((4 + pt_len) as u64, Ordering::Relaxed);
        }
    }
}

// ─── DNS name parsing helpers ───────────────────────────────────────────────

fn dns_read_name(data: &[u8], pos: &mut usize) -> Option<String> {
    let mut name = String::with_capacity(64);
    let mut p = *pos;
    let mut jumped = false;
    let mut jumps = 0;

    loop {
        if p >= data.len() { return None; }
        let b = data[p];
        if b == 0 {
            if !jumped { *pos = p + 1; }
            break;
        }
        if b & 0xC0 == 0xC0 {
            if p + 1 >= data.len() { return None; }
            if !jumped { *pos = p + 2; }
            p = ((b as usize & 0x3F) << 8) | data[p + 1] as usize;
            jumped = true;
            jumps += 1;
            if jumps > 16 { return None; }
            continue;
        }
        let len = b as usize;
        p += 1;
        if p + len > data.len() { return None; }
        if !name.is_empty() { name.push('.'); }
        name.push_str(std::str::from_utf8(&data[p..p + len]).unwrap_or("?"));
        p += len;
    }
    Some(name)
}
