//! Клиентские RX/TX loops: TUN ↔ UDP (Noise encrypted).
//! Платформо-независимый код — принимает generic AsyncRead/AsyncWrite для TUN.

use std::sync::Arc;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, Mutex};
use tokio::io::AsyncReadExt;

use phantom_core::{
    crypto::NoiseSession,
    session::{NonceCounter, NonceReconstructor, ReplayWindow},
    wire::{SrtpHeader, SRTP_HEADER_LEN, build_plaintext, extract_ip_packet, TUNNEL_MSS},
    mtu::clamp_tcp_mss,
};

const BUF: usize = 65536;

// ─── UDP RX: server → decrypt → TUN ──────────────────────────────────────────

pub async fn udp_rx_loop(
    socket:     Arc<UdpSocket>,
    noise:      Arc<Mutex<NoiseSession>>,
    tun_tx:     mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    let mut buf        = vec![0u8; BUF];
    let mut decrypt_buf = vec![0u8; BUF];
    let mut replay_win = ReplayWindow::new();
    let mut recv_nonce = NonceReconstructor::new();

    tracing::info!("UDP RX loop started");

    loop {
        let n = match socket.recv(&mut buf).await {
            Ok(n)  => n,
            Err(e) => {
                tracing::warn!("UDP recv error: {}", e);
                continue;
            }
        };

        if n < SRTP_HEADER_LEN {
            tracing::trace!("drop: too short ({} bytes)", n);
            continue;
        }

        let hdr = match SrtpHeader::parse(&buf[..n]) {
            Ok(h)  => h,
            Err(e) => {
                tracing::trace!("drop: bad SRTP header: {}", e);
                continue;
            }
        };

        // Replay protection
        let nonce = recv_nonce.reconstruct(hdr.seq_num);
        if let Err(e) = replay_win.check_and_update(nonce) {
            tracing::trace!("replay drop: {}", e);
            continue;
        }

        let payload = &buf[SRTP_HEADER_LEN..n];

        // Расшифровка
        let pt_len = {
            let mut session = noise.lock().await;
            match session.decrypt(nonce, payload, &mut decrypt_buf) {
                Ok(n)  => n,
                Err(e) => {
                    tracing::trace!("decrypt failed: {}", e);
                    continue;
                }
            }
        };

        // Извлекаем IP пакет
        let ip_data = match extract_ip_packet(&decrypt_buf[..pt_len]) {
            Ok(d)  => d.to_vec(),
            Err(e) => {
                tracing::trace!("extract_ip failed: {}", e);
                continue;
            }
        };

        // MSS clamping
        let mut ip_buf = ip_data;
        let _ = clamp_tcp_mss(&mut ip_buf, TUNNEL_MSS);

        // Отправляем в TUN
        if let Err(e) = tun_tx.send(ip_buf).await {
            tracing::error!("tun_tx send error: {}", e);
        }
    }
}

// ─── TUN → UDP: TUN → encrypt → server ───────────────────────────────────────

/// Generic TUN-to-UDP loop. Принимает mpsc::Receiver<Vec<u8>> с IP пакетами из TUN.
/// Платформенный код отвечает за чтение из TUN и отправку пакетов в этот канал.
pub async fn tun_to_udp_loop(
    mut tun_rx: mpsc::Receiver<Vec<u8>>,
    socket:     Arc<UdpSocket>,
    noise:      Arc<Mutex<NoiseSession>>,
    ssrc:       u32,
) -> anyhow::Result<()> {
    let mut pt_buf   = vec![0u8; BUF];
    let mut ct_buf   = vec![0u8; BUF];
    let mut send_nonce = NonceCounter::new();
    let mut rtp_ts:  u32 = rand::random();

    tracing::info!("TUN→UDP loop started (ssrc={:#010x})", ssrc);

    loop {
        let ip_pkt = match tun_rx.recv().await {
            Some(pkt) => pkt,
            None => {
                tracing::warn!("TUN read channel closed");
                break;
            }
        };

        // Padding target: минимальный P-frame
        let target = (ip_pkt.len() + 50).max(200);

        let pt_len = match build_plaintext(&ip_pkt, target, &mut pt_buf) {
            Ok(n)  => n,
            Err(e) => {
                tracing::trace!("build_plaintext error: {}", e);
                continue;
            }
        };

        // Шифруем
        let (seq_num, nonce) = send_nonce.next();
        let ct_len = {
            let mut session = noise.lock().await;
            match session.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
                Ok(n)  => n,
                Err(e) => {
                    tracing::trace!("encrypt error: {}", e);
                    continue;
                }
            }
        };

        // Фейковый SRTP заголовок
        let mut pkt = vec![0u8; SRTP_HEADER_LEN + ct_len];
        let hdr = SrtpHeader {
            seq_num,
            timestamp: rtp_ts,
            ssrc,
            is_last: true,
        };
        hdr.write(&mut pkt[..SRTP_HEADER_LEN]);
        pkt[SRTP_HEADER_LEN..].copy_from_slice(&ct_buf[..ct_len]);

        rtp_ts  = rtp_ts.wrapping_add(3000); // 30 FPS, 90kHz

        if let Err(e) = socket.send(&pkt).await {
            tracing::warn!("UDP send error: {}", e);
        }
    }
    Ok(())
}
