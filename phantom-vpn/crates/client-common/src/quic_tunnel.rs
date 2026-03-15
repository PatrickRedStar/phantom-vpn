//! QUIC stream tunnel loops: TUN ↔ QUIC streams.
//! Данные передаются надёжными QUIC-стримами, батчами, по H.264-шаблону для DPI-защиты.
//!
//! Wire format одного stream-фрейма:
//!   [4B total_len][8B nonce][Noise ciphertext]
//!
//! Noise plaintext внутри — batch:
//!   [2B len1][pkt1][2B len2][pkt2]...[2B 0x0000][padding до H.264 target]

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::sync::mpsc;

use phantom_core::{
    crypto::NoiseSession,
    mtu::clamp_tcp_mss,
    wire::{build_batch_plaintext, extract_batch_packets, flow_stream_idx, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
};

// Буфер с запасом для Noise overhead (16B AEAD tag)
const BUF: usize = BATCH_MAX_PLAINTEXT + 64;

// ─── QUIC stream RX: stream → decrypt → TUN ──────────────────────────────────

pub async fn quic_stream_rx_loop(
    mut recv: quinn::RecvStream,
    noise: Arc<NoiseSession>,
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

        // 3. Расшифровываем (NoiseSession::decrypt берёт &self — lock не нужен)
        let pt_len = match noise.decrypt(nonce, ciphertext, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("stream RX: decrypt failed: {}", e);
                continue;
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

// ─── QUIC stream TX: N параллельных pipeline'ов ───────────────────────────────
//
// Dispatcher читает пакеты из TUN, раздаёт по N потокам по flow-hash (5-tuple).
// Каждый поток: [collect+encrypt task] → channel → [write task]
// Все потоки делят один AtomicU64 nonce counter — nonce глобально уникален.
//
// N потоков = нет head-of-line blocking: потеря пакета на потоке 2
// не блокирует потоки 1, 3, 4.

pub async fn quic_stream_tx_loop(
    tun_rx: mpsc::Receiver<Vec<u8>>,
    sends: Vec<quinn::SendStream>,
    noise: Arc<NoiseSession>,
) -> anyhow::Result<()> {
    let n = sends.len().max(1);
    let shared_nonce = Arc::new(AtomicU64::new(0));
    let mut stream_txs: Vec<mpsc::Sender<Vec<u8>>> = Vec::with_capacity(n);

    for send in sends {
        let (pkt_tx, pkt_rx) = mpsc::channel::<Vec<u8>>(512);
        let (frame_tx, frame_rx) = mpsc::channel::<Vec<u8>>(64);
        stream_txs.push(pkt_tx);

        // Stage 1: collect batch + encrypt → frame channel
        let noise_c = noise.clone();
        let nonce_c = shared_nonce.clone();
        tokio::spawn(async move {
            if let Err(e) = collect_encrypt_shared(pkt_rx, frame_tx, noise_c, nonce_c).await {
                tracing::warn!("TX stage1: {}", e);
            }
        });

        // Stage 2: write encrypted frames to this QUIC stream
        tokio::spawn(async move {
            let mut s = send;
            let mut fr = frame_rx;
            while let Some(frame) = fr.recv().await {
                if let Err(e) = s.write_all(&frame).await {
                    tracing::warn!("TX write: {}", e);
                    break;
                }
            }
        });
    }

    // Dispatcher: распределяем пакеты по потокам по flow-hash
    tracing::info!("QUIC multi-stream TX started ({} streams)", n);
    let mut tun_rx = tun_rx;
    while let Some(pkt) = tun_rx.recv().await {
        let idx = flow_stream_idx(&pkt, n);
        if stream_txs[idx].send(pkt).await.is_err() {
            break;
        }
    }

    Ok(())
}

// ─── Collect + encrypt с shared nonce counter ────────────────────────────────

async fn collect_encrypt_shared(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    frame_tx: mpsc::Sender<Vec<u8>>,
    noise: Arc<NoiseSession>,
    nonce_ctr: Arc<AtomicU64>,
) -> anyhow::Result<()> {
    let mut pt_buf = vec![0u8; BUF];
    let mut ct_buf = vec![0u8; BUF];

    loop {
        let first = match pkt_rx.recv().await {
            Some(p) => p,
            None => break,
        };

        let batch_limit = BATCH_MAX_PLAINTEXT - 16;
        let mut batch: Vec<Vec<u8>> = Vec::with_capacity(64);
        let mut batch_data_bytes = 2usize;

        let mut pkt = first;
        loop {
            let _ = clamp_tcp_mss(&mut pkt, QUIC_TUNNEL_MSS);
            batch_data_bytes += 2 + pkt.len();
            batch.push(pkt);
            if batch_data_bytes + 2 + 1350 > batch_limit {
                break;
            }
            match pkt_rx.try_recv() {
                Ok(p) => pkt = p,
                Err(_) => break,
            }
        }

        let refs: Vec<&[u8]> = batch.iter().map(|p| p.as_slice()).collect();
        let pt_len = match build_batch_plaintext(&refs, 0, &mut pt_buf) {
            Ok(n) => n,
            Err(e) => { tracing::warn!("build_batch: {}", e); continue; }
        };

        let nonce = nonce_ctr.fetch_add(1, Ordering::Relaxed);
        let ct_len = match noise.encrypt(nonce, &pt_buf[..pt_len], &mut ct_buf) {
            Ok(n) => n,
            Err(e) => { tracing::warn!("encrypt: {}", e); continue; }
        };

        let total_len = 8 + ct_len;
        let mut frame = vec![0u8; 4 + total_len];
        frame[..4].copy_from_slice(&(total_len as u32).to_be_bytes());
        frame[4..12].copy_from_slice(&nonce.to_be_bytes());
        frame[12..12 + ct_len].copy_from_slice(&ct_buf[..ct_len]);

        if frame_tx.send(frame).await.is_err() {
            break;
        }
    }

    Ok(())
}
