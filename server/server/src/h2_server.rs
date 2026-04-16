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
use std::sync::atomic::Ordering;
use std::time::{SystemTime, UNIX_EPOCH};

use bytes::{Bytes, BytesMut};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    mtu::clamp_tcp_mss,
    wire::{
        build_heartbeat_frame, first_heartbeat_delay, next_heartbeat_delay,
        BATCH_MAX_PLAINTEXT, MAX_N_STREAMS, MIN_N_STREAMS, QUIC_TUNNEL_MSS,
    },
};

use crate::fakeapp;
use crate::mimicry;

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
                tracing::info!("Unauthenticated TLS from {} → fake app-face", remote);
                fakeapp::handle(tls_stream, remote).await;
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

            // ─── Read handshake: [stream_idx, client_max_streams] (v0.18+) ────
            // v0.18 clients atomically write both bytes in write_handshake().
            // Earlier prototype used a 200ms timeout after the first byte to
            // stay compatible with v0.17 one-byte handshake, but that window
            // could fire spuriously on high-latency paths (RU-bastion hop) and
            // pin effective_n to the server's core count, permanently freezing
            // the session below the client's requested parallelism. Read both
            // bytes with a single read_exact — if the client really is v0.17
            // (none in the wild) it'll disconnect and we'll error naturally.
            let (mut tls_read, mut tls_write) = tokio::io::split(tls_stream);
            let mut hs_buf = [0u8; 2];
            if let Err(e) = tls_read.read_exact(&mut hs_buf).await {
                tracing::warn!(
                    "handshake read failed from {} ({}…): {}",
                    remote, &client_fp[..16], e
                );
                return;
            }
            let stream_idx = hs_buf[0] as usize;
            let client_max: usize = (hs_buf[1] as usize).clamp(MIN_N_STREAMS, MAX_N_STREAMS);
            // Honor the client's request. Client picks parallelism based on its
            // own core count (phone = 8, desktop = 16, ...); server-side cost of
            // extra streams is just more mpsc channels + tokio tasks, which are
            // cheap regardless of the server's physical core count. Clamped so a
            // misbehaving client can't push beyond MAX_N_STREAMS.
            let effective_n = client_max.clamp(MIN_N_STREAMS, MAX_N_STREAMS);

            if stream_idx >= effective_n {
                tracing::warn!(
                    "Invalid stream_idx {} from {} (fp={}…, effective_n={})",
                    stream_idx, remote, &client_fp[..16], effective_n
                );
                return;
            }

            tracing::info!(
                "Authenticated VPN client from {} (fp={}…, stream {}/{})",
                remote, &client_fp[..16], stream_idx, effective_n
            );

            // ─── Lookup or create SessionCoordinator by fingerprint ──────────
            // If a stale session exists whose `effective_n` is smaller than
            // the client's newly-requested `client_max` (or whose batch_loops
            // may have been torn down by an earlier cleanup-task close()), we
            // evict it before falling through to the Vacant path so a fresh
            // coordinator is built. This fixes two v0.18 post-ship bugs:
            //   1) Bastion path pinned to effective_n=2 forever because the
            //      initial handshake timed out the 200ms fallback window and
            //      rejected stream_idx>=2 on every reconnect.
            //   2) NL-direct zombie sessions where cleanup_task had removed
            //      the IP mapping and close()'d the coordinator (which drops
            //      all tun_pkt_txs so every `stream_batch_loop` exits), but
            //      left the entry in `sessions_by_fp` — a subsequent reconnect
            //      found the corpse, attached fresh writers, but had no
            //      batching task alive to feed them → download = 0.
            let stale_session = sessions_by_fp.get(&client_fp).map(|e| e.value().clone());
            if let Some(ref old) = stale_session {
                let need_wider   = client_max != old.effective_n;
                let idx_out      = stream_idx >= old.effective_n;
                let dead_batches = old.all_streams_down()
                    && old.tun_pkt_txs.lock().map(|g| g.iter().all(|s| s.is_none())).unwrap_or(true);
                if need_wider || idx_out || dead_batches {
                    tracing::warn!(
                        "Evicting stale session fp={}… (old_n={}, new_n={}, idx={}, dead={})",
                        &client_fp[..16], old.effective_n, client_max, stream_idx, dead_batches
                    );
                    // Remove from both maps and close the coordinator. close()
                    // drops all per-stream TUN senders → any remaining batch
                    // loops wake up with pkt_rx=None and exit, any live writer
                    // drops its TLS half → TCP FIN.
                    sessions_by_fp.remove_if(&client_fp, |_, v| Arc::ptr_eq(v, old));
                    let mut victims: Vec<IpAddr> = Vec::new();
                    for entry in sessions.iter() {
                        if Arc::ptr_eq(entry.value(), old) {
                            victims.push(*entry.key());
                        }
                    }
                    for ip in victims {
                        let _ = sessions.remove_if(&ip, |_, v| Arc::ptr_eq(v, old));
                    }
                    old.close();
                }
            }
            drop(stale_session);

            let (session, is_new) = {
                if let Some(existing) = sessions_by_fp.get(&client_fp) {
                    // Reject stream_idx outside this session's effective_n.
                    // With eviction above this branch is hit only when the
                    // entry survived eviction (concurrent races are benign).
                    let existing_session = existing.value().clone();
                    if stream_idx >= existing_session.effective_n {
                        tracing::warn!(
                            "stream_idx {} exceeds existing session effective_n={} (fp={}…)",
                            stream_idx, existing_session.effective_n, &client_fp[..16]
                        );
                        return;
                    }
                    (existing_session, false)
                } else {
                    // Create a fresh coordinator with `effective_n` per-stream channels.
                    let mut pkt_txs: Vec<mpsc::Sender<Bytes>> = Vec::with_capacity(effective_n);
                    let mut pkt_rxs: Vec<mpsc::Receiver<Bytes>> = Vec::with_capacity(effective_n);
                    for _ in 0..effective_n {
                        // Per-stream depth 1024 → effective_n × 1024 total.
                        let (tx, rx) = mpsc::channel::<Bytes>(1024);
                        pkt_txs.push(tx);
                        pkt_rxs.push(rx);
                    }
                    let (close_tx, close_rx) = tokio::sync::oneshot::channel::<()>();
                    let sess = Arc::new(VpnSession::new_coordinator(
                        client_fp.clone(),
                        effective_n,
                        pkt_txs,
                        close_tx,
                    ));

                    // Atomic insert: lose the race → use the winner's session.
                    let session = match sessions_by_fp.entry(client_fp.clone()) {
                        dashmap::mapref::entry::Entry::Occupied(o) => o.get().clone(),
                        dashmap::mapref::entry::Entry::Vacant(v) => {
                            v.insert(sess.clone());
                            // Start one batcher per stream_idx for this newly created session.
                            for (idx, rx) in pkt_rxs.into_iter().enumerate() {
                                tokio::spawn(vpn_session::stream_batch_loop(
                                    rx, sess.clone(), idx,
                                ));
                            }
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
            //
            // IMPORTANT: move frame_tx into the slot (no clone kept outside).
            // An earlier revision held a `frame_tx_for_detach = frame_tx.clone()`
            // inside the writer's spawn closure so it could call
            // `detach_stream_if(same_channel)` after the loop. That clone kept
            // the channel's sender-side alive, which meant `frame_rx.recv()`
            // never returned `None` — the writer task could only exit on a
            // TLS write error. If no TX traffic flowed through a freshly-
            // attached (but stale-session) writer, it would park forever and
            // prevent reap. Use generation tokens instead.
            let (frame_tx, frame_rx) = mpsc::channel::<Bytes>(512);
            let attach_gen = session.attach_stream(stream_idx, frame_tx);

            // Writer: frame channel → TLS write half.
            // Only stream 0 runs the mimicry warmup. Other streams skip it —
            // we don't want N parallel warmups burning CPU in first 5 seconds.
            let run_warmup = stream_idx == 0 && is_new;
            let session_for_writer = session.clone();
            let sessions_for_reap = sessions.clone();
            let sessions_by_fp_for_reap = sessions_by_fp.clone();
            let client_fp_for_writer = client_fp.clone();
            tokio::spawn(async move {
                if run_warmup {
                    if let Err(e) = mimicry::warmup_write(&mut tls_write).await {
                        tracing::debug!("mimicry warmup failed for {}: {}", remote, e);
                    }
                }
                tls_write_loop(frame_rx, &mut tls_write, remote).await;
                // Clear our slot ONLY if no newer reconnect overwrote it.
                session_for_writer.detach_stream_gen(stream_idx, attach_gen);
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
                        &client_fp_for_writer[..16.min(client_fp_for_writer.len())]
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

            // RX loop exited (client TCP FIN, read error, or EOF). Clear our
            // slot — this drops the Sender, which in turn makes the writer's
            // frame_rx.recv() return None so the writer task unwinds. The
            // generation check is idempotent with the writer's own detach.
            session.detach_stream_gen(stream_idx, attach_gen);
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

            if pkt_len < 20 || (pkt[0] >> 4) != 4 { continue; }

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
                let dst_host = session.dns_lookup(&dst_ip);
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
/// Emits a dummy heartbeat frame if no real traffic has flowed for
/// `next_heartbeat_delay()` (randomized ~20s) — keeps the TCP/TLS channel
/// alive and traffic-shaped even during idle periods.
async fn tls_write_loop<W: AsyncWriteExt + Unpin>(
    mut frame_rx: mpsc::Receiver<Bytes>,
    writer: &mut W,
    remote: SocketAddr,
) {
    let mut next_heartbeat = tokio::time::Instant::now() + first_heartbeat_delay();
    loop {
        tokio::select! {
            biased;
            maybe_frame = frame_rx.recv() => {
                let Some(frame) = maybe_frame else { break; };
                if writer.write_all(&frame).await.is_err() {
                    tracing::debug!("TLS write to {} failed", remote);
                    break;
                }
                // Drain queued frames before flushing
                let mut write_err = false;
                for _ in 0..31 {
                    match frame_rx.try_recv() {
                        Ok(frame) => {
                            if writer.write_all(&frame).await.is_err() {
                                write_err = true;
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                if write_err {
                    return;
                }
                if writer.flush().await.is_err() {
                    tracing::debug!("TLS flush to {} failed", remote);
                    break;
                }
                // Real traffic just flowed → push heartbeat deadline forward.
                next_heartbeat = tokio::time::Instant::now() + next_heartbeat_delay();
            }
            _ = tokio::time::sleep_until(next_heartbeat) => {
                let hb = build_heartbeat_frame();
                tracing::trace!("heartbeat fire → {}", remote);
                if writer.write_all(&hb).await.is_err() {
                    tracing::debug!("TLS heartbeat write to {} failed", remote);
                    break;
                }
                if writer.flush().await.is_err() {
                    tracing::debug!("TLS heartbeat flush to {} failed", remote);
                    break;
                }
                next_heartbeat = tokio::time::Instant::now() + next_heartbeat_delay();
            }
        }
    }
    tracing::debug!("TLS write loop ended for {}", remote);
}

// Fallback handler moved to `fakeapp.rs` module.
