//! TLS server: TCP/TLS accept loop with multi-stream SessionCoordinator.
//!
//! Wire protocol:
//! 1. TCP accept
//! 2. mTLS handshake (client cert validated against allowlist; revoked or
//!    unknown cert → TLS alert `certificate_revoked`)
//! 3. Client writes 2 bytes: `stream_idx` ∈ [0, N_STREAMS), `client_max_streams`
//! 4. Frame loop: [4B frame_len u32 BE][batch: (2B pktlen)(ip_pkt)...(2B 0x0000)]
//!
//! Up to `N_STREAMS` parallel TCP connections per client fingerprint are
//! aggregated via `VpnSession` (SessionCoordinator). Each physical connection
//! claims one slot; TUN→client frames are dispatched across slots via
//! round-robin. When all slots become empty the session is reaped.

use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use bytes::{BufMut, Bytes, BytesMut};
use rand::Rng;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, UnixTime};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{CertificateError, DigitallySignedStruct, DistinguishedName, SignatureScheme};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc;

use phantom_core::{
    mtu::clamp_tcp_mss,
    wire::{
        batch_packets, build_heartbeat_frame,
        BATCH_MAX_PLAINTEXT, MAX_N_STREAMS, MIN_N_STREAMS, QUIC_TUNNEL_MSS,
    },
};

use crate::fakeapp;

use crate::vpn_session::{
    self, ClientAllowList, DestEntry, SessionByFp, VpnSession, VpnSessionMap,
};

/// TLS handshake + 2-byte stream header must finish within this window.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// No frame (data or heartbeat) from the client for this long → the stream is
/// dead. Clients heartbeat every 30–60 s per stream.
const STREAM_IDLE_TIMEOUT: Duration = Duration::from_secs(150);
/// How long the writer waits for close_notify + FIN to go out.
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
/// Per-stream heartbeat interval, drawn independently per stream (never in
/// sync across streams — that would be a DPI tell). Must stay well below the
/// client's 75 s "stale" threshold. Capped at 40 s while v0.24–v0.26 clients
/// are around: they drop a stream after 45 s without a frame (raise to 60 s
/// once they are gone).
const HEARTBEAT_MIN_SECS: u64 = 30;
const HEARTBEAT_MAX_SECS: u64 = 40;
/// The first frames of every stream are padded to a random size so the
/// stream start doesn't mirror IP packet sizes. Receivers ignore everything
/// after the batch terminator, so the wire format is unchanged.
const PAD_FIRST_FRAMES: std::ops::RangeInclusive<u32> = 10..=20;
const PAD_TARGET: std::ops::RangeInclusive<usize> = 256..=1400;
/// Per-stream queue of ready frames (≤ ~54 KB each). Small on purpose: deep
/// queues only add latency under load; backpressure goes to the TUN dispatcher.
const FRAME_QUEUE: usize = 32;
/// TCP_NOTSENT_LOWAT for stream sockets: keep at most this much unsent data in
/// the kernel so queued bytes don't turn into seconds of delay.
#[cfg(target_os = "linux")]
const NOTSENT_LOWAT: libc::c_int = 128 * 1024;

/// Build the transport TLS config: optional mTLS against our CA (a client
/// without a cert gets the fake app-face); the client cert is checked against
/// the allowlist inside the handshake (revoked → alert, the client can tell
/// "access revoked" from a network failure), and the CA name list is not sent
/// in CertificateRequest (it would name our CA to any prober; rustls clients
/// send their only cert anyway).
pub fn make_tls_config(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
    client_ca: Option<Vec<CertificateDer<'static>>>,
    allow_list: ClientAllowList,
) -> anyhow::Result<Arc<rustls::ServerConfig>> {
    let builder = rustls::ServerConfig::builder();
    let mut cfg = match client_ca {
        Some(ca_certs) => {
            let mut roots = rustls::RootCertStore::empty();
            for cert in ca_certs {
                roots.add(cert)?;
            }
            let inner = rustls::server::WebPkiClientVerifier::builder(Arc::new(roots))
                .allow_unauthenticated()
                .clear_root_hint_subjects()
                .build()
                .map_err(|e| anyhow::anyhow!("Failed to build client verifier: {}", e))?;
            builder
                .with_client_cert_verifier(Arc::new(AllowListVerifier { inner, allow_list }))
                .with_single_cert(certs, key)?
        }
        None => builder.with_no_client_auth().with_single_cert(certs, key)?,
    };
    // h2 first: our clients offer both and always get h2. http/1.1 is there
    // for probers — with h2 alone they got a no_application_protocol alert,
    // which no nginx in front of a website ever sends.
    cfg.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];
    cfg.max_early_data_size = 0;
    Ok(Arc::new(cfg))
}

