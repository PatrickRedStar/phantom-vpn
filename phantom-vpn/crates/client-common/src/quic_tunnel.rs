//! QUIC stream tunnel loops: TUN ↔ QUIC streams.
//! Data is sent as raw batch plaintext over reliable QUIC streams.
//! QUIC TLS provides confidentiality — no additional encryption layer.
//!
//! Wire format of one stream frame:
//!   [4B total_len][batch plaintext]
//!
//! Batch plaintext format:
//!   [2B len1][pkt1][2B len2][pkt2]...[2B 0x0000][padding to H.264 target]

use phantom_core::{
    mtu::clamp_tcp_mss,
    wire::{build_batch_plaintext, extract_batch_packets, flow_stream_idx, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
};
use tokio::sync::mpsc;

const BUF: usize = BATCH_MAX_PLAINTEXT + 16;

// ─── QUIC stream RX: stream → decrypt → TUN ──────────────────────────────────

pub async fn quic_stream_rx_loop(
    mut recv: quinn::RecvStream,
    tun_tx: mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    let mut frame_buf = vec![0u8; BUF];

    tracing::info!("QUIC stream RX loop started");

    loop {
        // 1. Read frame header: [4B total_len]
        let mut len_buf = [0u8; 4];
        match tokio::io::AsyncReadExt::read_exact(&mut recv, &mut len_buf).await {
            Ok(_) => {}
            Err(e) => return Err(anyhow::anyhow!("stream RX: closed: {}", e)),
        }
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len < 4 || frame_len > BUF {
            return Err(anyhow::anyhow!(
                "stream RX: invalid frame_len={}, closing",
                frame_len
            ));
        }

        // 2. Read [frame_len bytes of plaintext batch]
        tokio::io::AsyncReadExt::read_exact(&mut recv, &mut frame_buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream RX: read frame: {}", e))?;

        // 3. Extract all packets from the batch
        let packets = match extract_batch_packets(&frame_buf[..frame_len]) {
            Ok(pkts) => pkts,
            Err(e) => {
                tracing::warn!("stream RX: extract_batch failed: {}", e);
                continue;
            }
        };

        for mut pkt in packets {
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

// ─── QUIC stream TX: N parallel pipelines ────────────────────────────────────
//
// Dispatcher reads packets from TUN, distributes to N streams by flow-hash (5-tuple).
// Each stream: [collect+batch task] → channel → [write task]
// No encryption here — QUIC TLS handles confidentiality.

pub async fn quic_stream_tx_loop(
    tun_rx: mpsc::Receiver<Vec<u8>>,
    sends: Vec<quinn::SendStream>,
) -> anyhow::Result<()> {
    let n = sends.len().max(1);
    let mut stream_txs: Vec<mpsc::Sender<Vec<u8>>> = Vec::with_capacity(n);

    for send in sends {
        let (pkt_tx, pkt_rx) = mpsc::channel::<Vec<u8>>(512);
        let (frame_tx, frame_rx) = mpsc::channel::<Vec<u8>>(64);
        stream_txs.push(pkt_tx);

        // Stage 1: collect batch → frame channel
        tokio::spawn(async move {
            if let Err(e) = collect_and_batch(pkt_rx, frame_tx).await {
                tracing::warn!("TX stage1: {}", e);
            }
        });

        // Stage 2: write frames to this QUIC stream
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

    // Dispatcher: route packets to streams by flow-hash
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

// ─── Collect + batch (no encryption) ─────────────────────────────────────────

async fn collect_and_batch(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    frame_tx: mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    let mut pt_buf = vec![0u8; BUF];

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
            Err(e) => {
                tracing::warn!("build_batch: {}", e);
                continue;
            }
        };

        // Frame: [4B pt_len][plaintext batch]
        let mut frame = vec![0u8; 4 + pt_len];
        frame[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
        frame[4..].copy_from_slice(&pt_buf[..pt_len]);

        if frame_tx.send(frame).await.is_err() {
            break;
        }
    }

    Ok(())
}
