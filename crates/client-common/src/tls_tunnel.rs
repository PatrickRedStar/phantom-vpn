//! Raw TLS tunnel loops: direct [4B frame_len][batch] framing over TLS.
//! Multi-stream aware: each TLS connection is a single stream index.
//! Byte layout: see `phantom_core::wire`.
//!
//! Packets flow through the system as `Bytes`; each received packet costs one
//! allocation (copied out of the reusable frame buffer, MSS-clamped in place).

use std::borrow::BorrowMut;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use bytes::{Bytes, BytesMut};
use rand::Rng;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::time::Instant;
use phantom_core::{
    wire::{
        batch_packets, build_batch_plaintext, build_heartbeat_frame, next_heartbeat_delay,
        BATCH_MAX_PLAINTEXT, QUIC_TUNNEL_MSS,
    },
    mtu::clamp_tcp_mss,
};

/// Write the per-connection handshake header on a freshly-opened TLS stream:
/// `[stream_idx, max_streams]`, followed in the same TLS record by a regular
/// heartbeat frame. Must be called *before* entering the tx/rx loops.
///
/// The server reads exactly these 2 bytes (single `read_exact`) and then
/// parses frames, where the heartbeat is dropped like any other — so the
/// extra frame works against every server version. Without it the first
/// client record of every stream is always 2 bytes of plaintext, a fixed-size
/// tell. `max_streams` is always the client's full N; the server pins the
/// session's stream count from it.
pub async fn write_handshake<W: AsyncWriteExt + Unpin>(
    writer: &mut W,
    stream_idx: u8,
    max_streams: u8,
) -> anyhow::Result<()> {
    let hb = build_heartbeat_frame();
    let mut buf = Vec::with_capacity(2 + hb.len());
    buf.extend_from_slice(&[stream_idx, max_streams]);
    buf.extend_from_slice(&hb);
    writer
        .write_all(&buf)
        .await
        .map_err(|e| anyhow::anyhow!("write handshake: {}", e))?;
    writer
        .flush()
        .await
        .map_err(|e| anyhow::anyhow!("flush handshake: {}", e))?;
    Ok(())
}

/// RX loop: read [4B len][batch] from TLS → parse packets → push as `Bytes`
/// into the shared TUN sink channel.
///
/// `idle_timeout` (v0.24.0): when set, any read that waits longer returns
/// `Err`, which the caller surfaces as a dead stream. Without it a half-open
/// TCP socket (server reachable for ACKs but no data flowing — typical with
/// TSPU silently dropping packets) zombies forever on `read_exact`. Pass
/// `None` to keep the legacy unbounded wait (OpenWrt CLI uses this).
pub async fn tls_rx_loop<R: AsyncReadExt + Unpin>(
    reader: R,
    tun_tx: mpsc::Sender<Bytes>,
    idle_timeout: Option<Duration>,
) -> anyhow::Result<()> {
    tls_rx_loop_counted(reader, tun_tx, idle_timeout, &AtomicU32::new(0)).await
}

/// [`tls_rx_loop`] that also bumps `frames` on every received frame,
/// heartbeats included, so the caller can tell a quiet-but-alive stream from
/// a dead one without reading clocks on the hot path.
pub async fn tls_rx_loop_counted<R: AsyncReadExt + Unpin>(
    mut reader: R,
    tun_tx: mpsc::Sender<Bytes>,
    idle_timeout: Option<Duration>,
    frames: &AtomicU32,
) -> anyhow::Result<()> {
    let mut len_buf = [0u8; 4];
    let mut buf = vec![0u8; BATCH_MAX_PLAINTEXT];

    loop {
        read_exact_idle(&mut reader, &mut len_buf, idle_timeout, false).await?;
        let frame_len = u32::from_be_bytes(len_buf) as usize;
        if frame_len > BATCH_MAX_PLAINTEXT {
            return Err(anyhow::anyhow!("oversized frame: {}", frame_len));
        }
        // A header arrived, so the body MUST follow promptly as well.
        read_exact_idle(&mut reader, &mut buf[..frame_len], idle_timeout, true).await?;
        frames.fetch_add(1, Ordering::Relaxed);

        for pkt in batch_packets(&buf[..frame_len]) {
            // Drop anything that isn't a valid IPv4 packet: heartbeat stubs and
            // the server's mimicry warmup placeholder (16-byte stub) — the TUN
            // fd would return EINVAL on write(). TUN is v4-only (10.7.0.0/24),
            // so IPv6 bytes are also junk we don't want.
            if pkt.len() < 20 || (pkt[0] >> 4) != 4 {
                continue;
            }
            let mut pkt = BytesMut::from(pkt);
            let _ = clamp_tcp_mss(&mut pkt, QUIC_TUNNEL_MSS);
            if tun_tx.send(pkt.freeze()).await.is_err() {
                return Ok(());
            }
        }
    }
}

