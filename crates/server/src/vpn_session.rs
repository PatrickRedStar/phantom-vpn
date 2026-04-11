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

use phantom_core::wire::{flow_stream_idx, N_STREAMS};

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

/// Transport-agnostic VPN session / SessionCoordinator.
///
/// For the TLS-over-TCP h2_server path this aggregates up to `N_STREAMS` parallel
/// TCP connections from the same client (identified by cert fingerprint). Each
/// physical connection claims one slot in `data_sends[stream_idx]`. Slots can be
/// `None` (disconnected) and are dynamically replaced on reconnect.
///
/// The QUIC path historically registered a `Vec` of stream senders at construction
/// time; we now write them into the same slotted structure, with each QUIC sub-stream
/// occupying a dedicated slot.
pub struct VpnSession {
    /// Session creation timestamp (unix seconds) for hard lifetime expiry.
    pub created_at:    u64,
    /// Per-stream frame senders (batched frames → transport write loop).
    /// Fixed-length `N_STREAMS` slots; `None` = stream currently disconnected.
    pub data_sends:    Vec<std::sync::Mutex<Option<mpsc::Sender<Bytes>>>>,
    /// Per-stream packet channels for TUN→transport packets. One sender per
    /// stream_idx; `tun_dispatch_loop` picks the slot via `flow_stream_idx`.
    /// Each receiver is drained by a dedicated `stream_batch_loop` task.
    /// Wrapped in `Mutex<Vec<Option<...>>>` so `close()` can drop all senders
    /// to unblock the per-stream batch loops.
    pub tun_pkt_txs:   std::sync::Mutex<Vec<Option<mpsc::Sender<Bytes>>>>,
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
    /// Client cert fingerprint (hex). Set for h2_server path — used to locate the
    /// coordinator across reconnects of individual streams.
    pub fingerprint:   String,
}

impl VpnSession {
    /// Build a new coordinator with all stream slots empty.
    /// Used by h2_server path; caller will attach streams as clients connect.
    pub fn new_coordinator(
        fingerprint: String,
        tun_pkt_txs: Vec<mpsc::Sender<Bytes>>,
        close_tx: tokio::sync::oneshot::Sender<()>,
    ) -> Self {
        let now = now_unix_secs();
        let data_sends = (0..N_STREAMS)
            .map(|_| std::sync::Mutex::new(None))
            .collect();
        let tun_pkt_txs_wrapped: Vec<Option<mpsc::Sender<Bytes>>> =
            tun_pkt_txs.into_iter().map(Some).collect();
        Self {
            created_at: now,
            data_sends,
            tun_pkt_txs: std::sync::Mutex::new(tun_pkt_txs_wrapped),
            close_tx: std::sync::Mutex::new(Some(close_tx)),
            last_seen: AtomicU64::new(now),
            bytes_rx: AtomicU64::new(0),
            bytes_tx: AtomicU64::new(0),
            dest_log: std::sync::Mutex::new(std::collections::VecDeque::new()),
            stats_samples: std::sync::Mutex::new(std::collections::VecDeque::new()),
            dns_cache: DashMap::new(),
            log_counter: AtomicU64::new(0),
            fingerprint,
        }
    }

    /// Attach a stream sender at `stream_idx`. Returns the previously attached
    /// sender (if any), which the caller should drop to signal the old writer
    /// loop to terminate.
    pub fn attach_stream(
        &self,
        stream_idx: usize,
        sender: mpsc::Sender<Bytes>,
    ) -> Option<mpsc::Sender<Bytes>> {
        if stream_idx >= self.data_sends.len() {
            return Some(sender);
        }
        let mut slot = self.data_sends[stream_idx].lock().unwrap();
        slot.replace(sender)
    }

