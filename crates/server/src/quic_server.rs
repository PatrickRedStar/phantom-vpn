//! QUIC server: accepts connections, forwards stream frames between QUIC streams and TUN.
//! Authentication is handled by mTLS at the TLS layer.
//! Wire format per stream frame: [4B total_len][batch plaintext]

use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::path::Path;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::Context;
use bytes::Bytes;
use dashmap::DashMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, Mutex, RwLock};

use phantom_core::{
    mtu::clamp_tcp_mss,
    shaper::H264Shaper,
    wire::{build_batch_plaintext, flow_stream_idx, BATCH_MAX_PLAINTEXT, N_DATA_STREAMS, QUIC_TUNNEL_MSS},
};

// ─── Session types ──────────────────────────────────────────────────────────

/// One logged destination visit (client → server direction).
#[derive(Clone)]
pub struct DestEntry {
    pub ts:       u64,
    pub dst_ip:   std::net::Ipv4Addr,
    pub dst_host: Option<String>,  // resolved hostname from passive DNS cache
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

pub struct QuicSession {
    pub connection:    quinn::Connection,
    pub data_sends:    Vec<mpsc::Sender<Bytes>>,
    /// Per-session channel for TUN→QUIC packets (fed by tun_dispatch_loop)
    pub tun_pkt_tx:    mpsc::Sender<Vec<u8>>,
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

impl QuicSession {
    pub fn touch(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.last_seen.store(now, Ordering::Relaxed);
    }

