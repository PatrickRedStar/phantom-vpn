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

use phantom_core::wire::flow_stream_idx;

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
/// For the TLS-over-TCP h2_server path this aggregates up to `effective_n` parallel
/// TCP connections from the same client (identified by cert fingerprint), where
/// `effective_n = min(server_n_data_streams, client_max_streams)` is negotiated
/// on the first handshake. Each physical connection claims one slot in
/// `data_sends[stream_idx]`. Slots can be `None` (disconnected) and are
/// dynamically replaced on reconnect.
pub struct VpnSession {
    /// Session creation timestamp (unix seconds) for hard lifetime expiry.
    pub created_at:    u64,
    /// Negotiated stream count for THIS session. `data_sends.len() == effective_n`
    /// and `flow_stream_idx` must be called with this value (not MAX_N_STREAMS).
    pub effective_n:   usize,
    /// Per-stream frame senders (batched frames → transport write loop).
    /// Length == `effective_n`; `None` = stream currently disconnected.
    pub data_sends:    Vec<std::sync::Mutex<Option<mpsc::Sender<Bytes>>>>,
    /// Per-stream attachment generation counter. Incremented on every
    /// `attach_stream` under the slot's mutex. The writer task returns this
    /// token to `detach_stream_gen` to clear the slot ONLY if a newer
    /// reconnect has not happened in the meantime — avoids clobbering a fresh
    /// sender with a stale detach from the previous connection, and removes
    /// the need to hold a `Sender` clone for `same_channel` comparison (the
    /// clone was leaking frame_rx.recv() liveness, see v0.18.0 hotfix notes).
    pub attach_gen:    Vec<AtomicU64>,
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
    /// Passive DNS cache: IPv4 → (hostname, insert_time), populated from DNS responses (src_port=53).
    /// LRU with capacity 2048 and 5-minute TTL per entry.
    pub dns_cache:     std::sync::Mutex<lru::LruCache<Ipv4Addr, (String, std::time::Instant)>>,
    /// Counter for dest_log sampling (log every 64th packet to reduce mutex contention)
    pub log_counter:   AtomicU64,
    /// Client cert fingerprint (hex). Set for h2_server path — used to locate the
    /// coordinator across reconnects of individual streams.
    pub fingerprint:   String,
}

impl VpnSession {
    /// Build a new coordinator with all stream slots empty.
    /// Used by h2_server path; caller will attach streams as clients connect.
    /// `effective_n` is the negotiated stream count (`min(server, client)`),
    /// must equal `tun_pkt_txs.len()`.
    pub fn new_coordinator(
        fingerprint: String,
        effective_n: usize,
        tun_pkt_txs: Vec<mpsc::Sender<Bytes>>,
        close_tx: tokio::sync::oneshot::Sender<()>,
    ) -> Self {
        assert_eq!(
            tun_pkt_txs.len(), effective_n,
            "new_coordinator: tun_pkt_txs length must equal effective_n"
        );
        let now = now_unix_secs();
        let data_sends = (0..effective_n)
            .map(|_| std::sync::Mutex::new(None))
            .collect();
        let attach_gen = (0..effective_n).map(|_| AtomicU64::new(0)).collect();
        let tun_pkt_txs_wrapped: Vec<Option<mpsc::Sender<Bytes>>> =
            tun_pkt_txs.into_iter().map(Some).collect();
        Self {
            created_at: now,
            effective_n,
            data_sends,
            attach_gen,
            tun_pkt_txs: std::sync::Mutex::new(tun_pkt_txs_wrapped),
            close_tx: std::sync::Mutex::new(Some(close_tx)),
            last_seen: AtomicU64::new(now),
            bytes_rx: AtomicU64::new(0),
            bytes_tx: AtomicU64::new(0),
            dest_log: std::sync::Mutex::new(std::collections::VecDeque::new()),
            stats_samples: std::sync::Mutex::new(std::collections::VecDeque::new()),
            dns_cache: std::sync::Mutex::new(lru::LruCache::new(
                std::num::NonZeroUsize::new(2048).unwrap(),
            )),
            log_counter: AtomicU64::new(0),
            fingerprint,
        }
    }

    /// Attach a stream sender at `stream_idx`. Returns a generation token that
    /// the caller must pass to `detach_stream_gen` when the writer exits — the
    /// detach then only clears the slot if no newer reconnect has taken place
    /// under that stream_idx. Any previously-held sender in the slot is
    /// dropped immediately, which signals the old writer to terminate.
    pub fn attach_stream(
        &self,
        stream_idx: usize,
        sender: mpsc::Sender<Bytes>,
    ) -> u64 {
        if stream_idx >= self.data_sends.len() {
            return 0;
        }
        let mut slot = self.data_sends[stream_idx].lock().unwrap();
        // Increment and slot update are both under the mutex, so a concurrent
        // detach observing `attach_gen == gen` is guaranteed to see our Sender.
        let gen = self.attach_gen[stream_idx]
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        *slot = Some(sender); // drops the old sender, if any
        gen
    }

