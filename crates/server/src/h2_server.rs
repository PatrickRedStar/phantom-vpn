//! HTTP/2 server: TCP/TLS accept loop, h2 tunnel handler.
//! Listens on TCP:443 (alongside QUIC on UDP:8443).

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::task::Context;
use std::time::{SystemTime, UNIX_EPOCH};
use std::sync::atomic::{AtomicU64, Ordering};

use bytes::{Bytes, Buf};
use futures_util::future::poll_fn;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};

use phantom_core::{
    shaper::H264Shaper,
    wire::{BATCH_MAX_PLAINTEXT, N_DATA_STREAMS, QUIC_TUNNEL_MSS},
    mtu::clamp_tcp_mss,
};

use crate::vpn_session::{self, VpnSession, VpnSessionMap, ClientAllowList, DestEntry};

/// HTTP/2 accept loop: TCP → TLS → h2 → tunnel or fallback.
pub async fn run_h2_accept_loop(
    listener: TcpListener,
    tls_acceptor: Arc<rustls::ServerConfig>,
    tun_tx: mpsc::Sender<Vec<u8>>,
    sessions: VpnSessionMap,
    tun_network: Ipv4Addr,
    tun_prefix: u8,
    allow_list: ClientAllowList,
) -> anyhow::Result<()> {
    tracing::info!("HTTP/2 accept loop started on {}", listener.local_addr()?);

    let tls_acceptor = tokio_rustls::TlsAcceptor::from(tls_acceptor);

    loop {
        let (tcp, remote) = listener.accept().await?;
        // TCP_NODELAY: disable Nagle algorithm.
        // Do NOT set SO_RCVBUF/SO_SNDBUF explicitly — disables TCP auto-tuning,
        // caps buffers at rmem_max (~208KB on VPS). Auto-tuning is better.
        let _ = tcp.set_nodelay(true);
        let tun_tx = tun_tx.clone();
        let sessions = sessions.clone();
        let allow_list = allow_list.clone();
        let tls_acceptor = tls_acceptor.clone();

        tokio::spawn(async move {
            tracing::info!("Incoming TCP connection from {}", remote);

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
                tracing::info!("Unauthenticated TLS connection from {} → fallback mode", remote);
                handle_fallback_h2(tls_stream, remote).await;
                return;
            }

            // Fingerprint allowlist check
            let client_fp = vpn_session::cert_fingerprint(peer_certs[0].as_ref());
            {
                let allowed = allow_list.read().await;
                if !allowed.is_empty() && !allowed.contains(&client_fp) {
                    tracing::warn!(
                        "Client {} rejected: fingerprint {}… not in allowlist",
                        remote, &client_fp[..16]
                    );
                    return;
                }
            }

            tracing::info!("Authenticated VPN client from {} (fp={}…)", remote, &client_fp[..16]);

            // HTTP/2 handshake
            let mut h2_conn_builder = h2::server::Builder::default();
            // Moderate windows: 4MB/stream, 16MB connection, 256KB max frame
            // Avoid extreme 16MB values — causes memory pressure on mobile clients
            h2_conn_builder.initial_window_size(4 * 1024 * 1024);
            h2_conn_builder.initial_connection_window_size(16 * 1024 * 1024);
            h2_conn_builder.max_frame_size(256 * 1024);

            let mut h2_conn = match h2_conn_builder.handshake(tls_stream).await {
                Ok(c) => c,
                Err(e) => {
                    tracing::warn!("HTTP/2 handshake failed from {}: {}", remote, e);
                    return;
                }
            };

            // Accept 8 data streams: POST /v1/tunnel/{0..7}
            let mut frame_txs: Vec<mpsc::Sender<Bytes>> = Vec::with_capacity(N_DATA_STREAMS);
            let mut data_recvs: Vec<h2::RecvStream> = Vec::with_capacity(N_DATA_STREAMS);

            for i in 0..N_DATA_STREAMS {
                // Use poll_fn to wrap h2_conn.accept() which requires Pin+Context
                let accept_result = tokio::time::timeout(
                    std::time::Duration::from_secs(10),
                    poll_fn(|cx: &mut Context<'_>| h2_conn.poll_accept(cx)),
                ).await;

                // poll_accept() returns: Poll<Option<Result<(Request, SendResponse), Error>>>
                // timeout wraps: Poll<Result<...>, Elapsed>
                let (req, mut send) = match accept_result {
                    Ok(poll_outcome) => match poll_outcome {
                        Some(Ok((req, send))) => (req, send),
                        Some(Err(e)) => {
                            tracing::warn!("Failed to accept HTTP/2 stream {}: {}", i, e);
                            return;
                        }
                        None => {
                            tracing::warn!("HTTP/2 stream {} closed by peer", i);
                            return;
                        }
                    },
                    Err(_) => {
                        tracing::warn!("Timeout accepting HTTP/2 stream {}", i);
                        return;
                    }
                };

                let path = req.uri().path();
                if !path.starts_with("/v1/tunnel/") {
                    tracing::warn!("Invalid stream path: {}", path);
                    return;
                }
                // Respond 200 OK
                let response = http::Response::builder()
                    .status(200)
                    .body(())
                    .unwrap();
                let send_resp = match send.send_response(response, false) {
                    Ok(s) => s,
                    Err(e) => {
                        tracing::warn!("Failed to send response: {}", e);
                        return;
                    }
                };
                let recv = req.into_body();
                let (frame_tx, frame_rx) = mpsc::channel::<Bytes>(512);
                tokio::spawn(h2_stream_write_loop(frame_rx, send_resp, remote));
                frame_txs.push(frame_tx);
                data_recvs.push(recv);
            }

            tracing::debug!("{} HTTP/2 streams accepted from {}", N_DATA_STREAMS, remote);

            // Per-session TUN packet channel + batching task
            let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(2048);

            // Transport-agnostic shutdown
            let (close_tx, close_rx) = tokio::sync::oneshot::channel::<()>();

            let session = Arc::new(VpnSession {
                data_sends: frame_txs,
                tun_pkt_tx,
                close_tx: std::sync::Mutex::new(Some(close_tx)),
                last_seen: AtomicU64::new(
                    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs(),
                ),
                bytes_rx: AtomicU64::new(0),
                bytes_tx: AtomicU64::new(0),
                dest_log: std::sync::Mutex::new(std::collections::VecDeque::new()),
                stats_samples: std::sync::Mutex::new(std::collections::VecDeque::new()),
                dns_cache: dashmap::DashMap::new(),
                log_counter: AtomicU64::new(0),
            });

            // Background: wait for close signal → close TCP connection (drop TLS)
            {
                tokio::spawn(async move {
                    let _ = close_rx.await;
                    // TLS stream is dropped when this task exits
                });
            }

            // Spawn per-session batching task
            let shaper = match H264Shaper::new() {
                Ok(s) => s,
                Err(e) => {
                    tracing::warn!("Failed to create shaper: {}", e);
                    return;
                }
            };
            tokio::spawn(vpn_session::session_batch_loop(tun_pkt_rx, session.clone(), shaper, false));

            // Run N stream RX loops + h2 connection driver concurrently.
            // CRITICAL: h2_conn MUST be polled continuously — it is the sole I/O
            // driver that reads DATA frames from TCP into RecvStream buffers and
            // flushes SendStream buffers to TCP.  Without this, all streams stall.
            let registered_ip: Arc<Mutex<Option<IpAddr>>> = Arc::new(Mutex::new(None));
            let reg_ip_clone = registered_ip.clone();
            let sessions_clone = sessions.clone();

            let mut set = tokio::task::JoinSet::new();

            // Spawn h2 connection driver (drives all I/O for the lifetime of the connection)
            set.spawn(async move {
                if let Err(e) = poll_fn(|cx: &mut Context<'_>| h2_conn.poll_closed(cx)).await {
                    tracing::debug!("HTTP/2 connection driver error: {}", e);
                }
                Ok(())
            });

            for data_recv in data_recvs {
                set.spawn(h2_stream_rx_loop(
                    data_recv,
                    session.clone(),
                    tun_tx.clone(),
                    sessions.clone(),
                    registered_ip.clone(),
                    tun_network,
                    tun_prefix,
                    remote,
                ));
            }

            while set.join_next().await.is_some() {}

            // Cleanup — drop MutexGuard before block end
            {
                let ip = reg_ip_clone.lock().await.take();
                if let Some(ip) = ip {
                    if sessions_clone.remove_if(&ip, |_, v| Arc::ptr_eq(v, &session)).is_some() {
                        tracing::info!("H2 session unregistered for tunnel IP {} ({})", ip, remote);
                    } else {
                        tracing::debug!("H2 session for {} ({}) already replaced, skip remove", ip, remote);
                    }
                }
            }
        });
    }
}