    pub fn is_idle(&self, idle_secs: u64) -> bool {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        now.saturating_sub(self.last_seen.load(Ordering::Relaxed)) > idle_secs
    }
}

pub type QuicSessionMap = Arc<DashMap<IpAddr, Arc<QuicSession>>>;

pub fn new_quic_session_map() -> QuicSessionMap {
    Arc::new(DashMap::new())
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
/// Expected format: {"clients": {"name": {"fingerprint": "abcd1234..."}, ...}}
pub fn load_allow_list(path: &Path) -> anyhow::Result<HashSet<String>> {
    let content = std::fs::read_to_string(path)
        .with_context(|| format!("Failed to read {}", path.display()))?;
    let val: serde_json::Value = serde_json::from_str(&content)
        .with_context(|| format!("Failed to parse {}", path.display()))?;

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
fn cert_fingerprint(cert_der: &[u8]) -> String {
    use sha2::{Sha256, Digest};
    let hash = Sha256::digest(cert_der);
    hash.iter().map(|b| format!("{:02x}", b)).collect()
}

// ─── Accept loop ────────────────────────────────────────────────────────────

pub async fn run_accept_loop(
    endpoint: quinn::Endpoint,
    tun_tx:   mpsc::Sender<Vec<u8>>,
    sessions: QuicSessionMap,
    tun_network: Ipv4Addr,
    tun_prefix:  u8,
    allow_list:  ClientAllowList,
) -> anyhow::Result<()> {
    tracing::info!("QUIC accept loop started");

    loop {
        let incoming = match endpoint.accept().await {
            Some(inc) => inc,
            None => {
                tracing::warn!("QUIC endpoint closed");
                break;
            }
        };

        let tun_tx   = tun_tx.clone();
        let sessions = sessions.clone();
        let allow_list = allow_list.clone();

        tokio::spawn(async move {
            let remote = incoming.remote_address();
            tracing::info!("Incoming QUIC connection from {}", remote);

            let connection = match incoming.await {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!("QUIC accept failed from {}: {}", remote, e);
                    return;
                }
            };

            if let Err(e) = handle_connection(connection, tun_tx, sessions, tun_network, tun_prefix, allow_list).await {
                tracing::warn!("Connection handler error from {}: {}", remote, e);
            }
        });
    }

    Ok(())
}

// ─── Per-connection handler ─────────────────────────────────────────────────

async fn handle_connection(
    connection:  quinn::Connection,
    tun_tx:      mpsc::Sender<Vec<u8>>,
    sessions:    QuicSessionMap,
    tun_network: Ipv4Addr,
    tun_prefix:  u8,
    allow_list:  ClientAllowList,
) -> anyhow::Result<()> {
    let remote = connection.remote_address();

    // ─── REALITY-style: check if client presented a valid mTLS cert ──────
    let peer_certs = connection.peer_identity()
        .and_then(|id| id.downcast_ref::<Vec<rustls::pki_types::CertificateDer>>().cloned())
        .unwrap_or_default();

    if peer_certs.is_empty() {
        tracing::info!("Unauthenticated connection from {} → fallback mode", remote);
        handle_fallback(connection, remote).await;
        return Ok(());
    }

    // ─── Fingerprint allowlist check ─────────────────────────────────────
    let client_fp = cert_fingerprint(peer_certs[0].as_ref());
    {
        let allowed = allow_list.read().await;
        if !allowed.is_empty() && !allowed.contains(&client_fp) {
            tracing::warn!(
                "Client {} rejected: fingerprint {}… not in allowlist",
                remote, &client_fp[..16]
            );
            connection.close(0u32.into(), b"not authorized");
            return Ok(());
        }
    }

    tracing::info!("Authenticated VPN client from {} (fp={}…)", remote, &client_fp[..16]);

    let shaper = H264Shaper::new().map_err(|e| anyhow::anyhow!("shaper: {}", e))?;

    // Accept N_DATA_STREAMS bidirectional data streams; spawn per-stream write loops
    let mut frame_txs:  Vec<mpsc::Sender<Bytes>> = Vec::with_capacity(N_DATA_STREAMS);
    let mut data_recvs: Vec<quinn::RecvStream>   = Vec::with_capacity(N_DATA_STREAMS);

    for i in 0..N_DATA_STREAMS {
        let (ds, dr) = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            connection.accept_bi(),
        )
        .await
        .with_context(|| format!("Data stream {} accept timeout", i))?
        .with_context(|| format!("Failed to accept data stream {}", i))?;

        let (frame_tx, frame_rx) = mpsc::channel::<Bytes>(512);
        tokio::spawn(session_write_loop(frame_rx, ds, remote));
        frame_txs.push(frame_tx);
        data_recvs.push(dr);
    }

    tracing::debug!("{} data streams accepted from {}", N_DATA_STREAMS, remote);

    // Per-session TUN packet channel + batching task
    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(2048);

    let session = Arc::new(QuicSession {
        connection:    connection.clone(),
        data_sends:    frame_txs,
        tun_pkt_tx,
        last_seen:     AtomicU64::new(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        ),
        bytes_rx:      AtomicU64::new(0),
        bytes_tx:      AtomicU64::new(0),
        dest_log:      std::sync::Mutex::new(std::collections::VecDeque::new()),
        stats_samples: std::sync::Mutex::new(std::collections::VecDeque::new()),
        dns_cache:     DashMap::new(),
        log_counter:   AtomicU64::new(0),
    });

    // Spawn per-session batching task (TUN packets → QUIC streams)
    tokio::spawn(session_batch_loop(tun_pkt_rx, session.clone(), shaper));

    // Run N stream RX loops
    let registered_ip: Arc<Mutex<Option<IpAddr>>> = Arc::new(Mutex::new(None));
    let reg_ip_clone  = registered_ip.clone();
    let sessions_clone = sessions.clone();

    let mut set = tokio::task::JoinSet::new();
    for data_recv in data_recvs {
        set.spawn(stream_rx_loop(
            data_recv,
            session.clone(),
            tun_tx.clone(),
            sessions.clone(),
            registered_ip.clone(),
            tun_network,
            tun_prefix,
            remote,
        ));
    }

    while set.join_next().await.is_some() {}

    // Cleanup — only remove if our session is still the one in the map.
    // A newer connection may have replaced our entry with a different Arc.
    if let Some(ip) = reg_ip_clone.lock().await.take() {
        if sessions_clone.remove_if(&ip, |_, v| Arc::ptr_eq(v, &session)).is_some() {
            tracing::info!("Session unregistered for tunnel IP {} ({})", ip, remote);
        } else {
            tracing::debug!("Session for {} ({}) already replaced, skip remove", ip, remote);
        }
    }

    Ok(())
}

// ─── Stream RX loop (client → server) ───────────────────────────────────────

async fn stream_rx_loop(
    mut recv:      quinn::RecvStream,
    session:       Arc<QuicSession>,
    tun_tx:        mpsc::Sender<Vec<u8>>,
    sessions:      QuicSessionMap,
    registered_ip: Arc<Mutex<Option<IpAddr>>>,
    tun_network:   Ipv4Addr,
    tun_prefix:    u8,
    remote:        SocketAddr,
) -> anyhow::Result<()> {
    let buf_size = BATCH_MAX_PLAINTEXT + 16;
    let mut frame_buf = vec![0u8; buf_size];

    loop {
        // 1. Read frame header: [4B total_len]
        let mut len_buf = [0u8; 4];
        recv.read_exact(&mut len_buf)
            .await
            .map_err(|e| anyhow::anyhow!("stream closed: {}", e))?;
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len < 4 || frame_len > buf_size {
            return Err(anyhow::anyhow!("invalid frame_len={}", frame_len));
        }

        // 2. Read plaintext batch
        recv.read_exact(&mut frame_buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream read frame: {}", e))?;

        session.bytes_rx.fetch_add((4 + frame_len) as u64, Ordering::Relaxed);
        session.touch();

        // 3. Walk batch in-place — no intermediate Vec<Vec<u8>>
        let mut offset = 0;
        let mut registered = registered_ip.lock().await.is_some();
        loop {
            if offset + 2 > frame_len { break; }
            let pkt_len = u16::from_be_bytes([
                frame_buf[offset], frame_buf[offset + 1],
            ]) as usize;
            offset += 2;
            if pkt_len == 0 { break; }
            if offset + pkt_len > frame_len { break; }
            if pkt_len < 20 { offset += pkt_len; continue; }

            // Register session on first IPv4 packet (single lock, not per-packet)
            if !registered && (frame_buf[offset] >> 4) == 4 {
                let src_v4 = Ipv4Addr::new(
                    frame_buf[offset + 12], frame_buf[offset + 13],
                    frame_buf[offset + 14], frame_buf[offset + 15],
                );
                let mask: u32 = if tun_prefix == 0 { 0 } else { !0u32 << (32 - tun_prefix) };
                if u32::from(src_v4) & mask == u32::from(tun_network) & mask {
                    let src_ip = IpAddr::V4(src_v4);
                    sessions.insert(src_ip, session.clone());
                    *registered_ip.lock().await = Some(src_ip);
                    registered = true;
                    tracing::info!("Session registered for tunnel IP {} ({})", src_ip, remote);
                }
            }

            let _ = clamp_tcp_mss(&mut frame_buf[offset..offset + pkt_len], QUIC_TUNNEL_MSS);

            // Log destination IP/port — sampled every 64th packet to avoid mutex contention
            if pkt_len >= 20 && (frame_buf[offset] >> 4) == 4
                && session.log_counter.fetch_add(1, Ordering::Relaxed) % 64 == 0
            {
                let proto = frame_buf[offset + 9];
                let dst_ip = std::net::Ipv4Addr::new(
                    frame_buf[offset + 16], frame_buf[offset + 17],
                    frame_buf[offset + 18], frame_buf[offset + 19],
                );
                let ihl = ((frame_buf[offset] & 0x0F) as usize) * 4;
                let dst_port = if (proto == 6 || proto == 17) && ihl + 4 <= pkt_len {
                    u16::from_be_bytes([frame_buf[offset + ihl + 2], frame_buf[offset + ihl + 3]])
                } else {
                    0
                };
                let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
                let dst_host = session.dns_cache.get(&dst_ip).map(|v| v.clone());
                if let Ok(mut log) = session.dest_log.lock() {
                    if log.len() >= 1000 { log.pop_front(); }
                    log.push_back(DestEntry { ts, dst_ip, dst_host, dst_port, proto, bytes: pkt_len as u32 });
                }
            }

            if let Err(e) = tun_tx.send(frame_buf[offset..offset + pkt_len].to_vec()).await {
                tracing::error!("tun_tx send error: {}", e);
            }
            offset += pkt_len;
        }
    }
}

// ─── TUN reader: file → channel ─────────────────────────────────────────────

pub async fn tun_reader_loop(
    mut tun_reader: tokio::io::ReadHalf<crate::tun_iface::AsyncTun>,
    pkt_tx:         mpsc::Sender<Vec<u8>>,
) {
    let mut buf = vec![0u8; 65536];
    tracing::info!("TUN reader loop started");
    loop {
        let len = match tun_reader.read(&mut buf).await {
            Ok(0) | Err(_) => continue,
            Ok(n) => n,
        };
        if len < 20 || (buf[0] >> 4) != 4 {
            continue;
        }
        if pkt_tx.send(buf[..len].to_vec()).await.is_err() {
            break;
        }
    }
}

// ─── TUN → per-session dispatch (lightweight) ───────────────────────────────

pub async fn tun_dispatch_loop(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    sessions:   QuicSessionMap,
) -> anyhow::Result<()> {
    tracing::info!("TUN→QUIC dispatch loop started");

    loop {
        let pkt = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        if pkt.len() < 20 { continue; }

        let dst = IpAddr::V4(Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]));

        if let Some(session) = sessions.get(&dst) {
            // Intercept DNS responses (src_port=53) for passive hostname cache
            if pkt.len() >= 28 && pkt[9] == 17 {
                let ihl = ((pkt[0] & 0x0F) as usize) * 4;
                if ihl + 8 <= pkt.len() {
                    let src_port = u16::from_be_bytes([pkt[ihl], pkt[ihl + 1]]);
                    if src_port == 53 {
                        dns_parse_response(&pkt[ihl + 8..], session.value());
                    }
                }
            }

            // Non-blocking send to per-session channel; drop packet if channel full
            let _ = session.value().tun_pkt_tx.try_send(pkt);
        }
    }

