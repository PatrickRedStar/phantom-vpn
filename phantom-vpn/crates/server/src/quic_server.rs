//! QUIC server: accepts connections, forwards stream frames between QUIC streams and TUN.
//! Authentication is handled by mTLS at the TLS layer.
//! Wire format per stream frame: [4B total_len][batch plaintext]

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::Context;
use dashmap::DashMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    mtu::clamp_tcp_mss,
    shaper::H264Shaper,
    wire::{build_batch_plaintext, extract_batch_packets, flow_stream_idx, BATCH_MAX_PLAINTEXT, N_DATA_STREAMS, QUIC_TUNNEL_MSS},
};

// ─── Session types ──────────────────────────────────────────────────────────

pub struct QuicSession {
    pub connection: quinn::Connection,
    pub data_sends: Vec<mpsc::Sender<Vec<u8>>>,
    pub shaper:     Mutex<H264Shaper>,
    pub last_seen:  AtomicU64,
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

// ─── Accept loop ────────────────────────────────────────────────────────────

pub async fn run_accept_loop(
    endpoint: quinn::Endpoint,
    tun_tx:   mpsc::Sender<Vec<u8>>,
    sessions: QuicSessionMap,
    tun_network: Ipv4Addr,
    tun_prefix:  u8,
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

            if let Err(e) = handle_connection(connection, tun_tx, sessions, tun_network, tun_prefix).await {
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
) -> anyhow::Result<()> {
    let remote = connection.remote_address();

    // Log mTLS identity if client presented a certificate
    if let Some(identity) = connection.peer_identity() {
        if let Some(certs) = identity.downcast_ref::<Vec<rustls::pki_types::CertificateDer>>() {
            tracing::debug!("Client {} presented {} TLS cert(s)", remote, certs.len());
        }
    }

    let shaper = H264Shaper::new().map_err(|e| anyhow::anyhow!("shaper: {}", e))?;

    // Accept N_DATA_STREAMS bidirectional data streams; spawn per-stream write loops
    let mut frame_txs:  Vec<mpsc::Sender<Vec<u8>>> = Vec::with_capacity(N_DATA_STREAMS);
    let mut data_recvs: Vec<quinn::RecvStream>      = Vec::with_capacity(N_DATA_STREAMS);

    for i in 0..N_DATA_STREAMS {
        let (ds, dr) = tokio::time::timeout(
            std::time::Duration::from_secs(10),
            connection.accept_bi(),
        )
        .await
        .with_context(|| format!("Data stream {} accept timeout", i))?
        .with_context(|| format!("Failed to accept data stream {}", i))?;

        let (frame_tx, frame_rx) = mpsc::channel::<Vec<u8>>(128);
        tokio::spawn(session_write_loop(frame_rx, ds, remote));
        frame_txs.push(frame_tx);
        data_recvs.push(dr);
    }

    tracing::debug!("{} data streams accepted from {}", N_DATA_STREAMS, remote);

    let session = Arc::new(QuicSession {
        connection: connection.clone(),
        data_sends: frame_txs,
        shaper:     Mutex::new(shaper),
        last_seen:  AtomicU64::new(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        ),
    });

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

    // Cleanup
    if let Some(ip) = reg_ip_clone.lock().await.take() {
        sessions_clone.remove(&ip);
        tracing::info!("Session unregistered for tunnel IP {} ({})", ip, remote);
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

        session.touch();

        // 3. Extract batch packets
        let packets = match extract_batch_packets(&frame_buf[..frame_len]) {
            Ok(pkts) => pkts,
            Err(e) => {
                tracing::trace!("extract_batch failed: {}", e);
                continue;
            }
        };

        for ip_data in packets {
            if ip_data.len() < 20 {
                continue;
            }

            // Register session by first IPv4 packet within tunnel subnet
            if registered_ip.lock().await.is_none() && (ip_data[0] >> 4) == 4 {
                let src_v4 = Ipv4Addr::new(
                    ip_data[12], ip_data[13], ip_data[14], ip_data[15],
                );
                let mask: u32 = if tun_prefix == 0 { 0 } else { !0u32 << (32 - tun_prefix) };
                if u32::from(src_v4) & mask == u32::from(tun_network) & mask {
                    let src_ip = IpAddr::V4(src_v4);
                    sessions.insert(src_ip, session.clone());
                    *registered_ip.lock().await = Some(src_ip);
                    tracing::info!(
                        "Session registered for tunnel IP {} ({})",
                        src_ip, remote
                    );
                } else {
                    tracing::debug!(
                        "Skipping session registration: src {} not in tunnel subnet {}/{}",
                        src_v4, tun_network, tun_prefix
                    );
                }
            }

            let mut ip_buf = ip_data;
            let _ = clamp_tcp_mss(&mut ip_buf, QUIC_TUNNEL_MSS);

            if let Err(e) = tun_tx.send(ip_buf).await {
                tracing::error!("tun_tx send error: {}", e);
            }
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

// ─── TUN → QUIC stream: batch routing per client ────────────────────────────

pub async fn tun_to_quic_loop(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    sessions:   QuicSessionMap,
) -> anyhow::Result<()> {
    let buf_size  = BATCH_MAX_PLAINTEXT + 16;
    let batch_limit = BATCH_MAX_PLAINTEXT - 16;
    let mut pt_buf = vec![0u8; buf_size];

    tracing::info!("TUN→QUIC loop started");

    loop {
        let first = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        let dst_ip = IpAddr::V4(Ipv4Addr::new(
            first[16], first[17], first[18], first[19],
        ));

        let session = match sessions.get(&dst_ip) {
            Some(entry) => entry.value().clone(),
            None => {
                tracing::trace!("No session for dst IP {}", dst_ip);
                continue;
            }
        };

        let n_streams = session.data_sends.len();

        // Per-stream batch collection: each TCP flow always goes to the same stream
        let mut stream_batches: Vec<Vec<Vec<u8>>> = vec![Vec::new(); n_streams];
        let first_idx = flow_stream_idx(&first, n_streams);
        stream_batches[first_idx].push(first);

        let mut collected = 1usize;
        while collected < 64 {
            match pkt_rx.try_recv() {
                Ok(pkt) if pkt.len() >= 20 => {
                    let d = IpAddr::V4(Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]));
                    if d == dst_ip {
                        let idx = flow_stream_idx(&pkt, n_streams);
                        stream_batches[idx].push(pkt);
                        collected += 1;
                    }
                }
                _ => break,
            }
        }

        // Build and send each per-stream batch
        for (idx, packets) in stream_batches.iter().enumerate() {
            if packets.is_empty() {
                continue;
            }

            let refs: Vec<&[u8]> = packets.iter().map(|p| p.as_slice()).collect();
            let pt_len = match build_batch_plaintext(&refs, 0, &mut pt_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("build_batch error stream {}: {}", idx, e);
                    continue;
                }
            };

            // Frame: [4B pt_len][plaintext batch]
            let mut frame = vec![0u8; 4 + pt_len];
            frame[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
            frame[4..].copy_from_slice(&pt_buf[..pt_len]);

            // Suppress unused variable warning
            let _ = batch_limit;

            if session.data_sends[idx].send(frame).await.is_err() {
                tracing::warn!("session write channel closed for stream {}", idx);
            }
        }
    }

    Ok(())
}

// ─── Per-session write loop ──────────────────────────────────────────────────

async fn session_write_loop(
    mut frame_rx: mpsc::Receiver<Vec<u8>>,
    mut send:     quinn::SendStream,
    remote:       SocketAddr,
) {
    while let Some(frame) = frame_rx.recv().await {
        if let Err(e) = send.write_all(&frame).await {
            tracing::warn!("session write to {} failed: {}", remote, e);
            break;
        }
    }
    tracing::debug!("session write loop ended for {}", remote);
}

// ─── Cleanup task ───────────────────────────────────────────────────────────

pub async fn cleanup_task(sessions: QuicSessionMap, idle_secs: u64) {
    let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(60));
    loop {
        interval.tick().await;

        let mut to_remove = Vec::new();
        for entry in sessions.iter() {
            if entry.value().is_idle(idle_secs) {
                to_remove.push(*entry.key());
            }
        }
        for ip in &to_remove {
            if let Some((_, session)) = sessions.remove(ip) {
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
