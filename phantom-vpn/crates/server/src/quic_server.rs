//! QUIC server: accepts QUIC connections, performs Noise IK handshake per client,
//! forwards stream frames between QUIC streams and TUN interface.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Context;
use dashmap::DashMap;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    crypto::{KeyPair, NoiseHandshake, NoiseSession},
    mtu::clamp_tcp_mss,
    shaper::H264Shaper,
    wire::{build_batch_plaintext, extract_batch_packets, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
};

// ─── Session types ──────────────────────────────────────────────────────────

pub struct QuicSession {
    pub connection: quinn::Connection,
    pub noise:      NoiseSession,
    pub send_nonce: AtomicU64,
    pub data_send:  mpsc::Sender<Vec<u8>>,
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

/// Sessions keyed by tunnel IP address for efficient routing of return traffic.
pub type QuicSessionMap = Arc<DashMap<IpAddr, Arc<QuicSession>>>;

pub fn new_quic_session_map() -> QuicSessionMap {
    Arc::new(DashMap::new())
}

// ─── Accept loop ────────────────────────────────────────────────────────────

pub async fn run_accept_loop(
    endpoint:    quinn::Endpoint,
    tun_tx:      mpsc::Sender<Vec<u8>>,
    sessions:    QuicSessionMap,
    server_keys: Arc<KeyPair>,
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

        let tun_tx = tun_tx.clone();
        let sessions = sessions.clone();
        let server_keys = server_keys.clone();

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

            if let Err(e) = handle_connection(connection, tun_tx, sessions, server_keys, tun_network, tun_prefix).await {
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
    server_keys: Arc<KeyPair>,
    tun_network: Ipv4Addr,
    tun_prefix:  u8,
) -> anyhow::Result<()> {
    let remote = connection.remote_address();

    // 1. Accept control stream for Noise handshake
    let (mut send, mut recv) = connection
        .accept_bi()
        .await
        .context("Failed to accept control stream")?;

    // 2. Read Noise IK msg1: [4B length][payload]
    let mut len_buf = [0u8; 4];
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        recv.read_exact(&mut len_buf),
    )
    .await
    .context("Handshake init timeout")?
    .context("Failed to read handshake init length")?;

    let msg1_len = u32::from_be_bytes(len_buf) as usize;
    if msg1_len > 4096 {
        anyhow::bail!("Handshake init too large: {} bytes", msg1_len);
    }

    let mut msg1_buf = vec![0u8; msg1_len];
    recv.read_exact(&mut msg1_buf)
        .await
        .context("Failed to read handshake init")?;

    tracing::debug!("Received Noise IK init ({} bytes) from {}", msg1_len, remote);

    // 3. Noise IK respond
    let mut responder = NoiseHandshake::respond(&server_keys)
        .context("Noise respond init failed")?;
    responder
        .read_initiator_message(&msg1_buf)
        .context("Noise read_initiator_message failed")?;
    let response = responder
        .write_response()
        .context("Noise write_response failed")?;

    // 4. Send response: [4B length][payload]
    let resp_len_bytes = (response.len() as u32).to_be_bytes();
    send.write_all(&resp_len_bytes).await.context("Failed to send response length")?;
    send.write_all(&response).await.context("Failed to send response")?;
    let _ = send.finish();

    tracing::info!("Noise handshake completed with {}", remote);

    // 5. Transition to transport
    let noise_session = responder
        .into_transport()
        .context("Noise into_transport failed")?;

    // 6. Accept data stream (client opens it immediately after handshake)
    let (data_send, data_recv) = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        connection.accept_bi(),
    )
    .await
    .context("Data stream accept timeout")?
    .context("Failed to accept data stream")?;

    tracing::debug!("Data stream accepted from {}", remote);

    let shaper = H264Shaper::new().map_err(|e| anyhow::anyhow!("shaper: {}", e))?;

    // Pipeline: tun_to_quic_loop шлёт готовые фреймы в канал,
    // session_write_loop пишет их в QUIC stream независимо.
    let (frame_tx, frame_rx) = mpsc::channel::<Vec<u8>>(128);
    tokio::spawn(session_write_loop(frame_rx, data_send, remote));

    let session = Arc::new(QuicSession {
        connection: connection.clone(),
        noise:      noise_session,
        send_nonce: AtomicU64::new(0),
        data_send:  frame_tx,
        shaper:     Mutex::new(shaper),
        last_seen:  AtomicU64::new(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        ),
    });

