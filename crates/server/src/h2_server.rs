//! TLS server: TCP/TLS accept loop with multi-stream SessionCoordinator.
//!
//! Wire protocol:
//! 1. TCP accept
//! 2. mTLS handshake (client cert validated against allowlist)
//! 3. Client writes 1 byte: `stream_idx` ∈ [0, N_STREAMS)
//! 4. Frame loop: [4B frame_len u32 BE][batch: (2B pktlen)(ip_pkt)...(2B 0x0000)]
//!
//! Up to `N_STREAMS` parallel TCP connections per client fingerprint are
//! aggregated via `VpnSession` (SessionCoordinator). Each physical connection
//! claims one slot; TUN→client frames are dispatched across slots via
//! round-robin. When all slots become empty the session is reaped.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::{Bytes, BytesMut};
use futures_util::future::poll_fn;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    mtu::clamp_tcp_mss,
    wire::{BATCH_MAX_PLAINTEXT, N_STREAMS, QUIC_TUNNEL_MSS},
};

use crate::vpn_session::{
    self, ClientAllowList, DestEntry, SessionByFp, VpnSession, VpnSessionMap,
};

/// TLS accept loop: TCP → TLS → multi-stream tunnel or h2 fallback.
pub async fn run_h2_accept_loop(
    listener: TcpListener,
    tls_acceptor: Arc<rustls::ServerConfig>,
    tun_tx: mpsc::Sender<Bytes>,
    sessions: VpnSessionMap,
    sessions_by_fp: SessionByFp,
    tun_network: Ipv4Addr,
    tun_prefix: u8,
    allow_list: ClientAllowList,
) -> anyhow::Result<()> {
    tracing::info!("TLS accept loop started on {}", listener.local_addr()?);

    let tls_acceptor = tokio_rustls::TlsAcceptor::from(tls_acceptor);

    loop {
        let (tcp, remote) = listener.accept().await?;
        let _ = tcp.set_nodelay(true);
        let tun_tx = tun_tx.clone();
        let sessions = sessions.clone();
        let sessions_by_fp = sessions_by_fp.clone();
        let allow_list = allow_list.clone();
        let tls_acceptor = tls_acceptor.clone();

        tokio::spawn(async move {
            tracing::debug!("Incoming TCP connection from {}", remote);

            // TLS handshake
            let tls_stream = match tls_acceptor.accept(tcp).await {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!("TLS handshake failed from {}: {}", remote, e);
                    return;
                }
            };

            // Extract client cert for mTLS
            let peer_certs = tls_stream.get_ref().1.peer_certificates()
                .map(|certs| certs.to_vec())
                .unwrap_or_default();

            if peer_certs.is_empty() {
                tracing::info!("Unauthenticated TLS from {} → H2 fallback", remote);
                handle_fallback_h2(tls_stream, remote).await;
                return;
            }

            // Fingerprint allowlist check
            let client_fp = vpn_session::cert_fingerprint(peer_certs[0].as_ref());
            {
                let allowed = allow_list.read().await;
                if !allowed.is_empty() && !allowed.contains(&client_fp) {
                    tracing::warn!("Client {} rejected: fp={}…", remote, &client_fp[..16]);
                    return;
                }
            }

            // ─── Read stream_idx byte (new in v0.17 wire protocol) ────────────
            let (mut tls_read, mut tls_write) = tokio::io::split(tls_stream);
            let mut idx_buf = [0u8; 1];
            if let Err(e) = tls_read.read_exact(&mut idx_buf).await {
                tracing::warn!("stream_idx read failed from {} ({}): {}", remote, &client_fp[..16], e);
                return;
            }
            let stream_idx = idx_buf[0] as usize;
            if stream_idx >= N_STREAMS {
                tracing::warn!(
                    "Invalid stream_idx {} from {} (fp={}…, max={})",
                    stream_idx, remote, &client_fp[..16], N_STREAMS
                );
                return;
            }

            tracing::info!(
                "Authenticated VPN client from {} (fp={}…, stream {}/{})",
                remote, &client_fp[..16], stream_idx, N_STREAMS
            );

            // ─── Lookup or create SessionCoordinator by fingerprint ──────────
            let (session, is_new) = {
                if let Some(existing) = sessions_by_fp.get(&client_fp) {
                    (existing.value().clone(), false)
                } else {
                    // Create a fresh coordinator
                    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Bytes>(2048);
                    let (close_tx, close_rx) = tokio::sync::oneshot::channel::<()>();
                    let sess = Arc::new(VpnSession::new_coordinator(
                        client_fp.clone(),
                        tun_pkt_tx,
                        close_tx,
                    ));

                    // Atomic insert: lose the race → use the winner's session.
                    let session = match sessions_by_fp.entry(client_fp.clone()) {
                        dashmap::mapref::entry::Entry::Occupied(o) => o.get().clone(),
                        dashmap::mapref::entry::Entry::Vacant(v) => {
                            v.insert(sess.clone());
                            // Start batcher + close watcher for this newly created session.
                            tokio::spawn(vpn_session::session_batch_loop(
                                tun_pkt_rx, sess.clone(),
                            ));
                            {
                                // Nothing QUIC-like to close; drain close_rx so channel drops.
                                tokio::spawn(async move {
                                    let _ = close_rx.await;
                                });
                            }
                            sess.clone()
                        }
                    };
                    (session, true)
                }
            };
            let _ = is_new;

            // ─── Per-stream frame channel, attach into slot[stream_idx] ─────
            let (frame_tx, frame_rx) = mpsc::channel::<Bytes>(512);
            let replaced = session.attach_stream(stream_idx, frame_tx.clone());
            if replaced.is_some() {
                tracing::warn!(
                    "stream {} for fp={}… replaced by reconnect from {}",
                    stream_idx, &client_fp[..16], remote
                );
            }

            // Writer: frame channel → TLS write half
            let session_for_writer = session.clone();
            let sessions_for_reap = sessions.clone();
            let sessions_by_fp_for_reap = sessions_by_fp.clone();
            let frame_tx_for_detach = frame_tx.clone();
            tokio::spawn(async move {
                tls_write_loop(frame_rx, &mut tls_write, remote).await;
                // Clear our slot
                session_for_writer.detach_stream_if(stream_idx, &frame_tx_for_detach);
                // If every stream is down, reap the coordinator from both maps.
                if session_for_writer.all_streams_down() {
                    vpn_session::reap_session_fp(&sessions_by_fp_for_reap, &session_for_writer);
                    // Best-effort remove from tun-ip map too
                    let mut victims: Vec<IpAddr> = Vec::new();
                    for entry in sessions_for_reap.iter() {
                        if Arc::ptr_eq(entry.value(), &session_for_writer) {
                            victims.push(*entry.key());
                        }
                    }
                    for ip in victims {
                        let _ = sessions_for_reap.remove_if(
                            &ip,
                            |_, v| Arc::ptr_eq(v, &session_for_writer),
                        );
                    }
                    tracing::info!(
                        "Session reaped: fp={}… (all streams down)",
                        &session_for_writer.fingerprint[..16.min(session_for_writer.fingerprint.len())]
                    );
                }
            });

            // ─── RX loop (this TCP stream) ───────────────────────────────────
            let registered_ip: Arc<Mutex<Option<IpAddr>>> = Arc::new(Mutex::new(None));
            let _ = tls_rx_loop(
                tls_read,
                session.clone(),
                tun_tx,
                sessions.clone(),
                registered_ip,
                tun_network,
                tun_prefix,
                remote,
                stream_idx,
            ).await;

            // RX loop exited → drop frame_tx for this slot so the writer task
            // also unwinds (detach + reap handled in the writer task above).
            drop(frame_tx);
        });
    }
}

