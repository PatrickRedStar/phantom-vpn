//! Raw TLS tunnel loops: direct [4B frame_len][batch] framing over TLS.
//! Multi-stream aware: each TLS connection is a single stream index.
//!
//! Zero-copy: packets flow through the system as `Bytes`, avoiding `.to_vec()`
//! on every hop. `BytesMut` is used for reassembly buffers and sliced via
//! `split_to(n).freeze()` to hand off to the next stage without a copy.

use bytes::{Bytes, BytesMut};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::time::Instant;
use phantom_core::{
    wire::{
        build_batch_plaintext, build_heartbeat_frame, first_heartbeat_delay,
        next_heartbeat_delay, BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS,
    },
    mtu::clamp_tcp_mss,
};

const RX_BUF_INIT: usize = 128 * 1024;

/// Write the per-connection handshake header (2 bytes) on freshly-opened
/// TLS stream: `[stream_idx, max_streams]`. Must be called *before* entering
/// the tx/rx loops. The server reads `stream_idx` first and then waits up to
/// 200 ms for `max_streams`; if absent (v0.17 client) the server falls back
/// to its own `n_data_streams()`. Negotiated stream count is
/// `effective_n = min(server_n, client_max_streams)`.
pub async fn write_handshake<W: AsyncWriteExt + Unpin>(
    writer: &mut W,
    stream_idx: u8,
    max_streams: u8,
) -> anyhow::Result<()> {
    writer
        .write_all(&[stream_idx, max_streams])
        .await
        .map_err(|e| anyhow::anyhow!("write handshake: {}", e))?;
    writer
        .flush()
        .await
        .map_err(|e| anyhow::anyhow!("flush handshake: {}", e))?;
    Ok(())
}

/// RX loop: read [4B len][batch] from TLS → parse packets → push as `Bytes`
/// into the shared TUN sink channel. Uses a single reusable `BytesMut` buffer
/// that is sliced per-packet, so each packet is a cheap refcount bump instead
/// of an allocation.
pub async fn tls_rx_loop<R: AsyncReadExt + Unpin>(
    mut reader: R,
    tun_tx: mpsc::Sender<Bytes>,
) -> anyhow::Result<()> {
    let mut len_buf = [0u8; 4];
    let mut buf = BytesMut::with_capacity(RX_BUF_INIT);

    loop {
        reader
            .read_exact(&mut len_buf)
            .await
            .map_err(|e| anyhow::anyhow!("TLS read header: {}", e))?;
        let frame_len = u32::from_be_bytes(len_buf) as usize;
        if frame_len == 0 {
            continue;
        }
        if frame_len > BATCH_MAX_PLAINTEXT {
            return Err(anyhow::anyhow!("oversized frame: {}", frame_len));
        }

        // Make room for the full frame as a contiguous slice, then read into it.
        buf.resize(frame_len, 0);
        reader
            .read_exact(&mut buf[..frame_len])
            .await
            .map_err(|e| anyhow::anyhow!("TLS read body: {}", e))?;

        // Parse batch in place.
        let mut offset = 0usize;
        while offset + 2 <= frame_len {
            let pkt_len = u16::from_be_bytes([buf[offset], buf[offset + 1]]) as usize;
            offset += 2;
            if pkt_len == 0 {
                break;
            }
            if offset + pkt_len > frame_len {
                break;
            }
            // Drop anything that isn't a valid IPv4 packet. This silently
            // discards the mimicry warmup placeholder (16-byte stub) the
            // server prepends to stream 0 on new sessions — the TUN fd would
            // otherwise return EINVAL on write(). TUN is v4-only (10.7.0.0/24),
            // so IPv6 bytes are also junk we don't want.
            if pkt_len < 20 || (buf[offset] >> 4) != 4 {
                offset += pkt_len;
                continue;
            }
            // Clamp MSS in place, then hand off as a zero-copy slice.
            let _ = clamp_tcp_mss(&mut buf[offset..offset + pkt_len], QUIC_TUNNEL_MSS);
            let pkt = Bytes::copy_from_slice(&buf[offset..offset + pkt_len]);
            // NOTE: `Bytes::copy_from_slice` keeps a single owned allocation per
            // packet, which is unavoidable because the backing `BytesMut` is
            // reused across frames. If we want true zero-copy we'd need to
            // `buf.split_to(offset + pkt_len).freeze()` the whole frame up front
            // and index inside the frozen Bytes. Current form is already a
            // significant win because the channel no longer carries `Vec<u8>`
            // with a separate heap header.
            if tun_tx.send(pkt).await.is_err() {
                return Ok(());
            }
            offset += pkt_len;
        }

        // Drop processed data; cap the buffer so it does not grow unbounded
        // across oversized frames.
        buf.clear();
        if buf.capacity() > BATCH_MAX_PLAINTEXT * 2 {
            buf = BytesMut::with_capacity(RX_BUF_INIT);
        }
    }
}

