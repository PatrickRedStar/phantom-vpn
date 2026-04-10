//! HTTP/2 tunnel loops: RX (HTTP/2 DATA → TUN) and TX (TUN → HTTP/2 DATA).

use bytes::{Bytes, Buf, BytesMut};
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use phantom_core::{
    wire::{build_batch_plaintext, flow_stream_idx, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS},
    mtu::clamp_tcp_mss,
};

/// HTTP/2 stream RX loop: DATA frames → TUN
/// Buffers incoming DATA frames and parses [4B len][batch] format.
pub async fn h2_stream_rx_loop(
    mut recv: h2::RecvStream,
    tun_tx: mpsc::Sender<Vec<u8>>,
) -> anyhow::Result<()> {
    let buf_size = BATCH_MAX_PLAINTEXT + 16;
    let mut chunk_buf = BytesMut::with_capacity(buf_size);

    loop {
        // Read DATA frame chunk
        let chunk = match recv.data().await {
            Some(Ok(c)) => c,
            Some(Err(e)) => {
                tracing::debug!("H2 stream data error: {}", e);
                break;
            }
            None => break, // EOS
        };

        // Append to chunk buffer
        chunk_buf.extend_from_slice(&chunk);

        // Parse complete frames [4B len][batch] — zero-copy walk of chunk_buf
        while chunk_buf.len() >= 4 {
            let frame_len = u32::from_be_bytes([chunk_buf[0], chunk_buf[1], chunk_buf[2], chunk_buf[3]]) as usize;
            if chunk_buf.len() < 4 + frame_len {
                break; // incomplete frame
            }

            // Walk batch directly in chunk_buf (no intermediate Vec)
            let batch_end = 4 + frame_len;
            let mut offset = 4;
            loop {
                if offset + 2 > batch_end { break; }
                let pkt_len = u16::from_be_bytes([chunk_buf[offset], chunk_buf[offset + 1]]) as usize;
                offset += 2;
                if pkt_len == 0 { break; }
                if offset + pkt_len > batch_end { break; }

                if pkt_len >= 20 && (chunk_buf[offset] >> 4) == 4 {
                    let _ = clamp_tcp_mss(&mut chunk_buf[offset..offset + pkt_len], QUIC_TUNNEL_MSS);
                    if tun_tx.send(chunk_buf[offset..offset + pkt_len].to_vec()).await.is_err() {
                        return Ok(());
                    }
                }
                offset += pkt_len;
            }

            // Consume frame from buffer
            chunk_buf.advance(batch_end);

            // Return H2 RX credit only after the frame was fully accounted for locally:
            // either forwarded into tun_tx or dropped as consumed in this pass.
            if let Err(e) = recv.flow_control().release_capacity(batch_end) {
                tracing::debug!("Flow control error: {}", e);
                break;
            }
        }
    }

    Ok(())
}

/// HTTP/2 stream TX loop: TUN → HTTP/2 DATA frames.
/// Blocks until the TX pipeline dies (any stream failure triggers full shutdown).
/// Returns Ok(()) on clean shutdown, Err if task join failed.
pub async fn h2_stream_tx_loop(
    tun_rx: mpsc::Receiver<Vec<u8>>,
    sends: Vec<h2::SendStream<Bytes>>,
) -> anyhow::Result<()> {
    let n_streams = sends.len();

    // Create per-stream channels for packet dispatch
    let mut stream_txs: Vec<mpsc::Sender<Vec<u8>>> = Vec::new();
    let mut stream_rxs: Vec<mpsc::Receiver<Vec<u8>>> = Vec::new();
    for _ in 0..n_streams {
        let (tx, rx) = mpsc::channel::<Vec<u8>>(2048);
        stream_txs.push(tx);
        stream_rxs.push(rx);
    }

    let mut task_set: JoinSet<()> = JoinSet::new();

    // Spawn dispatcher: TUN packets → per-stream channels
    task_set.spawn(async move {
        let mut tun_rx = tun_rx;
        loop {
            let pkt = match tun_rx.recv().await {
                Some(p) => p,
                None => break,
            };
            let idx = flow_stream_idx(&pkt, n_streams);
            if stream_txs[idx].send(pkt).await.is_err() {
                break;
            }
        }
        tracing::debug!("H2 TX dispatcher exiting");
    });

    // Spawn per-stream batch+send tasks
    tracing::info!("H2 stream TX loop: spawning {} per-stream tasks", n_streams);
    for (idx, mut send) in sends.into_iter().enumerate() {
        let mut stream_rx = stream_rxs.remove(0);
        task_set.spawn(async move {
            // H2 over TCP/TLS — no H.264 shaping needed (DPI sees encrypted TCP, not packets)
            let buf_size = 4 + BATCH_MAX_PLAINTEXT + 16;
            let mut frame_buf = vec![0u8; buf_size];
            let mut batch: Vec<Vec<u8>> = Vec::with_capacity(64);
            let batch_limit = BATCH_MAX_PLAINTEXT - 16;

            loop {
                batch.clear();
                let mut batch_data_bytes = 2usize; // end marker

                // Wait for at least one packet
                let pkt = match stream_rx.recv().await {
                    Some(p) => p,
                    None => break,
                };
                batch_data_bytes += 2 + pkt.len();
                batch.push(pkt);

                // Collect more (by bytes, not count — like QUIC)
                while batch_data_bytes + 2 + 1350 <= batch_limit {
                    match stream_rx.try_recv() {
                        Ok(pkt) => {
                            batch_data_bytes += 2 + pkt.len();
                            batch.push(pkt);
                        }
                        Err(_) => break,
                    }
                }

                // Build batch plaintext (target_bytes = 0: no padding)
                let refs: Vec<&[u8]> = batch.iter().map(|p| p.as_slice()).collect();
                let pt_len = match build_batch_plaintext(&refs, 0, &mut frame_buf[4..]) {
                    Ok(n) => n,
                    Err(_) => continue,
                };

                frame_buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
                let frame_len = 4 + pt_len;
                let frame = Bytes::copy_from_slice(&frame_buf[..frame_len]);

                // Send via HTTP/2 DATA frame
                if let Err(e) = send.send_data(frame, false) {
                    tracing::warn!("H2 stream {} send_data error: {}", idx, e);
                    break;
                }
            }
            tracing::debug!("H2 TX stream {} task exiting", idx);
        });
    }

    tracing::info!("H2 TX: {} streams + dispatcher running", n_streams);

    // Block until first task exits (any stream death triggers full TX shutdown)
    if let Some(res) = task_set.join_next().await {
        if let Err(e) = res {
            tracing::error!("H2 TX task panicked: {}", e);
        } else {
            tracing::warn!("H2 TX task completed (stream died or channel closed)");
        }
    }

    // Abort remaining tasks immediately
    task_set.abort_all();
    tracing::info!("H2 TX pipeline shut down");
    Ok(())
}