    /// Detach a stream sender at `stream_idx` using the generation token that
    /// `attach_stream` returned. Only clears the slot if no newer `attach_stream`
    /// has overwritten this slot in the meantime.
    pub fn detach_stream_gen(&self, stream_idx: usize, gen: u64) {
        if stream_idx >= self.data_sends.len() { return; }
        let mut slot = self.data_sends[stream_idx].lock().unwrap();
        if self.attach_gen[stream_idx].load(Ordering::Acquire) == gen {
            *slot = None;
        }
    }

    /// Returns true if every stream slot is empty (all connections dead).
    pub fn all_streams_down(&self) -> bool {
        self.data_sends.iter().all(|m| m.lock().unwrap().is_none())
    }
}

/// DNS cache TTL: entries older than this are evicted on read.
const DNS_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(300);

impl VpnSession {
    /// Look up a hostname in the DNS cache. Returns `None` if not found or expired (TTL 5 min).
    pub fn dns_lookup(&self, ip: &Ipv4Addr) -> Option<String> {
        let mut cache = self.dns_cache.lock().ok()?;
        // peek does not promote — avoids keeping expired entries "hot"
        let expired = match cache.peek(ip) {
            Some((_, inserted)) => inserted.elapsed() > DNS_CACHE_TTL,
            None => return None,
        };
        if expired {
            cache.pop(ip);
            None
        } else {
            // Now promote via get and clone
            cache.get(ip).map(|(h, _)| h.clone())
        }
    }

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