/// TLS RX loop: read [4B len][batch] → extract packets → TUN.
/// Zero-copy: parse directly out of a BytesMut pool, emit each packet as `Bytes`.
async fn tls_rx_loop<R: AsyncReadExt + Unpin>(
    mut reader: R,
    session: Arc<VpnSession>,
    tun_tx: mpsc::Sender<Bytes>,
    sessions: VpnSessionMap,
    registered_ip: Arc<Mutex<Option<IpAddr>>>,
    tun_network: Ipv4Addr,
    tun_prefix: u8,
    remote: SocketAddr,
    stream_idx: usize,
) -> anyhow::Result<()> {
    let mut len_buf = [0u8; 4];
    // Pre-allocated BytesMut pool (128 KB) — we split_to(frame_len) per frame
    // to mint zero-copy Bytes, then replenish when capacity runs low.
    let buf_reserve = 128 * 1024;
    let mut buf = BytesMut::with_capacity(buf_reserve);

    loop {
        // Read frame header
        if reader.read_exact(&mut len_buf).await.is_err() {
            break; // connection closed
        }
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len > BATCH_MAX_PLAINTEXT {
            tracing::warn!("Oversized frame {} from {} (stream {})", frame_len, remote, stream_idx);
            break;
        }

        // Ensure capacity for this frame.
        if buf.capacity() < frame_len {
            buf.reserve(frame_len.max(buf_reserve) - buf.len());
        }
        // Grow so we can read_exact into &mut [u8].
        let old_len = buf.len();
        buf.resize(old_len + frame_len, 0);
        if reader.read_exact(&mut buf[old_len..old_len + frame_len]).await.is_err() {
            break;
        }

        session.bytes_rx.fetch_add((4 + frame_len) as u64, Ordering::Relaxed);
        session.touch();

        // Zero-copy: split the frame bytes out of the pool.
        // `frame` is an owned Bytes sharing the underlying BytesMut allocation.
        let mut frame: Bytes = {
            // split_off at old_len to leave unread prefix (none at old_len==0)
            // We built frame at [old_len .. old_len+frame_len]; the only content
            // in the buffer right now IS that frame (old_len was 0 or the tail
            // of a previous frame already consumed). Ensure old_len is 0.
            debug_assert_eq!(old_len, 0);
            let _ = old_len;
            buf.split_to(frame_len).freeze()
        };

        // Parse batch walking `frame` — each pkt is a zero-copy slice.
        let registered_already = registered_ip.lock().await.is_some();
        let mut registered = registered_already;

        while frame.len() >= 2 {
            let pkt_len = u16::from_be_bytes([frame[0], frame[1]]) as usize;
            // Consume the 2-byte length prefix.
            let _ = frame.split_to(2);
            if pkt_len == 0 { break; }
            if frame.len() < pkt_len { break; }

            let mut pkt = frame.split_to(pkt_len);

            if pkt_len < 20 { continue; }

            // Register session on first IPv4 packet
            if !registered && (pkt[0] >> 4) == 4 {
                let src_v4 = Ipv4Addr::new(pkt[12], pkt[13], pkt[14], pkt[15]);
                let mask: u32 = if tun_prefix == 0 { 0 } else { !0u32 << (32 - tun_prefix) };
                if u32::from(src_v4) & mask == u32::from(tun_network) & mask {
                    let src_ip = IpAddr::V4(src_v4);
                    let replaced = vpn_session::register_session_ip(
                        &sessions, src_ip, session.clone(),
                    );
                    *registered_ip.lock().await = Some(src_ip);
                    registered = true;
                    if replaced {
                        tracing::warn!("Session replaced for tunnel IP {} ({})", src_ip, remote);
                    } else {
                        tracing::info!(
                            "Session registered for tunnel IP {} ({}, stream {})",
                            src_ip, remote, stream_idx
                        );
                    }
                }
            }

            // MSS clamp needs mutable access → make the Bytes unique (cheap: refcount=1 here).
            // split_to returns refcount=1 since we own the whole pool; we can reclaim as BytesMut.
            let mut pkt_mut: BytesMut = match pkt.try_into_mut() {
                Ok(bm) => bm,
                Err(b) => {
                    // Fallback: copy.
                    pkt = b;
                    let mut bm = BytesMut::with_capacity(pkt.len());
                    bm.extend_from_slice(&pkt);
                    bm
                }
            };
            let _ = clamp_tcp_mss(&mut pkt_mut, QUIC_TUNNEL_MSS);
            let pkt_bytes: Bytes = pkt_mut.freeze();

            // Log destination (sampled every 64th packet)
            if pkt_bytes.len() >= 20 && (pkt_bytes[0] >> 4) == 4
                && session.log_counter.fetch_add(1, Ordering::Relaxed) % 64 == 0
            {
                let proto = pkt_bytes[9];
                let dst_ip = Ipv4Addr::new(pkt_bytes[16], pkt_bytes[17], pkt_bytes[18], pkt_bytes[19]);
                let ihl = ((pkt_bytes[0] & 0x0F) as usize) * 4;
                let dst_port = if (proto == 6 || proto == 17) && ihl + 4 <= pkt_bytes.len() {
                    u16::from_be_bytes([pkt_bytes[ihl + 2], pkt_bytes[ihl + 3]])
                } else {
                    0
                };
                let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
                let dst_host = session.dns_cache.get(&dst_ip).map(|v| v.clone());
                if let Ok(mut log) = session.dest_log.lock() {
                    if log.len() >= 1000 { log.pop_front(); }
                    log.push_back(DestEntry { ts, dst_ip, dst_host, dst_port, proto, bytes: pkt_bytes.len() as u32 });
                }
            }

            if tun_tx.send(pkt_bytes).await.is_err() {
                return Ok(());
            }
        }

        // Drop what remains of this frame (padding, trailing bytes).
        drop(frame);
        // Reset the pool for the next iteration.
        buf.clear();
        if buf.capacity() < buf_reserve {
            buf.reserve(buf_reserve - buf.capacity());
        }
    }

    Ok(())
}