/// WebPKI chain check, then the allowlist. No cert at all stays allowed
/// (→ fake app-face), exactly as before.
#[derive(Debug)]
struct AllowListVerifier {
    inner: Arc<dyn ClientCertVerifier>,
    allow_list: ClientAllowList,
}

impl ClientCertVerifier for AllowListVerifier {
    fn offer_client_auth(&self) -> bool {
        self.inner.offer_client_auth()
    }

    fn client_auth_mandatory(&self) -> bool {
        self.inner.client_auth_mandatory()
    }

    fn root_hint_subjects(&self) -> &[DistinguishedName] {
        self.inner.root_hint_subjects()
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        now: UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        self.inner.verify_client_cert(end_entity, intermediates, now)?;
        let fp = vpn_session::cert_fingerprint(end_entity.as_ref());
        if vpn_session::client_access(&self.allow_list, &fp).is_some() {
            Ok(ClientCertVerified::assertion())
        } else {
            tracing::warn!("Client cert rejected in handshake (revoked/unknown): fp={}…", &fp[..16]);
            Err(rustls::Error::InvalidCertificate(CertificateError::Revoked))
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

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
        // Never leave the loop on accept errors (EMFILE, ENOBUFS, …): the
        // process would stay up with nobody listening on the VPN port.
        let (tcp, remote) = match listener.accept().await {
            Ok(x) => x,
            Err(e) => {
                tracing::warn!("TLS accept failed: {}", e);
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        let _ = tcp.set_nodelay(true);
        #[cfg(target_os = "linux")]
        unsafe {
            use std::os::unix::io::AsRawFd;
            let _ = libc::setsockopt(
                tcp.as_raw_fd(),
                libc::IPPROTO_TCP,
                libc::TCP_NOTSENT_LOWAT,
                &NOTSENT_LOWAT as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
        let tun_tx = tun_tx.clone();
        let sessions = sessions.clone();
        let sessions_by_fp = sessions_by_fp.clone();
        let allow_list = allow_list.clone();
        let tls_acceptor = tls_acceptor.clone();

        tokio::spawn(async move {
            tracing::debug!("Incoming TCP connection from {}", remote);

            // TLS handshake + stream header share one deadline, so a silent
            // scanner can't park sockets forever.
            let deadline = tokio::time::Instant::now() + HANDSHAKE_TIMEOUT;
            let tls_stream = match tokio::time::timeout_at(deadline, tls_acceptor.accept(tcp)).await {
                Ok(Ok(s)) => s,
                Ok(Err(e)) => {
                    tracing::warn!("TLS handshake failed from {}: {}", remote, e);
                    return;
                }
                Err(_) => {
                    tracing::debug!("TLS handshake timeout from {}", remote);
                    return;
                }
            };

            // Extract client cert for mTLS
            let peer_certs = tls_stream.get_ref().1.peer_certificates()
                .map(|certs| certs.to_vec())
                .unwrap_or_default();

            // Client fingerprint = identity, derived from the mTLS client cert.
            // No cert ⇒ not a client ⇒ fake app-face. This branch is the only
            // authentication boundary on the transport port.
            //
            // Do NOT reintroduce an escape hatch that assigns an identity without a
            // cert (there used to be a PHANTOM_TEST_CERTLESS_FP env var here). The
            // server TLS config uses `.allow_unauthenticated()` — see
            // `make_tls_config` above — so a certless handshake *does* reach
            // this point, and any such branch is an unauthenticated VPN open to the
            // internet: exit through the NL node, reachability of 10.7.0.0/24 and of
            // the admin API on 10.7.0.1:8080, under a real client's identity.
            // The experiment it served (is mTLS what RU DPI throttles?) is finished —
            // answer is no, see docs/knowledge/architecture/dpi-tspu.md.
            let client_fp = if peer_certs.is_empty() {
                tracing::info!("Unauthenticated TLS from {} → fake app-face", remote);
                if tls_stream.get_ref().1.alpn_protocol() == Some(b"h2") {
                    fakeapp::handle(tls_stream, remote).await;
                } else {
                    fakeapp::handle_http1(tls_stream, remote).await;
                }
                return;
            } else {
                vpn_session::cert_fingerprint(peer_certs[0].as_ref())
            };
            // The verifier already checked the allowlist, but a resumed TLS
            // session skips it — check again here.
            let Some(keyring_ip) = vpn_session::client_access(&allow_list, &client_fp) else {
                tracing::warn!("Client {} rejected: fp={}…", remote, &client_fp[..16]);
                return;
            };

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
            match tokio::time::timeout_at(deadline, tls_read.read_exact(&mut hs_buf)).await {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => {
                    tracing::warn!(
                        "handshake read failed from {} ({}…): {}",
                        remote, &client_fp[..16], e
                    );
                    return;
                }
                Err(_) => {
                    tracing::warn!("handshake read timeout from {} ({}…)", remote, &client_fp[..16]);
                    return;
                }
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
                let dead_batches = old.is_closed() || (old.all_streams_down()
                    && old.tun_pkt_txs.lock().map(|g| g.iter().all(|s| s.is_none())).unwrap_or(true));
                if need_wider || idx_out || dead_batches {
                    tracing::warn!(
                        "Evicting stale session fp={}… (old_n={}, new_n={}, idx={}, dead={})",
                        &client_fp[..16], old.effective_n, client_max, stream_idx, dead_batches
                    );
                    // Remove from both maps and close the coordinator. close()
                    // drops all per-stream TUN senders → any remaining batch
                    // loops wake up with pkt_rx=None and exit, any live writer
                    // shuts its TLS half down → TCP FIN.
                    vpn_session::evict_session(&sessions, &sessions_by_fp, old);
                }
            }
            drop(stale_session);

            let session = {
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
                    existing_session
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
                    match sessions_by_fp.entry(client_fp.clone()) {
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
                    }
                }
            };

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
            let (frame_tx, frame_rx) = mpsc::channel::<Bytes>(FRAME_QUEUE);
            let attach_gen = session.attach_stream(stream_idx, frame_tx);

            // Writer: frame channel → TLS write half.
            let session_for_writer = session.clone();
            let sessions_for_reap = sessions.clone();
            let sessions_by_fp_for_reap = sessions_by_fp.clone();
            let client_fp_for_writer = client_fp.clone();
            tokio::spawn(async move {
                tls_write_loop(frame_rx, &mut tls_write, remote).await;
                // Clear our slot ONLY if no newer reconnect overwrote it.
                session_for_writer.detach_stream_gen(stream_idx, attach_gen);
                // If every stream is down, reap the coordinator from both maps
                // and close it — close() is what lets its batch tasks exit.
                if session_for_writer.all_streams_down() {
                    vpn_session::evict_session(
                        &sessions_for_reap, &sessions_by_fp_for_reap, &session_for_writer,
                    );
                    tracing::info!(
                        "Session reaped: fp={}… (all streams down)",
                        &client_fp_for_writer[..16.min(client_fp_for_writer.len())]
                    );
                }
                // close_notify + FIN: the client (and the relay in front of
                // us) learns right away that this stream is gone.
                let _ = tokio::time::timeout(SHUTDOWN_TIMEOUT, tls_write.shutdown()).await;
            });

            // ─── RX loop (this TCP stream) ───────────────────────────────────
            let _ = tls_rx_loop(
                tls_read,
                session.clone(),
                tun_tx,
                sessions.clone(),
                keyring_ip,
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

/// Register `session` as the owner of tunnel IP `ip` (downlink routing).
fn register_ip(sessions: &VpnSessionMap, session: &Arc<VpnSession>, ip: Ipv4Addr, remote: SocketAddr, stream_idx: usize) {
    if vpn_session::register_session_ip(sessions, IpAddr::V4(ip), session.clone()) {
        tracing::warn!("Session replaced for tunnel IP {} ({})", ip, remote);
    } else {
        tracing::info!("Session registered for tunnel IP {} ({}, stream {})", ip, remote, stream_idx);
    }
}

/// IPv4 TCP SYN — the only packets the MSS clamp rewrites.
fn is_tcp_syn(pkt: &[u8]) -> bool {
    let ihl = ((pkt[0] & 0x0F) as usize) * 4;
    pkt[9] == 6 && pkt.len() > ihl + 13 && pkt[ihl + 13] & 0x02 != 0
}

/// TLS RX loop: read [4B len][batch] → extract packets → TUN.
/// Zero-copy: parse directly out of a BytesMut pool, emit each packet as `Bytes`.
///
/// `tun_ip` is the client's tunnel IP from the keyring. Without one (no
/// allowlist / no `tun_addr`), the first in-subnet source address is taken.
/// Either way, packets with any other source address are dropped.
#[allow(clippy::too_many_arguments)]
async fn tls_rx_loop<R: AsyncReadExt + Unpin>(
    mut reader: R,
    session: Arc<VpnSession>,
    tun_tx: mpsc::Sender<Bytes>,
    sessions: VpnSessionMap,
    mut tun_ip: Option<Ipv4Addr>,
    tun_network: Ipv4Addr,
    tun_prefix: u8,
    remote: SocketAddr,
    stream_idx: usize,
) -> anyhow::Result<()> {
    // Attached to a session that was closed (evicted, reaped) right after we
    // looked it up: registering its IP would close the client's fresh
    // replacement session. Drop this stream; the client reconnects into the
    // new one.
    if session.is_closed() {
        return Ok(());
    }
    if let Some(ip) = tun_ip {
        register_ip(&sessions, &session, ip, remote, stream_idx);
    }
    let mask: u32 = if tun_prefix == 0 { 0 } else { !0u32 << (32 - tun_prefix) };
    let mut dropped_spoofed: u64 = 0;

    let mut len_buf = [0u8; 4];

    loop {
        // Read frame header. A live client sends at least a heartbeat every
        // 30–60 s; silence past STREAM_IDLE_TIMEOUT means a dead peer.
        match tokio::time::timeout(STREAM_IDLE_TIMEOUT, reader.read_exact(&mut len_buf)).await {
            Ok(Ok(_)) => {}
            Ok(Err(_)) => break, // connection closed
            Err(_) => {
                tracing::info!("Stream {} from {} idle for {:?}, closing", stream_idx, remote, STREAM_IDLE_TIMEOUT);
                break;
            }
        }
        // Session closed (revoked, evicted, reaped): stop forwarding uplink.
        if session.is_closed() {
            break;
        }
        let frame_len = u32::from_be_bytes(len_buf) as usize;

        if frame_len > BATCH_MAX_PLAINTEXT {
            tracing::warn!("Oversized frame {} from {} (stream {})", frame_len, remote, stream_idx);
            break;
        }

        // Exactly frame_len per frame: packets below are zero-copy slices of
        // it and keep it alive until written to TUN, so a shared oversized
        // pool would pin 128 KB behind every queued ACK.
        let mut buf = BytesMut::zeroed(frame_len);
        match tokio::time::timeout(STREAM_IDLE_TIMEOUT, reader.read_exact(&mut buf[..])).await {
            Ok(Ok(_)) => {}
            _ => break,
        }

        session.bytes_rx.fetch_add((4 + frame_len) as u64, Ordering::Relaxed);
        session.touch();

        // Zero-copy: every packet below is a slice of `frame`.
        let frame: Bytes = buf.freeze();

        for pkt in batch_packets(&frame) {
            if pkt.len() < 20 || (pkt[0] >> 4) != 4 { continue; }

            let src_v4 = Ipv4Addr::new(pkt[12], pkt[13], pkt[14], pkt[15]);
            if tun_ip.is_none() && u32::from(src_v4) & mask == u32::from(tun_network) & mask {
                register_ip(&sessions, &session, src_v4, remote, stream_idx);
                tun_ip = Some(src_v4);
            }
            if tun_ip != Some(src_v4) {
                dropped_spoofed += 1;
                if dropped_spoofed == 1 || dropped_spoofed % 1024 == 0 {
                    tracing::warn!(
                        "Dropped packet with foreign src {} from {} (fp={}…, dropped={})",
                        src_v4, remote, &session.fingerprint[..16.min(session.fingerprint.len())], dropped_spoofed
                    );
                }
                continue;
            }

            // Only a SYN gets its MSS clamped — copy just those, the rest go
            // out as zero-copy slices of the frame.
            let pkt_bytes: Bytes = if is_tcp_syn(pkt) {
                let mut pkt_mut = BytesMut::from(pkt);
                let _ = clamp_tcp_mss(&mut pkt_mut, QUIC_TUNNEL_MSS);
                pkt_mut.freeze()
            } else {
                frame.slice_ref(pkt)
            };

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
    }

    Ok(())
}

fn heartbeat_delay() -> Duration {
    Duration::from_secs(rand::thread_rng().gen_range(HEARTBEAT_MIN_SECS..=HEARTBEAT_MAX_SECS))
}

/// While `left > 0`, pads `frame` with zeros after its batch terminator up to
/// a random size from `PAD_TARGET` (frames already larger pass unchanged).
fn pad_start(frame: Bytes, left: &mut u32) -> Bytes {
    if *left == 0 || frame.len() < 4 {
        return frame;
    }
    *left -= 1;
    let body = frame.len() - 4;
    let target = rand::thread_rng().gen_range(PAD_TARGET).min(BATCH_MAX_PLAINTEXT);
    if target <= body {
        return frame;
    }
    let mut out = BytesMut::with_capacity(4 + target);
    out.put_u32(target as u32);
    out.extend_from_slice(&frame[4..]);
    out.resize(4 + target, 0);
    out.freeze()
}

/// TLS write loop: drain Bytes from channel → write to TLS stream.
/// Emits a dummy heartbeat frame if no real traffic has flowed for a random
/// HEARTBEAT_MIN_SECS..=HEARTBEAT_MAX_SECS — keeps NAT state and the client's
/// liveness detector fed.
async fn tls_write_loop<W: AsyncWriteExt + Unpin>(
    mut frame_rx: mpsc::Receiver<Bytes>,
    writer: &mut W,
    remote: SocketAddr,
) {
    let mut next_heartbeat = tokio::time::Instant::now() + heartbeat_delay();
    let mut pad_left = rand::thread_rng().gen_range(PAD_FIRST_FRAMES);
    loop {
        tokio::select! {
            biased;
            maybe_frame = frame_rx.recv() => {
                let Some(frame) = maybe_frame else { break; };
                let frame = pad_start(frame, &mut pad_left);
                if writer.write_all(&frame).await.is_err() {
                    tracing::debug!("TLS write to {} failed", remote);
                    break;
                }
                // Drain queued frames before flushing
                let mut write_err = false;
                for _ in 0..31 {
                    match frame_rx.try_recv() {
                        Ok(frame) => {
                            let frame = pad_start(frame, &mut pad_left);
                            if writer.write_all(&frame).await.is_err() {
                                write_err = true;
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                if write_err {
                    break;
                }
                if writer.flush().await.is_err() {
                    tracing::debug!("TLS flush to {} failed", remote);
                    break;
                }
                // Real traffic just flowed → push heartbeat deadline forward.
                next_heartbeat = tokio::time::Instant::now() + heartbeat_delay();
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
                next_heartbeat = tokio::time::Instant::now() + heartbeat_delay();
            }
        }
    }
    tracing::debug!("TLS write loop ended for {}", remote);
}

// Fallback handler moved to `fakeapp.rs` module.

#[cfg(test)]
mod tests {
    use super::*;
    use phantom_core::wire::build_batch_plaintext;

    /// Padded frames must stay readable by every existing receiver: same
    /// packets, length prefix matches the body, padding only after 0x0000.
    #[test]
    fn padded_frame_keeps_packets() {
        let pkts: [&[u8]; 2] = [&[0x45; 60], &[0x45; 40]];
        let mut body = vec![0u8; 256];
        let n = build_batch_plaintext(&pkts, 0, &mut body).unwrap();
        let mut frame = BytesMut::new();
        frame.put_u32(n as u32);
        frame.extend_from_slice(&body[..n]);
        let frame = frame.freeze();

        let mut left = 2;
        let padded = pad_start(frame.clone(), &mut left);
        assert_eq!(left, 1);
        let len = u32::from_be_bytes(padded[..4].try_into().unwrap()) as usize;
        assert_eq!(len, padded.len() - 4);
        assert!(PAD_TARGET.contains(&len));
        let got: Vec<&[u8]> = batch_packets(&padded[4..]).collect();
        assert_eq!(got, pkts);

        let mut none = 0;
        assert_eq!(pad_start(frame.clone(), &mut none), frame);
    }

    #[test]
    fn syn_detection() {
        let mut pkt = [0u8; 40];
        pkt[0] = 0x45;
        pkt[9] = 6;
        assert!(!is_tcp_syn(&pkt));
        pkt[33] = 0x02; // SYN
        assert!(is_tcp_syn(&pkt));
        pkt[9] = 17; // UDP
        assert!(!is_tcp_syn(&pkt));
    }
}
