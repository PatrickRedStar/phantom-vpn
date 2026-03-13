//! QUIC server: accepts QUIC connections, performs Noise IK handshake per client,
//! forwards datagrams between QUIC connections and TUN interface.

use std::net::IpAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Context;
use dashmap::DashMap;
use tokio::io::AsyncReadExt;
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    crypto::{KeyPair, NoiseHandshake, NoiseSession},
    mtu::clamp_tcp_mss,
    session::{NonceCounter, ReplayWindow},
    wire::{build_plaintext, extract_ip_packet, NONCE_LEN, QUIC_TUNNEL_MSS},
};

// ─── Session types ──────────────────────────────────────────────────────────

pub struct QuicSession {
    pub connection: quinn::Connection,
    pub noise:      Mutex<NoiseSession>,
    pub send_nonce: Mutex<NonceCounter>,
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

/// Main QUIC accept loop: waits for incoming connections and spawns a handler per client.
pub async fn run_accept_loop(
    endpoint:    quinn::Endpoint,
    tun_tx:      mpsc::Sender<Vec<u8>>,
    sessions:    QuicSessionMap,
    server_keys: Arc<KeyPair>,
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

            if let Err(e) = handle_connection(connection, tun_tx, sessions, server_keys).await {
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

    let session = Arc::new(QuicSession {
        connection: connection.clone(),
        noise:      Mutex::new(noise_session),
        send_nonce: Mutex::new(NonceCounter::new()),
        last_seen:  AtomicU64::new(
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
        ),
    });

    // 6. Run datagram RX loop — register session once we know the client's tunnel IP
    let registered_ip: Arc<Mutex<Option<IpAddr>>> = Arc::new(Mutex::new(None));
    let reg_ip_clone = registered_ip.clone();
    let sessions_clone = sessions.clone();
    let rx_result = datagram_rx_loop(
        connection.clone(),
        session.clone(),
        tun_tx,
        sessions.clone(),
        registered_ip.clone(),
    )
    .await;

    // 7. Cleanup: unregister session on disconnect
    if let Some(ip) = reg_ip_clone.lock().await.take() {
        sessions_clone.remove(&ip);
        tracing::info!("Session unregistered for tunnel IP {} ({})", ip, remote);
    }

    if let Err(e) = rx_result {
        tracing::debug!("Datagram RX loop ended for {}: {}", remote, e);
    }

    Ok(())
}

// ─── Datagram RX loop (per connection) ──────────────────────────────────────

async fn datagram_rx_loop(
    connection:    quinn::Connection,
    session:       Arc<QuicSession>,
    tun_tx:        mpsc::Sender<Vec<u8>>,
    sessions:      QuicSessionMap,
    registered_ip: Arc<Mutex<Option<IpAddr>>>,
) -> anyhow::Result<()> {
    let mut decrypt_buf = vec![0u8; 65536];
    let mut replay_win = ReplayWindow::new();

    loop {
        let datagram = match connection.read_datagram().await {
            Ok(d) => d,
            Err(e) => return Err(e.into()),
        };

        if datagram.len() < NONCE_LEN {
            continue;
        }

        // Extract nonce
        let nonce = u64::from_be_bytes(datagram[..NONCE_LEN].try_into().unwrap());
        let ciphertext = &datagram[NONCE_LEN..];

        // Replay check
        if let Err(_) = replay_win.check_and_update(nonce) {
            continue;
        }

        session.touch();

        // Decrypt
        let pt_len = {
            let mut noise = session.noise.lock().await;
            match noise.decrypt(nonce, ciphertext, &mut decrypt_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("decrypt failed: {}", e);
                    continue;
                }
            }
        };

        // Extract IP packet
        let ip_data = match extract_ip_packet(&decrypt_buf[..pt_len]) {
            Ok(d) => d.to_vec(),
            Err(e) => {
                tracing::trace!("extract_ip failed: {}", e);
                continue;
            }
        };

        // Register session by source IP from the first packet
        if registered_ip.lock().await.is_none() {
            if ip_data.len() >= 20 {
                let src_ip = IpAddr::V4(std::net::Ipv4Addr::new(
                    ip_data[12], ip_data[13], ip_data[14], ip_data[15],
                ));
                sessions.insert(src_ip, session.clone());
                *registered_ip.lock().await = Some(src_ip);
                tracing::info!(
                    "Session registered for tunnel IP {} ({})",
                    src_ip,
                    connection.remote_address()
                );
            }
        }

        // MSS clamping
        let mut ip_buf = ip_data;
        let _ = clamp_tcp_mss(&mut ip_buf, QUIC_TUNNEL_MSS);

        // Send to TUN
        if let Err(e) = tun_tx.send(ip_buf).await {
            tracing::error!("tun_tx send error: {}", e);
        }
    }
}

// ─── TUN → QUIC: route packets to correct client ───────────────────────────

pub async fn tun_to_quic_loop(
    mut tun_reader: tokio::io::ReadHalf<crate::tun_iface::AsyncTun>,
    sessions:       QuicSessionMap,
) -> anyhow::Result<()> {
    let mut tun_buf = vec![0u8; 65536];
    let mut pt_buf = vec![0u8; 65536];
    let mut ct_buf = vec![0u8; 65536];

    tracing::info!("TUN→QUIC loop started");

    loop {
        let len = match tun_reader.read(&mut tun_buf).await {
            Ok(0) => continue,
            Ok(n) => n,
            Err(e) => {
                tracing::error!("TUN read error: {}", e);
                tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                continue;
            }
        };

        let ip_pkt = &tun_buf[..len];

        // Extract destination IP from IPv4 header
        if len < 20 {
            continue;
        }

        let dst_ip = IpAddr::V4(std::net::Ipv4Addr::new(
            ip_pkt[16], ip_pkt[17], ip_pkt[18], ip_pkt[19],
        ));

        // Look up session by destination IP
        let session = match sessions.get(&dst_ip) {
            Some(entry) => entry.value().clone(),
            None => {
                tracing::trace!("No session for dst IP {}", dst_ip);
                continue;
            }
        };

        // Build plaintext with padding
        let target = (ip_pkt.len() + 50).max(200);
        let pt_len = match build_plaintext(ip_pkt, target, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::trace!("build_plaintext error: {}", e);
                continue;
            }
        };

        // Encrypt
        let nonce = {
            let mut send_nonce = session.send_nonce.lock().await;
            send_nonce.next_u64()
        };
        let ct_len = {
            let mut noise = session.noise.lock().await;
            match noise.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("encrypt error for {}: {}", dst_ip, e);
                    continue;
                }
            }
        };

        // Build datagram: [8B nonce][ciphertext]
        let mut datagram = Vec::with_capacity(NONCE_LEN + ct_len);
        datagram.extend_from_slice(&nonce.to_be_bytes());
        datagram.extend_from_slice(&ct_buf[..ct_len]);

        if let Err(e) = session.connection.send_datagram(datagram.into()) {
            tracing::warn!("QUIC send_datagram to {} failed: {}", dst_ip, e);
        }
    }
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