/// TLS write loop: drain Bytes from channel → write to TLS stream.
async fn tls_write_loop<W: AsyncWriteExt + Unpin>(
    mut frame_rx: mpsc::Receiver<Bytes>,
    writer: &mut W,
    remote: SocketAddr,
) {
    while let Some(frame) = frame_rx.recv().await {
        if writer.write_all(&frame).await.is_err() {
            tracing::debug!("TLS write to {} failed", remote);
            break;
        }
        // Drain queued frames before flushing
        for _ in 0..31 {
            match frame_rx.try_recv() {
                Ok(frame) => {
                    if writer.write_all(&frame).await.is_err() {
                        return;
                    }
                }
                Err(_) => break,
            }
        }
        if writer.flush().await.is_err() {
            tracing::debug!("TLS flush to {} failed", remote);
            break;
        }
    }
    tracing::debug!("TLS write loop ended for {}", remote);
}

/// Fallback handler for unauthenticated connections.
/// Performs HTTP/2 handshake and serves a static page — makes probes see a real website.
pub async fn handle_fallback_h2<S>(stream: S, remote: SocketAddr)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let mut h2_conn = match h2::server::Builder::default().handshake(stream).await {
        Ok(c) => c,
        Err(e) => {
            tracing::debug!("Fallback H2 handshake failed from {}: {}", remote, e);
            return;
        }
    };

    loop {
        let accept_result = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            poll_fn(|cx: &mut std::task::Context<'_>| h2_conn.poll_accept(cx)),
        ).await;

        match accept_result {
            Ok(poll_outcome) => match poll_outcome {
                Some(Ok((req, mut send))) => {
                    let mut body = req.into_body();
                    while body.data().await.is_some() {}

                    let response = http::Response::builder()
                        .status(200)
                        .header("content-type", "text/html; charset=utf-8")
                        .body(())
                        .unwrap();

                    let mut send = match send.send_response(response, false) {
                        Ok(s) => s,
                        Err(_) => break,
                    };
                    let html = "<html><body><h1>nl2.bikini-bottom.com</h1><p>Service is running.</p></body></html>";
                    let _ = send.send_data(Bytes::copy_from_slice(html.as_bytes()), true);
                }
                Some(Err(_)) | None => break,
            },
            Err(_) => break,
        }
    }

    tracing::debug!("Fallback H2 connection from {} ended", remote);
}

// Silence unused-variable warning.
#[allow(dead_code)]
fn _unused_atomic_placeholder(_: AtomicU64) {}
