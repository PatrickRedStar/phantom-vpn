//! QUIC stream tunnel loops: TUN ↔ QUIC streams.
//! Optimized pipeline: dispatcher → per-stream [batch+write] (2 hops, not 3).

use phantom_core::{
    mtu::clamp_tcp_mss,
    shaper::H264Shaper,
    wire::{build_batch_plaintext, flow_stream_idx, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;

const BUF: usize = 4 + BATCH_MAX_PLAINTEXT + 16;

// ─── QUIC stream RX: stream → TUN (zero-copy extract) ──────────────────────

pub async fn quic_stream_rx_loop(
    mut recv: quinn::RecvStream,
    tun_tx: mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    use tokio::io::AsyncReadExt;
    let mut frame_buf = vec![0u8; BUF];

    tracing::info!("QUIC stream RX loop started");

    loop {
        let mut len_buf = [0u8; 4];
        recv.read_exact(&mut len_buf)
            .await
            .map_err(|e| anyhow::anyhow!("stream RX: closed: {}", e))?;
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len < 4 || frame_len > BUF {
            return Err(anyhow::anyhow!("stream RX: invalid frame_len={}", frame_len));
        }

        recv.read_exact(&mut frame_buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream RX: read frame: {}", e))?;

        // Walk batch in-place
        let mut offset = 0;
        loop {
            if offset + 2 > frame_len { break; }
            let pkt_len = u16::from_be_bytes([
                frame_buf[offset], frame_buf[offset + 1],
            ]) as usize;
            offset += 2;
            if pkt_len == 0 { break; }
            if offset + pkt_len > frame_len { break; }

            if pkt_len >= 20 && (frame_buf[offset] >> 4) == 4 {
                let _ = clamp_tcp_mss(&mut frame_buf[offset..offset + pkt_len], QUIC_TUNNEL_MSS);
                if tun_tx.send(frame_buf[offset..offset + pkt_len].to_vec()).await.is_err() {
                    return Ok(());
                }
            }
            offset += pkt_len;
        }
    }
}

// ─── QUIC stream TX: dispatcher → per-stream batch+write ────────────────────
//
// Old (3 hops): dispatcher → mpsc → collect_and_batch → mpsc → write_loop → QUIC
// New (2 hops): dispatcher → mpsc → [batch + write_all] → QUIC
//
// With unlimited CC (128MB window), write_all returns instantly (quinn buffers).
// No need for pipeline parallelism between batch and write.

pub async fn quic_stream_tx_loop(
    tun_rx: mpsc::Receiver<Vec<u8>>,
    sends: Vec<quinn::SendStream>,
) -> anyhow::Result<()> {
    let n = sends.len().max(1);
    let mut stream_txs: Vec<mpsc::Sender<Vec<u8>>> = Vec::with_capacity(n);

    for send in sends {
        let (pkt_tx, pkt_rx) = mpsc::channel::<Vec<u8>>(512);
        stream_txs.push(pkt_tx);

        // Single task: collect batch + write directly to QUIC stream.
        // No intermediate frame channel (eliminated 1 hop).
        tokio::spawn(async move {
            if let Err(e) = batch_and_write(pkt_rx, send).await {
                tracing::warn!("TX pipeline: {}", e);
            }
        });
    }

    // Dispatcher: route packets to streams by flow-hash
    tracing::info!("QUIC TX started ({} streams, 2-hop pipeline)", n);
    let mut tun_rx = tun_rx;
    while let Some(pkt) = tun_rx.recv().await {
        let idx = flow_stream_idx(&pkt, n);
        if stream_txs[idx].send(pkt).await.is_err() {
            break;
        }
    }

    Ok(())
}

// ─── Batch + write in one task ──────────────────────────────────────────────

async fn batch_and_write(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    mut send: quinn::SendStream,
) -> anyhow::Result<()> {
    let mut buf = vec![0u8; BUF];
    let mut shaper = H264Shaper::new().map_err(|e| anyhow::anyhow!("shaper: {}", e))?;

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

        let frame = shaper.next_frame();
        let pt_len = match build_batch_plaintext(&refs, frame.target_bytes, &mut buf[4..]) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("build_batch: {}", e);
                continue;
            }
        };

        buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());

        // Direct write to QUIC stream — no frame channel.
        // With unlimited CC, quinn always has buffer space, write_all returns fast.
        send.write_all(&buf[..4 + pt_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream TX write: {}", e))?;
    }

    Ok(())
}