            let idx = flow_stream_idx(&pkt, session.effective_n);
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

pub async fn cleanup_task(
    sessions: VpnSessionMap,
    sessions_by_fp: SessionByFp,
    idle_secs: u64,
    hard_timeout_secs: u64,
) {
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
                // Also reap the fingerprint-keyed index so a reconnect from
                // the same client creates a fresh coordinator with live
                // stream_batch_loops — not a zombie whose batch loops have
                // already exited as a side-effect of close() dropping every
                // tun_pkt_tx (v0.18 post-ship NL-direct download=0 bug).
                reap_session_fp(&sessions_by_fp, &session);
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

    // Collect A-record entries before acquiring the cache lock
    let mut entries: Vec<(Ipv4Addr, String)> = Vec::new();

    for _ in 0..ancount {
        let name_start = pos;
        if !dns_skip_name(data, &mut pos) { return; }

        if pos + 10 > data.len() { return; }
        let rtype  = u16::from_be_bytes([data[pos], data[pos + 1]]);
        let rdlen  = u16::from_be_bytes([data[pos + 8], data[pos + 9]]) as usize;
        pos += 10;

        if pos + rdlen > data.len() { return; }

        if rtype == 1 && rdlen == 4 {
            let ip = Ipv4Addr::new(data[pos], data[pos + 1], data[pos + 2], data[pos + 3]);
            let mut name_pos = name_start;
            if let Some(hostname) = dns_read_name(data, &mut name_pos) {
                if !hostname.is_empty() {
                    entries.push((ip, hostname));
                }
            }
        }
        pos += rdlen;
    }

    if !entries.is_empty() {
        if let Ok(mut cache) = session.dns_cache.lock() {
            let now = std::time::Instant::now();
            for (ip, hostname) in entries {
                cache.put(ip, (hostname, now));
            }
        }
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

// ─── Tests ──────────────────────────────────────────────────────────────────

#[cfg(test)]
mod dns_tests {
    use super::*;

    /// Build a minimal VpnSession suitable for exercising `dns_parse_response`.
    /// Only `dns_cache`, `bytes_*`, `last_seen`, counters are touched — none of
    /// the transport plumbing is needed.
    fn mock_session() -> VpnSession {
        let (close_tx, _close_rx) = tokio::sync::oneshot::channel();
        let effective_n = 1;
        let (tx, _rx) = mpsc::channel::<Bytes>(4);
        VpnSession::new_coordinator("deadbeef".to_string(), effective_n, vec![tx], close_tx)
    }

    /// Encode a QNAME from a dotted hostname, terminated with a zero label.
    fn encode_name(out: &mut Vec<u8>, host: &str) {
        for label in host.split('.') {
            out.push(label.len() as u8);
            out.extend_from_slice(label.as_bytes());
        }
        out.push(0);
    }

    /// Build a DNS response packet: single QD for `host`/A, plus `answers`
    /// (each with its own name encoding and IP). `answer_name` can be the raw
    /// name bytes (e.g. compressed pointer 0xC0 0x0C) to exercise compression.
    fn build_response(host: &str, answers: &[(Vec<u8>, [u8; 4])]) -> Vec<u8> {
        let mut pkt = Vec::with_capacity(64);
        // header: id=0x1234, flags=0x8180 (response, no error), qd=1, an=N, ns=0, ar=0
        pkt.extend_from_slice(&[0x12, 0x34, 0x81, 0x80]);
        pkt.extend_from_slice(&(1u16).to_be_bytes());
        pkt.extend_from_slice(&(answers.len() as u16).to_be_bytes());
        pkt.extend_from_slice(&[0, 0, 0, 0]);
        // question: name, type=A, class=IN
        encode_name(&mut pkt, host);
        pkt.extend_from_slice(&[0, 1, 0, 1]);
        // answers
        for (name_bytes, ip) in answers {
            pkt.extend_from_slice(name_bytes);
            pkt.extend_from_slice(&[0, 1]);       // type A
            pkt.extend_from_slice(&[0, 1]);       // class IN
            pkt.extend_from_slice(&[0, 0, 0, 60]); // ttl
            pkt.extend_from_slice(&(4u16).to_be_bytes()); // rdlen
            pkt.extend_from_slice(ip);
        }
        pkt
    }

    #[test]
    fn valid_a_record_populates_cache() {
        let session = mock_session();
        // Question QNAME starts at offset 12 → pointer 0xC0 0x0C.
        let mut answer_name = Vec::new();
        encode_name(&mut answer_name, "example.com");
        let pkt = build_response("example.com", &[(answer_name, [1, 2, 3, 4])]);

        dns_parse_response(&pkt, &session);

        let mut cache = session.dns_cache.lock().unwrap();
        let entry = cache.get(&Ipv4Addr::new(1, 2, 3, 4)).cloned();
        assert!(entry.is_some(), "cache should contain 1.2.3.4");
        assert_eq!(entry.unwrap().0, "example.com");
    }

    #[test]
    fn compressed_pointer_resolves_hostname() {
        let session = mock_session();
        // 0xC0 0x0C → pointer back to the question QNAME at offset 12.
        let answer_name = vec![0xC0, 0x0C];
        let pkt = build_response("example.com", &[(answer_name, [5, 6, 7, 8])]);

        dns_parse_response(&pkt, &session);

        let mut cache = session.dns_cache.lock().unwrap();
        let entry = cache.get(&Ipv4Addr::new(5, 6, 7, 8)).cloned();
        assert!(entry.is_some(), "cache should contain 5.6.7.8");
        assert_eq!(entry.unwrap().0, "example.com");
    }

    #[test]
    fn malicious_pointer_loop_does_not_panic() {
        // Hand-craft a packet where the question QNAME is a self-referential
        // compressed pointer (0xC0 0x0C at offset 12 → points to itself).
        // `dns_skip_name` must bail, and `dns_parse_response` must return
        // cleanly without panicking.
        let mut pkt = Vec::new();
        pkt.extend_from_slice(&[0x12, 0x34, 0x81, 0x80]); // header
        pkt.extend_from_slice(&(1u16).to_be_bytes());     // qd=1
        pkt.extend_from_slice(&(1u16).to_be_bytes());     // an=1
        pkt.extend_from_slice(&[0, 0, 0, 0]);
        // QNAME at offset 12: self-pointer
        pkt.extend_from_slice(&[0xC0, 0x0C]);
        pkt.extend_from_slice(&[0, 1, 0, 1]);             // type/class
        // Answer: name is also a valid pointer, but rdlen=0 to stress the
        // `pos - rdlen - 10` underflow bug that this fix removes.
        pkt.extend_from_slice(&[0xC0, 0x0C]);             // pointer into QNAME (loops)
        pkt.extend_from_slice(&[0, 1]);                   // type A
        pkt.extend_from_slice(&[0, 1]);                   // class
        pkt.extend_from_slice(&[0, 0, 0, 60]);            // ttl
        pkt.extend_from_slice(&(0u16).to_be_bytes());     // rdlen=0 (degenerate)

        let session = mock_session();
        // Must not panic.
        dns_parse_response(&pkt, &session);
    }

    #[test]
    fn multi_a_answers_both_cached() {
        let session = mock_session();
        let mut name_a = Vec::new();
        encode_name(&mut name_a, "multi.example.org");
        let name_b = vec![0xC0, 0x0C]; // second answer uses compression
        let pkt = build_response(
            "multi.example.org",
            &[(name_a, [9, 9, 9, 1]), (name_b, [9, 9, 9, 2])],
        );

        dns_parse_response(&pkt, &session);

        let mut cache = session.dns_cache.lock().unwrap();
        assert_eq!(
            cache.get(&Ipv4Addr::new(9, 9, 9, 1)).map(|(h, _)| h.clone()),
            Some("multi.example.org".to_string())
        );
        assert_eq!(
            cache.get(&Ipv4Addr::new(9, 9, 9, 2)).map(|(h, _)| h.clone()),
            Some("multi.example.org".to_string())
        );
    }
}
