//! QUIC stream tunnel loops: TUN ↔ QUIC streams.
//! Данные передаются надёжными QUIC-стримами, батчами, по H.264-шаблону для DPI-защиты.
//!
//! Wire format одного stream-фрейма:
//!   [4B total_len][8B nonce][Noise ciphertext]
//!
//! Noise plaintext внутри — batch:
//!   [2B len1][pkt1][2B len2][pkt2]...[2B 0x0000][padding до H.264 target]

use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    crypto::NoiseSession,
    mtu::clamp_tcp_mss,
    session::NonceCounter,
    shaper::H264Shaper,
    wire::{build_batch_plaintext, extract_batch_packets, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
};

// Буфер с запасом для Noise overhead (16B AEAD tag)
const BUF: usize = BATCH_MAX_PLAINTEXT + 64;

// ─── QUIC stream RX: stream → decrypt → TUN ──────────────────────────────────

pub async fn quic_stream_rx_loop(
    mut recv: quinn::RecvStream,
    noise: Arc<Mutex<NoiseSession>>,
    tun_tx: mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    let mut ct_buf = vec![0u8; BUF];
    let mut pt_buf = vec![0u8; BUF];

    tracing::info!("QUIC stream RX loop started");

    loop {
        // 1. Читаем заголовок: [4B total_len]
        let mut len_buf = [0u8; 4];
        match tokio::io::AsyncReadExt::read_exact(&mut recv, &mut len_buf).await {
            Ok(_) => {}
            Err(e) => return Err(anyhow::anyhow!("stream RX: closed: {}", e)),
        }
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        // Минимум: 8B nonce + 16B AEAD tag = 24B
        if frame_len < 24 || frame_len > BUF {
            return Err(anyhow::anyhow!(
                "stream RX: invalid frame_len={}, closing",
                frame_len
            ));
        }

        // 2. Читаем [8B nonce][ciphertext]
        tokio::io::AsyncReadExt::read_exact(&mut recv, &mut ct_buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream RX: read frame: {}", e))?;

        let nonce = u64::from_be_bytes(ct_buf[..8].try_into().unwrap());
        let ciphertext = &ct_buf[8..frame_len];

        // 3. Расшифровываем
        let pt_len = {
            let mut session = noise.lock().await;
            match session.decrypt(nonce, ciphertext, &mut pt_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::warn!("stream RX: decrypt failed: {}", e);
                    continue;
                }
            }
        };

        // 4. Извлекаем все пакеты из батча
        let packets = match extract_batch_packets(&pt_buf[..pt_len]) {
            Ok(pkts) => pkts,
            Err(e) => {
                tracing::warn!("stream RX: extract_batch failed: {}", e);
                continue;
            }
        };

        for mut pkt in packets {
            // Пропускаем не-IPv4
            if pkt.len() < 20 || (pkt[0] >> 4) != 4 {
                continue;
            }
            let _ = clamp_tcp_mss(&mut pkt, QUIC_TUNNEL_MSS);
            if let Err(e) = tun_tx.send(pkt).await {
                tracing::error!("stream RX: tun_tx send error: {}", e);
            }
        }
    }
}

// ─── QUIC stream TX: TUN → batch → encrypt → stream ──────────────────────────

pub async fn quic_stream_tx_loop(
    mut tun_rx: mpsc::Receiver<Vec<u8>>,
    mut send: quinn::SendStream,
    noise: Arc<Mutex<NoiseSession>>,
) -> anyhow::Result<()> {
    let mut pt_buf = vec![0u8; BUF];
    let mut ct_buf = vec![0u8; BUF];
    let mut send_nonce = NonceCounter::new();
    let mut shaper = H264Shaper::new().map_err(|e| anyhow::anyhow!("shaper init: {}", e))?;

    tracing::info!("QUIC stream TX loop started");

    loop {
        // 1. Ждём первый пакет (блокирующий)
        let first = match tun_rx.recv().await {
            Some(p) => p,
            None => {
                tracing::warn!("TUN channel closed");
                break;
            }
        };

        // 2. Определяем целевой размер фрейма по H.264 шаблону
        let target = shaper.next_frame().target_bytes.min(BATCH_MAX_PLAINTEXT - 16);

        // 3. Собираем батч: берём все уже доступные пакеты из канала (non-blocking)
        let mut batch: Vec<Vec<u8>> = Vec::with_capacity(16);
        let mut batch_data_bytes = 0usize;

        let mut pkt = first;
        loop {
            let _ = clamp_tcp_mss(&mut pkt, QUIC_TUNNEL_MSS);
            batch_data_bytes += 2 + pkt.len();
            batch.push(pkt);

            // Останавливаемся если набрали достаточно или буфер переполнится
            if batch_data_bytes >= target || batch_data_bytes + 2 + 1350 > BATCH_MAX_PLAINTEXT - 16 {
                break;
            }
            // Non-blocking drain
            match tun_rx.try_recv() {
                Ok(p) => pkt = p,
                Err(_) => break,
            }
        }

        // 4. Строим batch plaintext: реальные данные + H.264 padding
        let refs: Vec<&[u8]> = batch.iter().map(|p| p.as_slice()).collect();
        let pt_len = match build_batch_plaintext(&refs, target, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("stream TX: build_batch failed: {}", e);
                continue;
            }
        };

        // 5. Шифруем
        let nonce = send_nonce.next_u64();
        let ct_len = {
            let mut session = noise.lock().await;
            match session.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
                Ok(n) => n,
                Err(e) => {
                    tracing::warn!("stream TX: encrypt failed: {}", e);
                    continue;
                }
            }
        };

        // 6. Пишем фрейм: [4B total_len][8B nonce][ciphertext]
        let total_len = 8 + ct_len;
        let mut frame = Vec::with_capacity(4 + total_len);
        frame.extend_from_slice(&(total_len as u32).to_be_bytes());
        frame.extend_from_slice(&nonce.to_be_bytes());
        frame.extend_from_slice(&ct_buf[..ct_len]);

        if let Err(e) = send.write_all(&frame).await {
            return Err(anyhow::anyhow!("stream TX: write failed: {}", e));
        }
    }
    Ok(())
}