    Ok(())
}

// ─── Per-session batching: TUN packets → QUIC streams ───────────────────────

async fn session_batch_loop(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    session:    Arc<QuicSession>,
    mut shaper: H264Shaper,
) {
    let buf_size = 4 + BATCH_MAX_PLAINTEXT + 16;
    let mut frame_buf = vec![0u8; buf_size];
    let n_streams = session.data_sends.len();

    loop {
        let first = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        // Collect packets into per-stream batches
        let mut stream_batches: Vec<Vec<Vec<u8>>> = (0..n_streams).map(|_| Vec::new()).collect();

        // Route first packet
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
            let data_size: usize = refs.iter().map(|p| 2 + p.len()).sum::<usize>() + 2;
            let frame = shaper.next_frame();
            shaper.report_data_size(data_size, frame.target_bytes);
            let pt_len = match build_batch_plaintext(&refs, frame.target_bytes, &mut frame_buf[4..]) {
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

// ─── Per-session write loop ──────────────────────────────────────────────────

async fn session_write_loop(
    mut frame_rx: mpsc::Receiver<Bytes>,
    mut send:     quinn::SendStream,
    remote:       SocketAddr,
) {
    while let Some(frame) = frame_rx.recv().await {
        // write_chunk takes ownership of Bytes — zero-copy into quinn send buffer
        if let Err(e) = send.write_chunk(frame).await {
            tracing::warn!("session write to {} failed: {}", remote, e);
            break;
        }
    }
    tracing::debug!("session write loop ended for {}", remote);
}

// ─── REALITY fallback: serve fake HTTP/3 page to unauthenticated clients ────

async fn handle_fallback(connection: quinn::Connection, remote: SocketAddr) {
    // Accept bidirectional streams (like a browser would open for HTTP/3)
    // and respond with a minimal valid response. This makes the server
    // indistinguishable from a real HTTP/3 website to DPI probes.
    loop {
        let stream = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            connection.accept_bi(),
        ).await;

        match stream {
            Ok(Ok((mut send, mut recv))) => {
                tokio::spawn(async move {
                    // Read and discard request data (HTTP/3 frames from the "browser")
                    let mut buf = vec![0u8; 4096];
                    let _ = tokio::time::timeout(
                        std::time::Duration::from_secs(5),
                        recv.read(&mut buf),
                    ).await;

                    // Send a minimal HTTP/3-like response.
                    // Real H3 uses QPACK headers + DATA frames, but for DPI evasion
                    // we just need to send SOMETHING on the stream and close it.
                    // Most DPI only checks that the QUIC connection + TLS succeeds,
                    // not that the H3 framing is perfect.
                    let response = b"<html><body><h1>nl2.bikini-bottom.com</h1><p>Service is running.</p></body></html>";
                    let _ = send.write_all(response).await;
                    let _ = send.finish();

                    tracing::debug!("Fallback: served fake page to probe");
                });
            }
            Ok(Err(_)) | Err(_) => {
                // Connection closed or timeout — probe is done
                break;
            }
        }
    }
    tracing::debug!("Fallback connection from {} ended", remote);
}

// ─── Cleanup task ───────────────────────────────────────────────────────────

pub async fn cleanup_task(sessions: QuicSessionMap, idle_secs: u64) {
    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
    loop {
        interval.tick().await;

        let mut to_remove = Vec::new();
        let now_ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
        for entry in sessions.iter() {
            if entry.value().is_idle(idle_secs) {
                to_remove.push(*entry.key());
            } else {
                // Snapshot traffic counters for time-series
                let bytes_rx = entry.value().bytes_rx.load(Ordering::Relaxed);
                let bytes_tx = entry.value().bytes_tx.load(Ordering::Relaxed);
                if let Ok(mut samples) = entry.value().stats_samples.lock() {
                    if samples.len() >= 60 { samples.pop_front(); }
                    samples.push_back(StatsSample { ts: now_ts, bytes_rx, bytes_tx });
                }
            }
        }
        for ip in &to_remove {
            // Re-check is_idle at removal time — a new session may have registered
            if let Some((_, session)) = sessions.remove_if(ip, |_, v| v.is_idle(idle_secs)) {
                session.connection.close(0u32.into(), b"idle timeout");
                tracing::info!("Session expired (idle): tunnel IP {}", ip);
            }
        }
        if !to_remove.is_empty() {
            tracing::info!(
                "Cleanup: removed {} sessions, {} active",
                to_remove.len(),
                sessions.len()
            );
        }
    }
}

// ─── Passive DNS cache helpers ────────────────────────────────────────────────

/// Parse a DNS response packet and insert any A-record mappings into the session's dns_cache.
/// Called for UDP packets with src_port == 53 in tun_dispatch_loop.
fn dns_parse_response(data: &[u8], session: &QuicSession) {
    if data.len() < 12 { return; }
    // Flags: QR=1 (response), RCODE=0 (no error)
    let flags = u16::from_be_bytes([data[2], data[3]]);
    if flags & 0x8000 == 0 || flags & 0x000F != 0 { return; }

    let qdcount = u16::from_be_bytes([data[4], data[5]]) as usize;
    let ancount = u16::from_be_bytes([data[6], data[7]]) as usize;
    if ancount == 0 { return; }

    let mut pos = 12;

    // Skip question section
    for _ in 0..qdcount {
        if !dns_skip_name(data, &mut pos) { return; }
        pos += 4; // QTYPE + QCLASS
    }

    // Parse answer section — lock-free DashMap, no mutex needed
    // Limit cache size to avoid unbounded growth
    if session.dns_cache.len() > 4096 { session.dns_cache.clear(); }

    for _ in 0..ancount {
        let name_start = pos;
        if !dns_skip_name(data, &mut pos) { return; }
        let _ = name_start;

        if pos + 10 > data.len() { return; }
        let rtype  = u16::from_be_bytes([data[pos],     data[pos + 1]]);
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

/// Skip over a DNS name (handles pointer compression). Returns false on error.
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

/// Read a DNS name (handles pointer compression). Returns None on error.
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