/// `read_exact` bounded by the optional idle timeout. Error strings are
/// matched by the runtime's error classifier — keep "rx idle timeout" /
/// "rx body timeout" / "TLS read".
async fn read_exact_idle<R: AsyncReadExt + Unpin>(
    reader: &mut R,
    buf: &mut [u8],
    idle_timeout: Option<Duration>,
    body: bool,
) -> anyhow::Result<()> {
    let what = if body { "body" } else { "header" };
    let res = match idle_timeout {
        Some(d) => match tokio::time::timeout(d, reader.read_exact(buf)).await {
            Ok(r) => r,
            Err(_) => {
                tracing::warn!(
                    category = "network",
                    event = if body { "rx.body_timeout" } else { "rx.idle_timeout" },
                    timeout_secs = d.as_secs(),
                    "no RX ({}) for {}s — treating stream as dead",
                    what,
                    d.as_secs(),
                );
                return Err(anyhow::anyhow!(
                    "rx {} timeout: no data for {}s",
                    if body { "body" } else { "idle" },
                    d.as_secs()
                ));
            }
        },
        None => reader.read_exact(buf).await,
    };
    res.map(|_| ())
        .map_err(|e| anyhow::anyhow!("TLS read {}: {}", what, e))
}

/// TX loop: drain a per-stream mpsc of `Bytes` into one batch frame per
/// wake-up and write it as a single TLS write (one record per ≤16 KB instead
/// of one record per packet), flushing once.
///
/// When the stream has been idle for a random 30–60 s (`next_heartbeat_delay`)
/// the loop sends a dummy heartbeat frame; real traffic postpones it.
///
/// `tun_rx` may be the receiver itself or `&mut` to it — the runtime keeps the
/// receiver across a stream reopen, the OpenWrt CLI hands it over.
pub async fn tls_tx_loop<W, R>(mut writer: W, mut tun_rx: R) -> anyhow::Result<()>
where
    W: AsyncWriteExt + Unpin,
    R: BorrowMut<mpsc::Receiver<Bytes>>,
{
    let tun_rx = tun_rx.borrow_mut();
    let mut frame_buf = vec![0u8; 4 + BATCH_MAX_PLAINTEXT];
    let mut batch: Vec<Bytes> = Vec::with_capacity(64);
    // A packet that did not fit into the previous frame opens the next one.
    let mut carry: Option<Bytes> = None;

    // #3 shaping (ADR 0014): optional policy floor for every frame.
    let policy_pad = {
        let p = phantom_core::policy::current();
        if p.padding.enabled { p.padding.target } else { 0 }
    };
    // The first 10–20 frames of a stream are padded to a random size: the
    // opening records would otherwise map 1:1 onto inner packet sizes (SYN,
    // ClientHello, DNS) — a classic tunnel tell. Receivers skip padding.
    let mut padded_left: u32 = rand::thread_rng().gen_range(10..=20);

    // One heartbeat timer, re-armed only when it fires: a data write just
    // stamps `last_tx`, so the hot path pays one clock read — not a fresh
    // timer and a policy lock per batch.
    let mut last_tx = Instant::now();
    let mut armed_at = last_tx;
    let mut hb_delay = next_heartbeat_delay();
    let hb_timer = tokio::time::sleep_until(armed_at + hb_delay);
    tokio::pin!(hb_timer);

    loop {
        let first = match carry.take() {
            Some(pkt) => pkt,
            None => tokio::select! {
                maybe_pkt = tun_rx.recv() => match maybe_pkt {
                    Some(pkt) => pkt,
                    None => break,
                },
                _ = &mut hb_timer => {
                    if last_tx > armed_at {
                        // Traffic since arming: postpone, keep the drawn interval.
                        armed_at = last_tx;
                    } else {
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
                        armed_at = Instant::now();
                        hb_delay = next_heartbeat_delay();
                    }
                    hb_timer.as_mut().reset(armed_at + hb_delay);
                    continue;
                }
            },
        };

        batch.clear();
        let mut batch_bytes = 2 + 2 + first.len(); // terminator + first packet
        batch.push(first);
        while let Ok(pkt) = tun_rx.try_recv() {
            if batch_bytes + 2 + pkt.len() > BATCH_MAX_PLAINTEXT {
                carry = Some(pkt);
                break;
            }
            batch_bytes += 2 + pkt.len();
            batch.push(pkt);
        }

        let pad = if padded_left > 0 {
            padded_left -= 1;
            policy_pad.max(rand::thread_rng().gen_range(64..=1400))
        } else {
            policy_pad
        };
        let refs: Vec<&[u8]> = batch.iter().map(|p| p.as_ref()).collect();
        let pt_len = match build_batch_plaintext(&refs, pad, &mut frame_buf[4..]) {
            Ok(n) => n,
            Err(e) => {
                // Only a single packet larger than a frame can get here.
                tracing::warn!(category = "packet", error = ?e, "tls_tx: dropping unframeable batch");
                continue;
            }
        };
        frame_buf[..4].copy_from_slice(&(pt_len as u32).to_be_bytes());

        writer
            .write_all(&frame_buf[..4 + pt_len])
            .await
            .map_err(|e| anyhow::anyhow!("TLS write: {}", e))?;
        writer
            .flush()
            .await
            .map_err(|e| anyhow::anyhow!("TLS flush: {}", e))?;
        last_tx = Instant::now();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncReadExt;

    /// Read every frame the TX side produced and return the IPv4 packets in
    /// order, plus the number of frames.
    fn decode(mut wire: &[u8]) -> (Vec<Vec<u8>>, usize) {
        let (mut pkts, mut frames) = (Vec::new(), 0);
        while wire.len() >= 4 {
            let len = u32::from_be_bytes(wire[..4].try_into().unwrap()) as usize;
            assert!(len <= BATCH_MAX_PLAINTEXT);
            let body = &wire[4..4 + len];
            pkts.extend(batch_packets(body).filter(|p| p[0] >> 4 == 4).map(|p| p.to_vec()));
            frames += 1;
            wire = &wire[4 + len..];
        }
        assert!(wire.is_empty());
        (pkts, frames)
    }

    fn ipv4(len: usize, tag: u8) -> Bytes {
        let mut p = vec![tag; len];
        p[0] = 0x45;
        Bytes::from(p)
    }

    /// Queued packets are coalesced into as few frames as fit and none is lost
    /// or reordered when the queue exceeds one 64 KB frame.
    #[tokio::test]
    async fn tx_coalesces_and_carries_over() {
        let (tx, rx) = mpsc::channel(256);
        let sent: Vec<Bytes> = (0..100).map(|i| ipv4(1300, i as u8)).collect();
        for p in &sent {
            tx.send(p.clone()).await.unwrap();
        }
        drop(tx);
        let (mut a, mut b) = tokio::io::duplex(1 << 20);
        tls_tx_loop(&mut a, rx).await.unwrap();
        drop(a);
        let mut wire = Vec::new();
        b.read_to_end(&mut wire).await.unwrap();
        let (pkts, frames) = decode(&wire);
        assert_eq!(pkts, sent.iter().map(|p| p.to_vec()).collect::<Vec<_>>());
        assert_eq!(frames, 2, "50 × 1302 B fill one 64 KB frame, the rest carries over");
    }

    /// The handshake is followed by a heartbeat in the same write, and the
    /// server-side view (2 bytes, then frames) still parses.
    #[tokio::test]
    async fn handshake_carries_heartbeat() {
        let mut out = Vec::new();
        write_handshake(&mut out, 3, 8).await.unwrap();
        assert_eq!(&out[..2], &[3, 8]);
        let (pkts, frames) = decode(&out[2..]);
        assert!(pkts.is_empty(), "heartbeat is not an IPv4 packet");
        assert_eq!(frames, 1);
    }

    /// RX counts every frame (heartbeats too) and forwards only IPv4.
    #[tokio::test]
    async fn rx_counts_frames_and_drops_heartbeats() {
        let mut wire = Vec::new();
        write_handshake(&mut wire, 0, 2).await.unwrap();
        let wire = wire[2..].to_vec();
        let mut frame = [0u8; 4 + 64];
        let n = build_batch_plaintext(&[&ipv4(20, 1)], 0, &mut frame[4..]).unwrap();
        frame[..4].copy_from_slice(&(n as u32).to_be_bytes());
        let wire = [wire, frame[..4 + n].to_vec()].concat();

        let (tx, mut rx) = mpsc::channel(8);
        let frames = AtomicU32::new(0);
        let res = tls_rx_loop_counted(&wire[..], tx, None, &frames).await;
        assert!(res.is_err(), "EOF ends the loop with an error");
        assert_eq!(frames.load(Ordering::Relaxed), 2);
        assert_eq!(rx.recv().await.unwrap(), ipv4(20, 1));
        assert!(rx.try_recv().is_err());
    }
}