    // 7. Run stream RX loop — register session once we know the client's tunnel IP
    let registered_ip: Arc<Mutex<Option<IpAddr>>> = Arc::new(Mutex::new(None));
    let reg_ip_clone = registered_ip.clone();
    let sessions_clone = sessions.clone();
    let rx_result = stream_rx_loop(
        data_recv,
        session.clone(),
        tun_tx,
        sessions.clone(),
        registered_ip.clone(),
        tun_network,
        tun_prefix,
        remote,
    )
    .await;

    // 8. Cleanup: unregister session on disconnect
    if let Some(ip) = reg_ip_clone.lock().await.take() {
        sessions_clone.remove(&ip);
        tracing::info!("Session unregistered for tunnel IP {} ({})", ip, remote);
    }

    if let Err(e) = rx_result {
        tracing::debug!("Stream RX loop ended for {}: {}", remote, e);
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
    let buf_size = BATCH_MAX_PLAINTEXT + 64;
    let mut ct_buf = vec![0u8; buf_size];
    let mut pt_buf = vec![0u8; buf_size];

    loop {
        // 1. Read frame header: [4B total_len]
        let mut len_buf = [0u8; 4];
        recv.read_exact(&mut len_buf)
            .await
            .map_err(|e| anyhow::anyhow!("stream closed: {}", e))?;
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len < 24 || frame_len > buf_size {
            return Err(anyhow::anyhow!("invalid frame_len={}", frame_len));
        }

        // 2. Read [8B nonce][ciphertext]
        recv.read_exact(&mut ct_buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream read frame: {}", e))?;

        let nonce = u64::from_be_bytes(ct_buf[..8].try_into().unwrap());
        let ciphertext = &ct_buf[8..frame_len];

        session.touch();

        // 3. Decrypt (NoiseSession methods take &self — no lock needed)
        let pt_len = match session.noise.decrypt(nonce, ciphertext, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::trace!("decrypt failed: {}", e);
                continue;
            }
        };

        // 4. Extract batch packets
        let packets = match extract_batch_packets(&pt_buf[..pt_len]) {
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

            // Register session by first IPv4 packet within the tunnel subnet
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
            continue; // only IPv4
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
    let buf_size = BATCH_MAX_PLAINTEXT + 64;
    let batch_limit = BATCH_MAX_PLAINTEXT - 16; // запас на AEAD tag
    let mut pt_buf = vec![0u8; buf_size];
    let mut ct_buf = vec![0u8; buf_size];

    tracing::info!("TUN→QUIC loop started");

    loop {
        // Wait for the first packet
        let first = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        // Route by destination IP
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

        // Drain all available packets for this destination — no coalescing timer
        let mut batch_data_bytes = 2 + first.len() + 2; // first pkt + terminator
        let mut packets: Vec<Vec<u8>> = vec![first];
        while packets.len() < 64 && batch_data_bytes + 2 + 1350 <= batch_limit {
            match pkt_rx.try_recv() {
                Ok(pkt) if pkt.len() >= 20 => {
                    let d = IpAddr::V4(Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]));
                    if d == dst_ip {
                        batch_data_bytes += 2 + pkt.len();
                        packets.push(pkt);
                    }
                }
                _ => break,
            }
        }

        let refs: Vec<&[u8]> = packets.iter().map(|p| p.as_slice()).collect();

        // При высоком трафике шейпер не нужен — padding только для idle
        let pt_len = match build_batch_plaintext(&refs, 0, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::trace!("build_batch error for {}: {}", dst_ip, e);
                continue;
            }
        };

        // Encrypt + write under single data_send lock to minimize contention
        let nonce = session.send_nonce.fetch_add(1, Ordering::Relaxed);
        let ct_len = match session.noise.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::trace!("encrypt error for {}: {}", dst_ip, e);
                continue;
            }
        };

        // Формируем фрейм и отправляем в write loop сессии (без блокирующего await на сети)
        let total_len = 8 + ct_len;
        let mut frame = vec![0u8; 4 + total_len];
        frame[..4].copy_from_slice(&(total_len as u32).to_be_bytes());
        frame[4..12].copy_from_slice(&nonce.to_be_bytes());
        frame[12..12 + ct_len].copy_from_slice(&ct_buf[..ct_len]);

        if session.data_send.send(frame).await.is_err() {
            tracing::warn!("session write channel closed for {}", dst_ip);
        }
    }

    Ok(())
}

// ─── Per-session write loop ──────────────────────────────────────────────────
//
// Получает готовые зашифрованные фреймы из канала и пишет в QUIC stream.
// Работает параллельно с tun_to_quic_loop: пока tun_to_quic шифрует батч N+1,
// этот loop отправляет батч N в сеть.

async fn session_write_loop(
    mut frame_rx: mpsc::Receiver<Vec<u8>>,
    mut send: quinn::SendStream,
    remote: SocketAddr,
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