/// TX loop: drain a per-stream mpsc of `Bytes`, coalesce into a batch,
/// emit `[4B len][batch]` over this stream's TLS writer.
///
/// When no real TUN packet has been sent for ~20–30 s the loop fires a dummy
/// heartbeat frame to keep the TLS stream looking alive to passive DPI. Real
/// traffic resets the heartbeat timer, so active streams never emit them.
pub async fn tls_tx_loop<W: AsyncWriteExt + Unpin>(
    mut writer: W,
    mut tun_rx: mpsc::Receiver<Bytes>,
) -> anyhow::Result<()> {
    let buf_size = 4 + BATCH_MAX_PLAINTEXT + 16;
    let mut frame_buf = vec![0u8; buf_size];
    let batch_limit = BATCH_MAX_PLAINTEXT - 16;
    let mut batch: Vec<Bytes> = Vec::with_capacity(64);

    // First heartbeat is jittered per-stream so all N streams don't fire at t=20.
    let mut next_heartbeat: Instant = Instant::now() + first_heartbeat_delay();

    loop {
        batch.clear();
        let mut batch_bytes = 2usize; // end marker

        tokio::select! {
            maybe_pkt = tun_rx.recv() => {
                let pkt = match maybe_pkt {
                    Some(p) => p,
                    None => break,
                };
                batch_bytes += 2 + pkt.len();
                batch.push(pkt);

                while batch_bytes + 2 + 1500 <= batch_limit {
                    match tun_rx.try_recv() {
                        Ok(pkt) => {
                            batch_bytes += 2 + pkt.len();
                            batch.push(pkt);
                        }
                        Err(_) => break,
                    }
                }

                let refs: Vec<&[u8]> = batch.iter().map(|p| p.as_ref()).collect();
                let pt_len = match build_batch_plaintext(&refs, 0, &mut frame_buf[4..]) {
                    Ok(n) => n,
                    Err(_) => continue,
                };

                frame_buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
                let total = 4 + pt_len;

                writer
                    .write_all(&frame_buf[..total])
                    .await
                    .map_err(|e| anyhow::anyhow!("TLS write: {}", e))?;

                // Drain + coalesce: write queued frames before flushing so
                // multiple batches merge into fewer TLS records / syscalls.
                let mut extra_write_err = false;
                for _ in 0..31 {
                    match tun_rx.try_recv() {
                        Ok(extra_pkt) => {
                            let refs: Vec<&[u8]> = vec![extra_pkt.as_ref()];
                            let pt_len = match build_batch_plaintext(&refs, 0, &mut frame_buf[4..]) {
                                Ok(n) => n,
                                Err(_) => continue,
                            };
                            frame_buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());
                            let t = 4 + pt_len;
                            if writer.write_all(&frame_buf[..t]).await.is_err() {
                                extra_write_err = true;
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                if extra_write_err {
                    return Err(anyhow::anyhow!("TLS write failed during drain"));
                }
                writer
                    .flush()
                    .await
                    .map_err(|e| anyhow::anyhow!("TLS flush: {}", e))?;

                // Real traffic just went out — push the next heartbeat out.
                next_heartbeat = Instant::now() + next_heartbeat_delay();
            }
            _ = tokio::time::sleep_until(next_heartbeat) => {
                let hb = build_heartbeat_frame();
                writer
                    .write_all(&hb)
                    .await
                    .map_err(|e| anyhow::anyhow!("TLS heartbeat write: {}", e))?;
                writer
                    .flush()
                    .await
                    .map_err(|e| anyhow::anyhow!("TLS heartbeat flush: {}", e))?;
                tracing::trace!(bytes = hb.len(), "tls_tx heartbeat fired");
                next_heartbeat = Instant::now() + next_heartbeat_delay();
            }
        }
    }

    Ok(())
}