/// HTTP/2 stream RX loop: DATA frames → TUN
async fn h2_stream_rx_loop(
    mut recv: h2::RecvStream,
    session: Arc<VpnSession>,
    tun_tx: mpsc::Sender<Vec<u8>>,
    sessions: VpnSessionMap,
    registered_ip: Arc<Mutex<Option<IpAddr>>>,
    tun_network: Ipv4Addr,
    tun_prefix: u8,
    remote: SocketAddr,
) -> anyhow::Result<()> {
    let buf_size = BATCH_MAX_PLAINTEXT + 16;
    let mut frame_buf = vec![0u8; buf_size];
    let mut chunk_buf = bytes::BytesMut::with_capacity(buf_size);
    let mut registered = registered_ip.lock().await.is_some();

    loop {
        // Read DATA frame chunk
        let chunk = match recv.data().await {
            Some(Ok(c)) => c,
            Some(Err(e)) => {
                tracing::debug!("H2 stream {} data error: {}", remote, e);
                break;
            }
            None => break, // EOS
        };

        // Release flow control
        let len = chunk.len();
        if let Err(e) = recv.flow_control().release_capacity(len) {
            tracing::debug!("Flow control error: {}", e);
            break;
        }

        session.bytes_rx.fetch_add(len as u64, Ordering::Relaxed);
        session.touch();

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
                if pkt_len < 20 { offset += pkt_len; continue; }

                // Register session on first IPv4 packet
                if !registered && (chunk_buf[offset] >> 4) == 4 {
                    let src_v4 = Ipv4Addr::new(
                        chunk_buf[offset + 12], chunk_buf[offset + 13],
                        chunk_buf[offset + 14], chunk_buf[offset + 15],
                    );
                    let mask: u32 = if tun_prefix == 0 { 0 } else { !0u32 << (32 - tun_prefix) };
                    if u32::from(src_v4) & mask == u32::from(tun_network) & mask {
                        let src_ip = IpAddr::V4(src_v4);
                        sessions.insert(src_ip, session.clone());
                        *registered_ip.lock().await = Some(src_ip);
                        registered = true;
                        tracing::info!("H2 session registered for tunnel IP {} ({})", src_ip, remote);
                    }
                }

                let mut pkt = chunk_buf[offset..offset + pkt_len].to_vec();
                let _ = clamp_tcp_mss(&mut pkt, QUIC_TUNNEL_MSS);

                // Log destination (sampled)
                if pkt_len >= 20 && (pkt[0] >> 4) == 4
                    && session.log_counter.fetch_add(1, Ordering::Relaxed) % 64 == 0
                {
                    let proto = pkt[9];
                    let dst_ip = Ipv4Addr::new(pkt[16], pkt[17], pkt[18], pkt[19]);
                    let ihl = ((pkt[0] & 0x0F) as usize) * 4;
                    let dst_port = if (proto == 6 || proto == 17) && ihl + 4 <= pkt.len() {
                        u16::from_be_bytes([pkt[ihl + 2], pkt[ihl + 3]])
                    } else {
                        0
                    };
                    let ts = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs();
                    let dst_host = session.dns_cache.get(&dst_ip).map(|v| v.clone());
                    if let Ok(mut log) = session.dest_log.lock() {
                        if log.len() >= 1000 { log.pop_front(); }
                        log.push_back(DestEntry { ts, dst_ip, dst_host, dst_port, proto, bytes: pkt_len as u32 });
                    }
                }

                if let Err(e) = tun_tx.send(pkt).await {
                    tracing::error!("tun_tx send error: {}", e);
                    break;
                }
                offset += pkt_len;
            }

            // Consume frame from buffer
            chunk_buf.advance(batch_end);
        }
    }

    Ok(())
}