    /// Detach a stream sender at `stream_idx` (called when the transport write
    /// loop exits). Only clears the slot if the currently-held sender matches
    /// `expected`, to avoid clobbering a fresh reconnect.
    pub fn detach_stream_if(&self, stream_idx: usize, expected: &mpsc::Sender<Bytes>) {
        if stream_idx >= self.data_sends.len() { return; }
        let mut slot = self.data_sends[stream_idx].lock().unwrap();
        if let Some(cur) = slot.as_ref() {
            if cur.same_channel(expected) {
                *slot = None;
            }
        }
    }

    /// Returns true if every stream slot is empty (all connections dead).
    pub fn all_streams_down(&self) -> bool {
        self.data_sends.iter().all(|m| m.lock().unwrap().is_none())
    }
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
    ///
    /// For the QUIC path a background task awaits `close_rx` and calls
    /// `connection.close()`. For the h2 path there is no single connection,
    /// so we drop every stream sender — the corresponding writer tasks will
    /// exit, which drops the TLS write halves and closes each TCP socket.
    pub fn close(&self) {
        if let Ok(mut guard) = self.close_tx.lock() {
            if let Some(tx) = guard.take() {
                let _ = tx.send(());
            }
        }
        for slot in self.data_sends.iter() {
            if let Ok(mut s) = slot.lock() {
                *s = None;
            }
        }
        // Drop every per-stream TUN sender — this wakes each stream_batch_loop
        // with `pkt_rx.recv() == None` once all other references are gone.
        if let Ok(mut txs) = self.tun_pkt_txs.lock() {
            for slot in txs.iter_mut() {
                *slot = None;
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

/// Fingerprint-keyed map used by the h2_server path to find the
/// `VpnSession` across reconnects of individual sub-streams.
pub type SessionByFp = Arc<DashMap<String, Arc<VpnSession>>>;

pub fn new_session_by_fp() -> SessionByFp {
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
    mut pkt_rx: mpsc::Receiver<Bytes>,
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

            let idx = flow_stream_idx(&pkt, N_STREAMS);
            // Snapshot the sender at slot `idx` under the mutex, then release
            // the lock before try_send.
            let sender_opt: Option<mpsc::Sender<Bytes>> = {
                let guard = session.tun_pkt_txs.lock().unwrap();
                guard.get(idx).and_then(|s| s.clone())
            };
            let Some(sender) = sender_opt else {
                drop_closed += 1;
                if drop_closed == 1 || drop_closed % 128 == 0 {
                    tracing::warn!(
                        "TUN dispatch idx={} closed for {} (dropped_closed={})",
                        idx, dst, drop_closed
                    );
                }
                continue;
            };
            match sender.try_send(pkt) {
                Ok(()) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Full(_pkt)) => {
                    drop_full += 1;
                    if drop_full == 1 || drop_full % 1024 == 0 {
                        tracing::warn!(
                            "TUN dispatch idx={} full for {} (dropped_full={})",
                            idx, dst, drop_full
                        );
                    }
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_pkt)) => {
                    drop_closed += 1;
                    if drop_closed == 1 || drop_closed % 128 == 0 {
                        tracing::warn!(
                            "TUN dispatch idx={} closed for {} (dropped_closed={})",
                            idx, dst, drop_closed
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

/// Remove the coordinator from the fingerprint map (if still matching).
pub fn reap_session_fp(by_fp: &SessionByFp, session: &Arc<VpnSession>) {
    let fp = session.fingerprint.clone();
    if fp.is_empty() { return; }
    by_fp.remove_if(&fp, |_, v| Arc::ptr_eq(v, session));
}

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

// ─── Per-stream batch loop (transport-agnostic) ─────────────────────────────

/// One task per `stream_idx`. Reads pre-dispatched packets (all with the same
/// `flow_stream_idx`) from a dedicated channel, builds wire-format batch frames,
/// and writes them directly to `session.data_sends[stream_idx]`.
///
/// Replaces the old `session_batch_loop` + round-robin design. Removes
/// serialization at the round-robin send point — each stream now has its own
/// batch pipeline, so a slow/dead stream cannot backpressure the others.
pub async fn stream_batch_loop(
    mut pkt_rx: mpsc::Receiver<Bytes>,
    session:    Arc<VpnSession>,
    stream_idx: usize,
) {
    use bytes::BytesMut;
    use phantom_core::wire::{build_batch_plaintext, BATCH_MAX_PLAINTEXT};

    // Cap at 40 packets × 1350 MTU = 54000 bytes, comfortably under
    // BATCH_MAX_PLAINTEXT = 65536. Prevents the `BufferTooSmall` silent-drop
    // class that triggered at 256 packets per batch.
    const MAX_PKTS_PER_BATCH: usize = 40;

    let buf_size = 4 + BATCH_MAX_PLAINTEXT + 16;
    let mut frame_buf = BytesMut::with_capacity(buf_size);
    frame_buf.resize(buf_size, 0);

    let mut pending: Vec<Bytes> = Vec::with_capacity(MAX_PKTS_PER_BATCH);

    let mut drop_detached: u64 = 0;

    loop {
        let first = match pkt_rx.recv().await {
            Some(p) => p,
            None => {
                tracing::debug!(
                    "stream_batch_loop[{}]: pkt_rx closed, exiting (fp={}…)",
                    stream_idx,
                    &session.fingerprint[..16.min(session.fingerprint.len())]
                );
                return;
            }
        };

        pending.clear();
        pending.push(first);

        while pending.len() < MAX_PKTS_PER_BATCH {
            match pkt_rx.try_recv() {
                Ok(pkt) => pending.push(pkt),
                Err(_) => break,
            }
        }

        let refs: Vec<&[u8]> = pending.iter().map(|p| p.as_ref()).collect();

        if frame_buf.len() < buf_size {
            frame_buf.resize(buf_size, 0);
        }

        let pt_len = match build_batch_plaintext(&refs, 0, &mut frame_buf[4..]) {
            Ok(n) => n,
            Err(e) => {
                // Shouldn't happen under MAX_PKTS_PER_BATCH=40 cap; treat as a bug.
                tracing::warn!(
                    "stream_batch_loop[{}]: build_batch_plaintext failed: {:?} ({} pkts)",
                    stream_idx, e, pending.len()
                );
                continue;
            }
        };

        frame_buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
        let total = 4 + pt_len;

        let frame = frame_buf.split_to(total).freeze();
        if frame_buf.capacity() < buf_size {
            frame_buf.reserve(buf_size - frame_buf.capacity());
        }
        frame_buf.resize(buf_size, 0);

        // Re-snapshot the sender every iteration — the slot can flip to a
        // fresh sender after reconnect. Do NOT cache.
        let sender_opt: Option<mpsc::Sender<Bytes>> = {
            let slot = session.data_sends[stream_idx].lock().unwrap();
            slot.clone()
        };

        let Some(sender) = sender_opt else {
            // Stream currently detached. DROP the frame — never block the
            // whole batch pipeline waiting for a dead physical connection.
            drop_detached += 1;
            if drop_detached == 1 || drop_detached % 1024 == 0 {
                tracing::warn!(
                    "stream_batch_loop[{}]: slot detached, dropped {} frames (fp={}…)",
                    stream_idx, drop_detached,
                    &session.fingerprint[..16.min(session.fingerprint.len())]
                );
            }
            // If the whole session is gone AND our pkt channel is disconnected,
            // exit. Otherwise keep looping — reconnect may attach a new slot.
            if session.all_streams_down()
                && matches!(
                    pkt_rx.try_recv(),
                    Err(tokio::sync::mpsc::error::TryRecvError::Disconnected)
                )
            {
                return;
            }
            continue;
        };

        if let Err(_e) = sender.send(frame).await {
            // Send-half dropped — writer loop has exited. Next iteration will
            // re-snapshot and either find a reconnected slot or drop again.
            tracing::debug!(
                "stream_batch_loop[{}]: send_to_writer closed, will re-snapshot",
                stream_idx
            );
            continue;
        }

        session.bytes_tx.fetch_add(total as u64, Ordering::Relaxed);
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
