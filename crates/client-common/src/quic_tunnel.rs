//! QUIC stream tunnel loops: TUN ↔ QUIC streams.
//! Zero-copy optimized: batch built directly into frame buffer,
//! written to QUIC stream without intermediate allocations.

use bytes::Bytes;
use phantom_core::{
    mtu::clamp_tcp_mss,
    shaper::H264Shaper,
    wire::{build_batch_plaintext, flow_stream_idx, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
};
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
        // 1. Read frame header: [4B total_len]
        let mut len_buf = [0u8; 4];
        recv.read_exact(&mut len_buf)
            .await
            .map_err(|e| anyhow::anyhow!("stream RX: closed: {}", e))?;
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len < 4 || frame_len > BUF {
            return Err(anyhow::anyhow!("stream RX: invalid frame_len={}", frame_len));
        }

        // 2. Read plaintext batch into frame_buf
        recv.read_exact(&mut frame_buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("stream RX: read frame: {}", e))?;

        // 3. Walk batch in-place: [2B len][data]...[2B 0x0000]
        //    No intermediate Vec<Vec<u8>> — process each packet directly from frame_buf.
        let mut offset = 0;
        loop {
            if offset + 2 > frame_len { break; }
            let pkt_len = u16::from_be_bytes([
                frame_buf[offset], frame_buf[offset + 1],
            ]) as usize;
            offset += 2;
            if pkt_len == 0 { break; } // end-of-batch
            if offset + pkt_len > frame_len { break; }

            if pkt_len >= 20 && (frame_buf[offset] >> 4) == 4 {
                // Clamp MSS in-place (modifies frame_buf directly)
                let _ = clamp_tcp_mss(&mut frame_buf[offset..offset + pkt_len], QUIC_TUNNEL_MSS);
                // Single copy: frame_buf slice → owned Vec for channel send
                if tun_tx.send(frame_buf[offset..offset + pkt_len].to_vec()).await.is_err() {
                    return Ok(());
                }
            }
            offset += pkt_len;
        }
    }
}

// ─── QUIC stream TX: N parallel pipelines (zero-copy batch+write) ───────────

pub async fn quic_stream_tx_loop(
    tun_rx: mpsc::Receiver<Vec<u8>>,
    sends: Vec<quinn::SendStream>,
) -> anyhow::Result<()> {
    let n = sends.len().max(1);
    let mut stream_txs: Vec<mpsc::Sender<Vec<u8>>> = Vec::with_capacity(n);

    for send in sends {
        let (pkt_tx, pkt_rx) = mpsc::channel::<Vec<u8>>(512);
        let (frame_tx, frame_rx) = mpsc::channel::<Bytes>(64);
        stream_txs.push(pkt_tx);

        // Stage 1: collect + batch → frame channel (pipelined)
        tokio::spawn(async move {
            if let Err(e) = collect_and_batch(pkt_rx, frame_tx).await {
                tracing::warn!("TX stage1: {}", e);
            }
        });

        // Stage 2: write frames to QUIC stream (zero-copy via write_chunk)
        tokio::spawn(async move {
            let mut s = send;
            let mut fr = frame_rx;
            while let Some(frame) = fr.recv().await {
                if let Err(e) = s.write_chunk(frame).await {
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

// ─── Collect + batch (zero-copy: 1 copy instead of 2) ───────────────────────
//
// Old: build_batch → pt_buf → alloc frame Vec → copy pt_buf into frame (2 copies)
// New: build_batch directly at buf[4..] → prepend header → to_vec once (1 copy)

async fn collect_and_batch(
    mut pkt_rx: mpsc::Receiver<Vec<u8>>,
    frame_tx: mpsc::Sender<Bytes>,
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

        // H.264 shaping: pad batch to match video frame size pattern
        let frame = shaper.next_frame();
        let target_size = frame.target_bytes;
        shaper.report_data_size(batch_data_bytes, target_size);

        let pt_len = match build_batch_plaintext(&refs, target_size, &mut buf[4..]) {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!("build_batch: {}", e);
                continue;
            }
        };

        // Prepend header, then Bytes::copy_from_slice → zero-copy through channel + quinn
        buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
        let frame = Bytes::copy_from_slice(&buf[..4 + pt_len]);
        if frame_tx.send(frame).await.is_err() {
            break;
        }
    }

    Ok(())
}