/// HTTP/2 stream write loop: Bytes → DATA frames
async fn h2_stream_write_loop(
    mut frame_rx: mpsc::Receiver<Bytes>,
    mut send: h2::SendStream<Bytes>,
    remote: SocketAddr,
) {
    while let Some(frame) = frame_rx.recv().await {
        if let Err(e) = send.send_data(frame, false) {
            tracing::warn!("H2 stream write to {} failed: {}", remote, e);
            break;
        }
        // Drain additional queued frames before yielding to tokio scheduler
        // Reduces context-switch overhead under sustained load
        for _ in 0..15 {
            match frame_rx.try_recv() {
                Ok(frame) => {
                    if let Err(e) = send.send_data(frame, false) {
                        tracing::warn!("H2 stream write to {} failed: {}", remote, e);
                        return;
                    }
                }
                Err(_) => break,
            }
        }
    }
    let _ = send.send_data(Bytes::new(), true); // EOS
    tracing::debug!("H2 stream write loop ended for {}", remote);
}

/// Fallback handler for unauthenticated HTTP/2 connections.
/// Serves a static HTML page to mimic a real website.
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
        // Use poll_fn to wrap poll_accept
        let accept_result = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            poll_fn(|cx: &mut Context<'_>| h2_conn.poll_accept(cx)),
        ).await;

        // poll_accept() returns: Poll<Option<Result<(Request, SendResponse), Error>>>
        match accept_result {
            Ok(poll_outcome) => match poll_outcome {
                Some(Ok((req, mut send))) => {
                    // Read and discard request body
                    let mut body = req.into_body();
                    while let Some(_) = body.data().await {}

                    // Send 200 OK with static HTML
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
            Err(_) => break, // timeout
        }
    }

    tracing::debug!("Fallback H2 connection from {} ended", remote);
}
