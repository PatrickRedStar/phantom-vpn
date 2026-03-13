//! QUIC tunnel loops: TUN ↔ QUIC datagrams (Noise encrypted).
//! Replaces the UDP+SRTP tunnel with QUIC datagrams for DPI evasion.

use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    crypto::NoiseSession,
    session::{NonceCounter, ReplayWindow},
    wire::{build_plaintext, extract_ip_packet, NONCE_LEN, QUIC_TUNNEL_MSS},
    mtu::clamp_tcp_mss,
};

const BUF: usize = 65536;

// ─── QUIC RX: server → decrypt → TUN ────────────────────────────────────────

pub async fn quic_rx_loop(
    connection: quinn::Connection,
    noise:      Arc<Mutex<NoiseSession>>,
    tun_tx:     mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    let mut decrypt_buf = vec![0u8; BUF];
    let mut replay_win = ReplayWindow::new();

    tracing::info!("QUIC RX loop started");

    loop {
        let datagram = match connection.read_datagram().await {
            Ok(d) => d,
            Err(e) => {
                tracing::error!("QUIC connection closed: {}", e);
                return Err(e.into());
            }
        };

        if datagram.len() < NONCE_LEN {
            tracing::trace!("drop: datagram too short ({} bytes)", datagram.len());
            continue;
        }

        // Extract nonce (first 8 bytes)
        let nonce = u64::from_be_bytes(datagram[..NONCE_LEN].try_into().unwrap());
        let ciphertext = &datagram[NONCE_LEN..];

        // Replay protection
        if let Err(e) = replay_win.check_and_update(nonce) {
            tracing::trace!("replay drop: {}", e);
            continue;
        }

        // Decrypt
        let pt_len = {
            let mut session = noise.lock().await;
            match session.decrypt(nonce, ciphertext, &mut decrypt_buf) {
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

        // MSS clamping
        let mut ip_buf = ip_data;
        let _ = clamp_tcp_mss(&mut ip_buf, QUIC_TUNNEL_MSS);

        // Send to TUN
        if let Err(e) = tun_tx.send(ip_buf).await {
            tracing::error!("tun_tx send error: {}", e);
        }
    }
}

// ─── TUN → QUIC: TUN → encrypt → server ─────────────────────────────────────

pub async fn quic_tx_loop(
    mut tun_rx:   mpsc::Receiver<Vec<u8>>,
    connection:   quinn::Connection,
    noise:        Arc<Mutex<NoiseSession>>,
) -> anyhow::Result<()> {
    let mut pt_buf = vec![0u8; BUF];
    let mut ct_buf = vec![0u8; BUF];
    let mut send_nonce = NonceCounter::new();

    tracing::info!("TUN→QUIC loop started");

    loop {
        let mut ip_pkt = match tun_rx.recv().await {
            Some(pkt) => pkt,
            None => {
                tracing::warn!("TUN read channel closed");
                break;
            }
        };

        // Clamp TCP MSS early on client TX path to keep downstream packets within QUIC limits.
        let _ = clamp_tcp_mss(&mut ip_pkt, QUIC_TUNNEL_MSS);

        // Respect runtime QUIC datagram ceiling (depends on peer transport params + PMTU).
        let max_datagram = connection.max_datagram_size().unwrap_or(1200);
        let max_plaintext = max_datagram.saturating_sub(NONCE_LEN + 16); // 16 = Noise AEAD tag
        let min_plaintext = 2 + ip_pkt.len(); // inner length prefix + IP packet
        if min_plaintext > max_plaintext {
            tracing::warn!(
                "drop oversized TUN packet: ip_len={} min_plaintext={} max_plaintext={}",
                ip_pkt.len(),
                min_plaintext,
                max_plaintext
            );
            continue;
        }

        // Padding target (bounded by current datagram budget).
        let target = (ip_pkt.len() + 50).max(200).min(max_plaintext);

        let pt_len = match build_plaintext(&ip_pkt, target, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::trace!("build_plaintext error: {}", e);
                continue;
            }
        };

        // Encrypt
        let nonce = send_nonce.next_u64();
        let ct_len = {
            let mut session = noise.lock().await;
            match session.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::trace!("encrypt error: {}", e);
                    continue;
                }
            }
        };

        // Build datagram: [8B nonce][ciphertext]
        let mut datagram = Vec::with_capacity(NONCE_LEN + ct_len);
        datagram.extend_from_slice(&nonce.to_be_bytes());
        datagram.extend_from_slice(&ct_buf[..ct_len]);

        if datagram.len() > max_datagram {
            tracing::warn!(
                "drop oversized QUIC datagram before send: datagram_len={} max_datagram={}",
                datagram.len(),
                max_datagram
            );
            continue;
        }

        if let Err(e) = connection.send_datagram(datagram.into()) {
            tracing::warn!("QUIC send_datagram error: {}", e);
        }
    }
    Ok(())
}
