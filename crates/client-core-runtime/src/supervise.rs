//! Tunnel supervisor FSM with backoff reconnect.
//!
//! `supervise()` runs one `drive_tunnel()` attempt at a time and, on failure,
//! sleeps a backoff delay before retrying. With `auto_reconnect` it never
//! gives up on network errors; only fatal errors (bad profile, certificate
//! problems, revoked access, wrong clock) end in `ConnState::Error`. An
//! explicit `cancel` `watch::Receiver<bool>` interrupts any pending sleep
//! (issued by the caller on explicit disconnect; survives missed signals
//! because `watch` stores the latest value).

use anyhow::Context;
use bytes::Bytes;
use std::net::SocketAddr;
use std::os::unix::io::{AsRawFd, RawFd};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use client_common::helpers;
use client_common::tls_handshake::{TlsReadHalf, TlsWriteHalf, HANDSHAKE_TIMEOUT};
use client_common::{
    tls_connect_with_tcp, tls_connect_with_tcp_boring, tls_rx_loop_counted, tls_tx_loop,
    write_handshake, ClientTls,
};
use ghoststream_gui_ipc::{ConnState, ConnectProfile, StatusFrame, TunnelHealth, TunnelSettings};
use phantom_core::wire::{flow_stream_idx, n_data_streams_with_override};
use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::{watch, Mutex};

use crate::log_bridge::{packet_rx_log_sample_should_emit, packet_tx_log_sample_should_emit};
use crate::telemetry::{
    classify_error, disconnect_kind_label, now_unix_ms, spawn_telem_task, tls_state_label,
    Telemetry, KIND_RX_FORWARDER_DEAD, KIND_USER_DISCONNECT, TLS_CLOSED, TLS_CLOSING,
    TLS_ESTABLISHED, TLS_HANDSHAKING,
};
use crate::ProtectSocket;

/// Callback invoked by `supervise()` each attempt to create fresh TUN I/O
/// channels. Returns `(packet_reader, packet_writer)`.
///
/// The factory is called again on each reconnect attempt so the supervisor
/// does not need to know how TUN I/O is implemented.
pub type TunFactory = Arc<
    dyn Fn() -> anyhow::Result<(
        tokio::sync::mpsc::Receiver<Bytes>,
        tokio::sync::mpsc::Sender<Bytes>,
    )>
    + Send
    + Sync,
>;

/// Bound on resolving the server name: a hung resolver must not pin the
/// supervisor (cancellation is raced separately).
const DNS_TIMEOUT: Duration = Duration::from_secs(10);

/// A connection that stayed up this long counts as healthy: the backoff
/// starts over from the shortest delay after it drops.
const STABLE_SESSION: Duration = Duration::from_secs(30);

/// Wall-clock jump between two 1 s watcher ticks that means the device slept
/// (monotonic timers stop during sleep, the wall clock does not).
const SLEEP_JUMP: Duration = Duration::from_secs(60);

/// Top-level supervisor. Spawned once per `connect()` call. Runs
/// `drive_tunnel()`, decides whether to reconnect, publishes GUI state.
///
/// v0.25.1 (W3-2): `cancel` is a `watch::Receiver<bool>` rather than the
/// previous `Arc<Notify>`. `Notify::notify_waiters` only wakes tasks
/// already suspended on `.notified()` — a cancel issued during the brief
/// window between `select!` arms re-arming was silently dropped. `watch`
/// stores the latest value so a late observer still sees `true`.
pub async fn supervise(
    profile: ConnectProfile,
    settings: TunnelSettings,
    tun_factory: TunFactory,
    status_tx: watch::Sender<StatusFrame>,
    mut cancel: watch::Receiver<bool>,
    shared_telem: Arc<Mutex<Option<Arc<Telemetry>>>>,
    protect_socket: Option<ProtectSocket>,
) {
    publish_attempt_state(&status_tx, 0);

    // Everything derived from the profile is built once per run: a profile
    // problem is fatal (no retry can fix it), and one shared ClientTls lets
    // rustls resume TLS sessions across reconnects instead of repeating the
    // full mTLS handshake every time.
    //
    // SEC-R2-N06: only the top-level context — never the full chain.
    // `format!("{:#}", e)` can leak raw bytes through `base64::DecodeError`
    // and `FromUtf8Error` Display impls which surface offset/surrounding
    // bytes from invalid PEM.
    let cfg = match helpers::parse_conn_string(&profile.conn_string) {
        Ok(c) => c,
        Err(e) => {
            fail(&status_tx, format!("Неверная строка подключения: {}", e), "parse_conn_string");
            return;
        }
    };
    tracing::info!(
        category = "settings",
        name = %profile.name,
        server = %cfg.network.server_addr,
        sni = %cfg.network.server_name.as_deref().unwrap_or(""),
        "profile.loaded"
    );
    let client_tls = match helpers::load_tls_identity(&cfg)
        .and_then(|id| Ok((id, helpers::load_server_ca(&cfg)?)))
        .and_then(|(id, ca)| build_client_tls(ca, id))
    {
        Ok(t) => t,
        Err(e) => {
            fail(&status_tx, format!("Сертификат профиля не читается: {}", e), "tls_identity");
            return;
        }
    };

    let tun_addr = cfg.network.tun_addr.clone().unwrap_or_default();
    let sni = cfg.network.server_name.clone().unwrap_or_default();
    let server_name = cfg.network.server_name.clone().unwrap_or_else(|| "phantom".into());
    let raw_addr = client_common::with_default_port(&cfg.network.server_addr, 443);
    // Stream count resolution (ADR 0014): explicit user setting wins, else the
    // transport policy, else automatic (CPU-derived).
    let streams_override = settings.streams.or_else(|| phantom_core::policy::current().streams);
    let n_streams = n_data_streams_with_override(streams_override);

    let mut attempt: u32 = 0;
    loop {
        publish_attempt_state(&status_tx, attempt);

        let resolved = tokio::select! {
            biased;
            _ = crate::wait_cancelled(&mut cancel) => None,
            r = resolve_server(&raw_addr) => Some(r),
        };
        let server_addr = match resolved {
            None => {
                tracing::info!(category = "tunnel", reason = "user", phase = "dns", "disconnect");
                publish_stopped(&status_tx);
                break;
            }
            Some(r) => r,
        };

        let result = match server_addr {
            Err(e) => Err(e),
            Ok(server_addr) => {
                let telemetry = Arc::new(Telemetry::new(
                    n_streams,
                    tun_addr.clone(),
                    server_addr.to_string(),
                    sni.clone(),
                ));
                *shared_telem.lock().await = Some(telemetry.clone());

                if attempt == 0 {
                    tracing::info!(
                        category = "tunnel",
                        profile_id = %profile.name,
                        server = %server_addr,
                        sni = %sni,
                        streams = n_streams as u64,
                        "start"
                    );
                } else {
                    tracing::info!(category = "tunnel", attempt = attempt as u64, "reconnect.attempt");
                }

                let tun_channels = match tun_factory() {
                    Ok(ch) => ch,
                    Err(e) => {
                        fail(&status_tx, format!("Не удалось открыть TUN: {:#}", e), "tun_factory");
                        *shared_telem.lock().await = None;
                        break;
                    }
                };

                let dialer = StreamDialer {
                    server_addr,
                    server_name: server_name.clone(),
                    client_tls: client_tls.clone(),
                    protect_socket: protect_socket.clone(),
                    n_streams,
                };
                let result = drive_tunnel(
                    dialer,
                    &tun_addr,
                    status_tx.clone(),
                    telemetry.clone(),
                    tun_channels,
                    cancel.clone(),
                    settings.dpi_recycle_secs,
                    settings.dpi_recycle_bytes,
                )
                .await;

                let explicit_shutdown = telemetry.shutdown.load(Ordering::SeqCst);
                let stable = telemetry
                    .connected_at
                    .get()
                    .is_some_and(|t| t.elapsed() >= STABLE_SESSION);
                *shared_telem.lock().await = None;

                if explicit_shutdown {
                    tracing::info!(category = "tunnel", reason = "user", "disconnect");
                    publish_stopped(&status_tx);
                    break;
                }
                // v0.27.0 (W10): DPI recycle — intentional, reconnect at once
                // with no backoff and no error churn in the status frame.
                if matches!(&result, Err(e) if e.to_string().starts_with("recycle requested")) {
                    tracing::info!(
                        category = "tunnel",
                        reason = "recycle",
                        "session refreshed — reconnecting immediately"
                    );
                    attempt = 0;
                    continue;
                }
                if stable {
                    attempt = 0;
                }
                result
            }
        };

        // drive_tunnel returns Ok only on an explicit stop, handled above.
        let err = result.err().unwrap_or_else(|| anyhow::anyhow!("tunnel closed"));
        // Classify by the whole chain (the top line is often just "stream N
        // handshake failed"); log and show only the top line + category.
        let chain = format!("{:#}", err);
        let top = format!("{}", err);
        if let Some(reason) = crate::fatal_reason(&chain) {
            tracing::error!(category = "tunnel", error = %top, "fatal");
            fail(&status_tx, reason.to_string(), "fatal");
            break;
        }
        let err_category = crate::classify_tunnel_error(&chain);
        tracing::error!(
            category = "tunnel",
            phase = "drive",
            error = %top,
            err_kind = err_category.as_str(),
            "error"
        );

        if !should_reconnect(&settings, &status_tx, &mut cancel, attempt, err_category, &top).await {
            // A dropped sender means the owner is gone — also a stop.
            if *cancel.borrow() || cancel.has_changed().is_err() {
                // Stop pressed during the pause: a plain stop, not an error.
                publish_stopped(&status_tx);
            } else {
                // auto_reconnect is off — the tunnel stays down with the reason.
                tracing::error!(
                    category = "tunnel",
                    attempts = (attempt + 1) as u64,
                    last_error = %top,
                    err_kind = err_category.as_str(),
                    "reconnect.giveup"
                );
                let mut f = status_tx.borrow().clone();
                f.state = ConnState::Error;
                f.last_error = Some(top);
                f.reconnect_attempt = None;
                f.reconnect_next_delay_secs = None;
                let _ = status_tx.send(f);
            }
            break;
        }
        attempt += 1;
    }
}

/// Connecting on the first attempt, Reconnecting afterwards.
fn publish_attempt_state(status_tx: &watch::Sender<StatusFrame>, attempt: u32) {
    let mut f = status_tx.borrow().clone();
    if attempt == 0 {
        f.state = ConnState::Connecting;
        f.reconnect_attempt = None;
        f.reconnect_next_delay_secs = None;
    } else {
        f.state = ConnState::Reconnecting;
        f.reconnect_attempt = Some(attempt);
    }
    f.streams_up = 0;
    f.stream_activity = [0.0; 16];
    let _ = status_tx.send(f);
}

/// User stop: Disconnected, no error left behind.
fn publish_stopped(status_tx: &watch::Sender<StatusFrame>) {
    let mut f = status_tx.borrow().clone();
    f.state = ConnState::Disconnected;
    f.health = TunnelHealth::Healthy;
    f.last_error = None;
    f.streams_up = 0;
    f.stream_activity = [0.0; 16];
    f.reconnect_attempt = None;
    f.reconnect_next_delay_secs = None;
    let _ = status_tx.send(f);
}

/// Fatal stop: Error with a human-readable reason.
fn fail(status_tx: &watch::Sender<StatusFrame>, msg: String, phase: &str) {
    tracing::error!(
        category = "tunnel",
        phase = %phase,
        error = %msg,
        err_kind = %disconnect_kind_label(classify_error(&msg)),
        "error"
    );
    let mut f = status_tx.borrow().clone();
    f.state = ConnState::Error;
    f.last_error = Some(msg);
    f.streams_up = 0;
    f.stream_activity = [0.0; 16];
    f.reconnect_attempt = None;
    f.reconnect_next_delay_secs = None;
    let _ = status_tx.send(f);
}

/// Decide whether to keep retrying and sleep the backoff. Publishes
/// Reconnecting (with the countdown) *before* sleeping, so the GUI never
/// shows Connected during the pause.
///
/// Returns `false` when auto_reconnect is off or an explicit disconnect
/// cancel arrived mid-sleep. There is no attempt limit.
async fn should_reconnect(
    settings: &TunnelSettings,
    status_tx: &watch::Sender<StatusFrame>,
    cancel: &mut watch::Receiver<bool>,
    attempt: u32,
    err_category: crate::TunnelErrorCategory,
    last_error: &str,
) -> bool {
    if !settings.auto_reconnect {
        return false;
    }
    let delay = crate::reconnect_delay_secs(err_category, attempt);
    // Up to +25 % jitter so many clients dropped by one event don't come back
    // in lock-step.
    let sleep_ms = u64::from(delay) * 1000 + jitter(attempt as usize, u64::from(delay) * 250);
    tracing::warn!(
        category = "tunnel",
        attempt = (attempt + 1) as u64,
        delay_secs = delay as u64,
        error_category = err_category.as_str(),
        "reconnect.scheduled"
    );
    {
        let mut f = status_tx.borrow().clone();
        f.state = ConnState::Reconnecting;
        f.health = TunnelHealth::Reconnecting;
        f.streams_up = 0;
        f.stream_activity = [0.0; 16];
        f.reconnect_attempt = Some(attempt + 1);
        f.reconnect_next_delay_secs = Some(delay);
        f.last_error = Some(last_error.to_string());
        let _ = status_tx.send(f);
    }

    tokio::select! {
        _ = tokio::time::sleep(Duration::from_millis(sleep_ms)) => true,
        _ = crate::wait_cancelled(cancel) => {
            tracing::info!(category = "tunnel", reason = "user", "reconnect.cancelled");
            false
        }
    }
}

/// Cheap pseudo-random value in `0..range` without pulling the `rand` crate
/// into this crate. `salt` is mixed in (Knuth multiplicative hash) so callers
/// in the same clock tick — or on a coarse-resolution clock where
/// `subsec_nanos` barely moves — still diverge.
fn jitter(salt: usize, range: u64) -> u64 {
    if range == 0 {
        return 0;
    }
    let nanos = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let mixed = nanos ^ (salt as u32).wrapping_mul(2_654_435_761);
    u64::from(mixed) % range
}

/// Resolve the server address (bounded by `DNS_TIMEOUT`).
async fn resolve_server(raw_addr: &str) -> anyhow::Result<SocketAddr> {
    if let Ok(a) = raw_addr.parse() {
        return Ok(a);
    }
    let all: Vec<SocketAddr> = tokio::time::timeout(DNS_TIMEOUT, tokio::net::lookup_host(raw_addr))
        .await
        .map_err(|_| anyhow::anyhow!("DNS lookup timeout for {}", raw_addr))?
        .map_err(|e| anyhow::anyhow!("DNS lookup: {}", e))?
        .collect();
    // v0.25.0: prefer IPv4 — наши серверы v4-only, на IPv6-only сетях
    // (T-Mobile US, Иран) первый адрес без фильтра может оказаться IPv6 →
    // TCP connect timeout. Bug #9.
    let chosen = all
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| all.first())
        .copied()
        .ok_or_else(|| anyhow::anyhow!("no DNS results for {}", raw_addr))?;
    tracing::info!(
        category = "network",
        event = "dns.resolved",
        host = %raw_addr,
        chosen = %chosen,
        v4_count = all.iter().filter(|a| a.is_ipv4()).count() as u64,
        v6_count = all.iter().filter(|a| a.is_ipv6()).count() as u64,
        stack = if chosen.is_ipv4() { "v4" } else { "v6" },
        "DNS resolved"
    );
    Ok(chosen)
}

/// Build the TLS client once per run. Fingerprint dispatch (ADR 0014
/// Phase 2): rustls by default; boring (uTLS, browser-family ClientHello)
/// when the transport policy selects a fingerprint.
fn build_client_tls(
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(
        Vec<rustls::pki_types::CertificateDer<'static>>,
        rustls::pki_types::PrivateKeyDer<'static>,
    )>,
) -> anyhow::Result<ClientTls> {
    let pol = phantom_core::policy::current();
    // mTLS toggle (hypothesis test): when disabled, drop the client certificate
    // from the TLS handshake entirely (auth then must move in-stream, server-side).
    let client_identity = if pol.mtls {
        client_identity
    } else {
        tracing::warn!(category = "handshake", "mTLS DISABLED by policy — no client cert in handshake");
        None
    };
    Ok(match &pol.fingerprint {
        phantom_core::policy::ResolvedFingerprint::Default => ClientTls::Rustls(
            phantom_core::h2_transport::make_h2_client_tls(server_ca, client_identity)
                .context("build TLS client config")?,
        ),
        other => {
            let profile = match other {
                phantom_core::policy::ResolvedFingerprint::Named(n) => n.clone(),
                _ => "boring".to_string(),
            };
            // Server-cert verification stays ON. This was hardcoded `true` during
            // the ADR 0014 Phase 2 boring experiments (to avoid solving Android
            // root-store loading first); shipping that silently disables cert
            // verification for every non-default fingerprint — an ADR 0011
            // violation, and it makes the tunnel MITM-able. Fail closed instead.
            // Opt in only for the lab harness.
            let insecure = cfg!(feature = "lab-overrides");
            tracing::warn!(category = "handshake", fp = %profile, insecure,
                "boring uTLS fingerprint path selected");
            ClientTls::Boring(
                client_common::make_boring_client_tls(server_ca, client_identity, profile, insecure)
                    .context("build boring TLS client config")?,
            )
        }
    })
}

/// Kill a stream whose sent data stays unacknowledged for 30 s instead of
/// waiting out the 90 s RX timeout on a half-open socket under load. A local
/// timer only — it puts nothing extra on the wire (unlike keepalive).
fn set_tcp_user_timeout(fd: RawFd) {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let (opt, val): (libc::c_int, libc::c_int) = (libc::TCP_USER_TIMEOUT, 30_000); // ms
    // TCP_RXT_CONNDROPTIME from <netinet/tcp.h>, in seconds.
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    let (opt, val): (libc::c_int, libc::c_int) = (0x80, 30);
    #[cfg(any(target_os = "linux", target_os = "android", target_os = "macos", target_os = "ios"))]
    {
        let rc = unsafe {
            libc::setsockopt(
                fd,
                libc::IPPROTO_TCP,
                opt,
                &val as *const libc::c_int as *const libc::c_void,
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            )
        };
        if rc != 0 {
            tracing::debug!(category = "handshake", error = %std::io::Error::last_os_error(),
                "tcp user timeout not set");
        }
    }
}

/// Everything needed to (re)open one stream. Cloned into each stream task so
/// a dead stream is re-dialled on its own, without touching the others.
#[derive(Clone)]
struct StreamDialer {
    server_addr: SocketAddr,
    server_name: String,
    client_tls: ClientTls,
    protect_socket: Option<ProtectSocket>,
    n_streams: usize,
}

impl StreamDialer {
    /// Open ONE stream at a fixed `idx`: 1 attempt + 2 retries on a fresh
    /// socket with jitter (CONC-A1/A2, 2026-06-13 TSPU fix — the handshake of
    /// some parallel streams is silently blackholed, and a fresh socket almost
    /// always clears it). Fatal errors are not retried.
    async fn open(&self, idx: usize) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
        const STREAM_OPEN_RETRIES: u32 = 2;
        let mut last_err: Option<anyhow::Error> = None;
        for attempt in 0..=STREAM_OPEN_RETRIES {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(50 + jitter(idx, 100))).await;
                tracing::debug!(
                    category = "handshake",
                    stream_id = idx as u64,
                    attempt = attempt as u64,
                    "stream.retry"
                );
            }
            match self.dial(idx).await {
                Ok(rw) => {
                    // stream.open — per ADR 0008 §2.
                    tracing::debug!(
                        category = "stream",
                        stream_id = idx as u64,
                        priority = %if idx == 0 { "high" } else { "normal" },
                        "open"
                    );
                    return Ok(rw);
                }
                Err(e) => {
                    let chain = format!("{:#}", e);
                    tracing::warn!(
                        category = "handshake",
                        stream_id = idx as u64,
                        attempt = attempt as u64,
                        error = %chain,
                        "stream.open_failed"
                    );
                    if crate::fatal_reason(&chain).is_some() {
                        return Err(e);
                    }
                    last_err = Some(e);
                }
            }
        }
        Err(last_err.unwrap_or_else(|| anyhow::anyhow!("stream {} open failed", idx)))
    }

    /// One TCP + TLS + stream-handshake attempt. The socket is created here on
    /// every platform: Android must `VpnService.protect()` it before any I/O
    /// (including retries, else traffic loops back via tun), and every
    /// platform gets a bounded connect and the TCP user timeout.
    async fn dial(&self, idx: usize) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
        let socket = if self.server_addr.is_ipv4() {
            tokio::net::TcpSocket::new_v4()
        } else {
            tokio::net::TcpSocket::new_v6()
        }
        .with_context(|| format!("stream {} socket create", idx))?;
        let fd = socket.as_raw_fd();
        if let Some(protect) = &self.protect_socket {
            if !protect(fd) {
                anyhow::bail!("stream {} VpnService.protect() failed", idx);
            }
        }
        set_tcp_user_timeout(fd);
        // Bounded like the TLS phase: under a TSPU SYN-blackhole an unbounded
        // connect() blocks on kernel SYN_RETRIES (~75-130 s) and starves the
        // per-stream retry.
        let tcp = tokio::time::timeout(HANDSHAKE_TIMEOUT, socket.connect(self.server_addr))
            .await
            .with_context(|| format!("stream {} tcp connect timeout", idx))?
            .with_context(|| format!("stream {} tcp connect", idx))?;
        tracing::debug!(category = "handshake", peer = %self.server_addr, stream_id = idx as u64,
            "tcp.connected");

        let (r, mut w) = match &self.client_tls {
            ClientTls::Rustls(c) => tls_connect_with_tcp(tcp, self.server_name.clone(), c.clone()).await,
            ClientTls::Boring(c) => {
                tls_connect_with_tcp_boring(tcp, self.server_name.clone(), c.clone()).await
            }
        }
        .with_context(|| format!("stream {} tls connect", idx))?;
        tracing::debug!(
            category = "handshake",
            result = "ok",
            subject = %self.server_name,
            stream_id = idx as u64,
            "mtls.cert_verify"
        );
        // Wire contract: the 2nd handshake byte is ALWAYS the full n_streams
        // (never a live count). The server pins effective_n from it and evicts
        // the session on mismatch.
        write_handshake(&mut w, idx as u8, self.n_streams as u8)
            .await
            .with_context(|| format!("stream {} handshake", idx))?;
        tracing::debug!(
            category = "handshake",
            max_concurrent = self.n_streams as u64,
            initial_window = 0u64,
            stream_id = idx as u64,
            "h2.settings_sent"
        );
        Ok((r, w))
    }
}

/// One stream's lifetime inside a session: run RX and TX until either side
/// ends, then reopen just this stream after a random 1–10 s pause. Peers are
/// untouched, so a single frozen connection (TSPU "streams die one by one")
/// heals without a synchronized all-N reconnect burst — the server attaches
/// the new connection to the existing session. A stream that keeps failing
/// (or dies right after reopening) backs off along `BACKOFF_SECS`, so a
/// server that refuses us is not hammered. Returns on tunnel teardown
/// (channels closed) or on a fatal error, which it records in
/// `tele.fatal` for the death watcher.
async fn run_stream(
    idx: usize,
    mut rw: (TlsReadHalf, TlsWriteHalf),
    mut tx_queue: tokio::sync::mpsc::Receiver<Bytes>,
    sink: tokio::sync::mpsc::Sender<Bytes>,
    tele: Arc<Telemetry>,
    dialer: StreamDialer,
) {
    let mut fails: usize = 0;
    loop {
        tele.streams_alive[idx].store(true, Ordering::Relaxed);
        let started_at = Instant::now();
        let (r, w) = rw;
        let res = tokio::select! {
            res = tls_rx_loop_counted(
                r,
                sink.clone(),
                Some(Duration::from_secs(crate::RX_IDLE_TIMEOUT_SECS as u64)),
                &tele.rx_frames,
            ) => res,
            res = tls_tx_loop(w, &mut tx_queue) => res,
        };
        tele.streams_alive[idx].store(false, Ordering::Relaxed);
        let lifetime_ms = started_at.elapsed().as_millis() as u64;
        let e = match res {
            Ok(()) => {
                tracing::debug!(category = "stream", stream_id = idx as u64, lifetime_ms, "close");
                return;
            }
            Err(e) => e,
        };
        // v0.27.0 W4-3: classify + record so tunnel teardown can surface
        // "tcp_reset", "timeout" etc. as the cause.
        let chain = format!("{:#}", e);
        let kind = classify_error(&chain);
        tele.disconnect_kind.store(kind, Ordering::Relaxed);
        tele.last_failed_stream.store(idx as i8, Ordering::Relaxed);
        tracing::warn!(
            category = "stream",
            stream_id = idx as u64,
            error = %e,
            err_kind = %disconnect_kind_label(kind),
            lifetime_ms,
            "kill"
        );
        if crate::fatal_reason(&chain).is_some() {
            let _ = tele.fatal.set(chain);
            return;
        }
        fails = if started_at.elapsed() >= STABLE_SESSION { 0 } else { fails + 1 };

        rw = loop {
            let floor_ms = u64::from(crate::BACKOFF_SECS[fails.min(crate::BACKOFF_SECS.len() - 1)]) * 1000;
            let pause_ms = (1_000 + jitter(idx, 9_000)).max(floor_ms + jitter(idx, floor_ms / 4));
            tokio::time::sleep(Duration::from_millis(pause_ms)).await;
            match dialer.open(idx).await {
                Ok(rw) => break rw,
                Err(e) => {
                    fails += 1;
                    let chain = format!("{:#}", e);
                    if crate::fatal_reason(&chain).is_some() {
                        let _ = tele.fatal.set(chain);
                        return;
                    }
                }
            }
        };
        tracing::info!(category = "stream", stream_id = idx as u64, "reopened");
    }
}

/// Connect TLS streams, spawn I/O tasks, and run until shutdown or error.
/// Returns `Ok` only on an explicit stop; every other exit is an `Err`
/// carrying the cause.
///
/// Does NOT manage Linux-specific guards (DnsGuard, Ipv6Guard, RouteGuard) —
/// those remain in the linux-helper crate and are set up around this call.
#[allow(clippy::too_many_arguments)]
async fn drive_tunnel(
    dialer: StreamDialer,
    tun_addr: &str,
    status_tx: watch::Sender<StatusFrame>,
    telemetry: Arc<Telemetry>,
    tun_channels: (
        tokio::sync::mpsc::Receiver<Bytes>,
        tokio::sync::mpsc::Sender<Bytes>,
    ),
    mut cancel: watch::Receiver<bool>,
    // v0.27.0 (W10/W11): periodic session recycle to defeat net4people #490
    // silent-freeze. Two flavours:
    //  - `dpi_recycle_secs` (W10): time-based, fires every N seconds even
    //    when idle. Kept for debugging.
    //  - `dpi_recycle_bytes` (W11): byte-based, fires when bytes_rx +
    //    bytes_tx crosses N. Preferred — idle sessions don't get
    //    pointlessly recycled.
    // If both are set, whichever trips first wins. `None` / 0 = disabled.
    dpi_recycle_secs: Option<u32>,
    dpi_recycle_bytes: Option<u64>,
) -> anyhow::Result<()> {
    let n_streams = dialer.n_streams;
    let server_addr = dialer.server_addr;

    // ── Cancellable handshake (CONC-C1) ───────────────────────────────────
    //
    // The whole per-stream connect/TLS/handshake sequence races the
    // supervisor's `cancel` watch, so a Disconnect issued mid-connect is seen
    // at once (bug-bash #7 "Disconnect hangs 75 s").
    //
    // v0.27.1 (DPI regression fix — restores v0.22.4): streams are opened
    // STRICTLY SEQUENTIALLY, each TCP+TLS+handshake completing before the next
    // is dialed, so the N ClientHellos are spread over their natural RTT —
    // like a browser progressively opening connections. A concurrent fan-out
    // fired N SYNs to one IP:port within ~25 ms, a synchronized SYN-burst
    // carrier-DPI fingerprints as a VPN (pcap A/B vs v0.22.4). Stream 0 first
    // also preserves the server coordinator / mimicry-warmup ordering.
    //
    // All N are required (no partial quorum): the data plane routes
    // `flow_stream_idx % n_streams` and the server pins `effective_n`; a
    // missing index would blackhole every flow hashing to it. Position in
    // `opened` equals stream_idx by construction.
    telemetry.tls_state.store(TLS_HANDSHAKING, Ordering::Relaxed);
    let handshake_fut = async {
        let mut opened = Vec::with_capacity(n_streams);
        for idx in 0..n_streams {
            opened.push(
                dialer
                    .open(idx)
                    .await
                    .with_context(|| format!("stream {} handshake failed", idx))?,
            );
        }
        anyhow::Ok(opened)
    };
    let opened = tokio::select! {
        biased;
        _ = crate::wait_cancelled(&mut cancel) => {
            tracing::info!(category = "tunnel", phase = "handshake", "cancelled during handshake");
            // Explicit shutdown: the supervisor exits cleanly without retry.
            telemetry.shutdown.store(true, Ordering::SeqCst);
            anyhow::bail!("cancelled");
        }
        result = handshake_fut => result?,
    };
    // streams_alive set ONLY here, on success of all N — never mid-handshake —
    // so the death-watcher / derive_health never see a transient stream alive.
    for idx in 0..n_streams {
        telemetry.streams_alive[idx].store(true, Ordering::Relaxed);
    }
    let _ = telemetry.connected_at.set(Instant::now());
    // The handshake itself was the last thing received; Stale counts from here.
    telemetry.last_rx_unix_ms.store(now_unix_ms(), Ordering::Relaxed);
    telemetry.tls_state.store(TLS_ESTABLISHED, Ordering::Relaxed);
    tracing::info!(
        category = "handshake",
        n_streams_open = n_streams as u64,
        tls_state = %tls_state_label(TLS_ESTABLISHED),
        "h2.ready"
    );
    tracing::info!(
        category = "tunnel",
        session_id = %format!("{:x}", telemetry.started_at.elapsed().as_nanos() as u64),
        negotiated_streams = n_streams as u64,
        "connected"
    );

    let (mut tun_pkt_rx, tun_pkt_tx) = tun_channels;

    // Transition to Connected state, clearing all residue of earlier attempts
    // (stale last_rx_ms flagged Stale for a tick; a prior attempt's last_error
    // showed "DNS lookup failed" while actually Connected).
    {
        let mut f = status_tx.borrow().clone();
        f.state = ConnState::Connected;
        f.n_streams = n_streams as u8;
        f.streams_up = n_streams as u8;
        f.tun_addr = Some(if tun_addr.is_empty() { "10.7.0.2/24" } else { tun_addr }.to_string());
        f.server_addr = Some(server_addr.to_string());
        f.sni = Some(dialer.server_name.clone());
        f.last_rx_ms = 0;
        f.last_tx_ms = 0;
        f.idle_rx_secs = 0;
        f.last_error = None;
        f.reconnect_attempt = None;
        f.reconnect_next_delay_secs = None;
        f.health = TunnelHealth::Healthy;
        f.bandwidth_class = ghoststream_gui_ipc::BandwidthClass::Normal;
        let _ = status_tx.send(f);
    }

    // Per-stream TX queues; receivers live in the stream tasks across reopens.
    let mut tx_senders: Vec<tokio::sync::mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
    let mut tx_receivers: Vec<tokio::sync::mpsc::Receiver<Bytes>> = Vec::with_capacity(n_streams);
    for _ in 0..n_streams {
        let (t, r) = tokio::sync::mpsc::channel::<Bytes>(crate::STREAM_TX_QUEUE);
        tx_senders.push(t);
        tx_receivers.push(r);
    }
    let (rx_sink_tx, mut rx_sink_rx) = tokio::sync::mpsc::channel::<Bytes>(crate::PACKET_QUEUE);

    // Dispatcher: TUN → per-stream queue.
    //
    // A dead (reopening) stream drops its flow's packets at once — TCP inside
    // the tunnel retransmits. A live but momentarily full queue gets a short
    // grace before the drop: dropping on the first full slot (2026-05-06 RC1)
    // cost ×13 throughput, while an unbounded wait let one stuck stream wedge
    // ALL TX (v0.27.1 DPI regression). The dispatcher only ends when the TUN
    // reader closes.
    let tele = telemetry.clone();
    let mut dispatcher = tokio::spawn(async move {
        let mut first_tx_logged: [bool; 16] = [false; 16];
        while let Some(pkt) = tun_pkt_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams);
            let len = pkt.len() as u64;
            // stream.first_packet_tx — once per stream lifetime.
            if !first_tx_logged[idx] {
                first_tx_logged[idx] = true;
                tracing::trace!(category = "stream", stream_id = idx as u64, bytes = len, "first_packet_tx");
            }
            let sent = tele.streams_alive[idx].load(Ordering::Relaxed)
                && match tx_senders[idx].try_send(pkt) {
                    Ok(()) => true,
                    Err(TrySendError::Full(pkt)) => tx_senders[idx]
                        .send_timeout(pkt, Duration::from_millis(50))
                        .await
                        .is_ok(),
                    Err(TrySendError::Closed(_)) => false,
                };
            if sent {
                tele.bytes_tx.fetch_add(len, Ordering::Relaxed);
                tele.stream_tx_bytes[idx].fetch_add(len, Ordering::Relaxed);
                if packet_tx_log_sample_should_emit() {
                    tracing::trace!(category = "packet", n_pkts = 1u64, bytes = len,
                        stream_id = idx as u64, "tx.batch");
                }
            } else {
                let dropped = tele.tx_dropped.fetch_add(1, Ordering::Relaxed) + 1;
                if dropped.is_power_of_two() {
                    tracing::warn!(category = "packet", stream_id = idx as u64, dropped, "tx.drop");
                }
            }
        }
    });

    // RX sink forwarder: count bytes then push into TUN writer.
    //
    // v0.25.1 (W3-1): a TUN writer that stops accepting (fd closed, OS hung,
    // VpnService teardown half-way) used to block forever and freeze every
    // stream's RX behind it. The TUN write is timed out at 5 s and, on
    // expiry, the supervisor tears down and reconnects.
    let (forwarder_dead_tx, mut forwarder_dead_rx) = tokio::sync::oneshot::channel::<()>();
    let tun_write_tx = tun_pkt_tx;
    let tele_rx = telemetry.clone();
    let rx_forwarder = tokio::spawn(async move {
        while let Some(pkt) = rx_sink_rx.recv().await {
            let len = pkt.len() as u64;
            tele_rx.bytes_rx.fetch_add(len, Ordering::Relaxed);
            match tokio::time::timeout(Duration::from_secs(5), tun_write_tx.send(pkt)).await {
                Ok(Ok(())) => {}
                // TUN writer dropped — clean teardown path, not deadlock.
                Ok(Err(_send_err)) => return,
                Err(_elapsed) => {
                    tracing::error!(
                        category = "tunnel",
                        event = "rx_forwarder.tun_write_timeout",
                        "TUN write blocked for 5 s — forwarder is dead, will reconnect"
                    );
                    let _ = forwarder_dead_tx.send(());
                    return;
                }
            }
            if packet_rx_log_sample_should_emit() {
                tracing::trace!(category = "packet", n_pkts = 1u64, bytes = len, "rx.batch");
            }
        }
    });

    // Per-stream tasks (RX + TX + reopen).
    let stream_tasks: Vec<_> = opened
        .into_iter()
        .zip(tx_receivers)
        .enumerate()
        .map(|(idx, (rw, tx_queue))| {
            tokio::spawn(run_stream(
                idx,
                rw,
                tx_queue,
                rx_sink_tx.clone(),
                telemetry.clone(),
                dialer.clone(),
            ))
        })
        .collect();
    drop(rx_sink_tx);

    let telem_task = spawn_telem_task(telemetry.clone(), status_tx.clone());

    // Death watcher (ticks 1 s). Tears the session down when:
    //  - ALL streams are dead for ALL_STREAMS_DEAD_TIMEOUT_SECS. A single dead
    //    stream is NOT a reason — its task reopens it alone; tearing down all
    //    N on any single death produced synchronized N-stream reconnect bursts
    //    that carrier-DPI fingerprints (pcap A/B vs v0.22.4);
    //  - the device just woke up (P6): the wall clock jumped while monotonic
    //    timers were stopped, and the server has likely dropped the session —
    //    reconnect now instead of sitting on a dead tunnel for 90 s;
    //  - a stream hit a fatal error (revoked access, certificate, clock).
    // The watcher does NOT publish health — telem_task's derive_health() is
    // the single source of truth (I1 fix, v0.26.22).
    let (dead_watcher_tx, mut dead_watcher_rx) = tokio::sync::oneshot::channel::<anyhow::Error>();
    let dead_watcher = {
        let tele = telemetry.clone();
        let status_tx_w = status_tx.clone();
        tokio::spawn(async move {
            let mut dead_streak_secs: u32 = 0;
            let mut last_wall = SystemTime::now();
            loop {
                tokio::time::sleep(Duration::from_secs(1)).await;
                let now_wall = SystemTime::now();
                let slept = now_wall
                    .duration_since(last_wall)
                    .is_ok_and(|d| d > SLEEP_JUMP);
                last_wall = now_wall;
                if slept {
                    tracing::warn!(category = "tunnel", event = "wake", "device woke from sleep — reconnecting");
                    let _ = dead_watcher_tx.send(anyhow::anyhow!("device woke from sleep"));
                    return;
                }
                if let Some(chain) = tele.fatal.get() {
                    let _ = dead_watcher_tx.send(anyhow::anyhow!("{}", chain));
                    return;
                }
                let alive = (0..n_streams)
                    .filter(|i| tele.streams_alive[*i].load(Ordering::Relaxed))
                    .count();
                if alive > 0 {
                    dead_streak_secs = 0;
                    continue;
                }
                dead_streak_secs += 1;
                if dead_streak_secs >= crate::ALL_STREAMS_DEAD_TIMEOUT_SECS {
                    let kind = disconnect_kind_label(tele.disconnect_kind.load(Ordering::Relaxed));
                    tracing::warn!(
                        category = "tunnel",
                        event = "all_streams_dead",
                        streak_secs = dead_streak_secs as u64,
                        n_streams = n_streams as u64,
                        err_kind = %kind,
                        "death watcher: 0/{} streams alive — triggering reconnect",
                        n_streams,
                    );
                    let mut f = status_tx_w.borrow().clone();
                    f.last_error = Some(format!("all streams dead ({}s)", dead_streak_secs));
                    let _ = status_tx_w.send(f);
                    let _ = dead_watcher_tx.send(anyhow::anyhow!("all streams dead ({})", kind));
                    return;
                }
            }
        })
    };

    // Shutdown flag poll.
    let shutdown_poll = {
        let tele = telemetry.clone();
        async move {
            loop {
                // v0.25.1 (W3-8): Acquire matches the SeqCst writers.
                if tele.shutdown.load(Ordering::Acquire) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    };

    // Recycle trigger future. Pinned so the select! arm can be `&mut`-borrowed.
    //   - both disabled → park on `pending()` forever
    //   - `dpi_recycle_secs > 0` → fire at fixed interval
    //   - `dpi_recycle_bytes > 0` → poll telemetry every 500 ms, fire when
    //     bytes_rx + bytes_tx crosses the threshold
    //   - both set → whichever trips first wins
    let recycle_tele = telemetry.clone();
    let recycle_trigger = async move {
        let time_arm = async {
            match dpi_recycle_secs {
                Some(s) if s > 0 => {
                    tokio::time::sleep(Duration::from_secs(s as u64)).await;
                    "time"
                }
                _ => std::future::pending::<&'static str>().await,
            }
        };
        let bytes_arm = async {
            match dpi_recycle_bytes {
                Some(cap) if cap > 0 => loop {
                    tokio::time::sleep(Duration::from_millis(500)).await;
                    let rx = recycle_tele.bytes_rx.load(Ordering::Relaxed);
                    let tx = recycle_tele.bytes_tx.load(Ordering::Relaxed);
                    if rx.saturating_add(tx) >= cap {
                        break "bytes";
                    }
                },
                _ => std::future::pending::<&'static str>().await,
            }
        };
        tokio::select! {
            r = time_arm => r,
            r = bytes_arm => r,
        }
    };
    tokio::pin!(recycle_trigger);

    // `None` = explicit stop; otherwise the cause handed back to the supervisor.
    let exit_err: Option<anyhow::Error> = tokio::select! {
        _ = crate::wait_cancelled(&mut cancel) => {
            telemetry.disconnect_kind.store(KIND_USER_DISCONNECT, Ordering::Relaxed);
            tracing::info!(
                category = "tunnel",
                reason = "user",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "disconnect"
            );
            telemetry.shutdown.store(true, Ordering::SeqCst);
            None
        }
        _ = shutdown_poll => {
            tracing::info!(
                category = "tunnel",
                reason = "shutdown_flag",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "disconnect"
            );
            None
        }
        _ = &mut forwarder_dead_rx => {
            telemetry.disconnect_kind.store(KIND_RX_FORWARDER_DEAD, Ordering::Relaxed);
            tracing::error!(
                category = "tunnel",
                reason = "rx_forwarder_dead",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "RX forwarder timed out on TUN write — disconnecting"
            );
            Some(anyhow::anyhow!("rx_forwarder dead — TUN write blocked"))
        }
        res = &mut dead_watcher_rx => {
            tracing::warn!(category = "tunnel", event = "death_watcher.teardown", "drive_tunnel exiting");
            Some(res.unwrap_or_else(|_| anyhow::anyhow!("death watcher gone")))
        }
        _ = &mut dispatcher => {
            // The TUN reader closed: the uplink is gone. Reconnect instead of
            // zombie-ing. On a clean stop the cancel/shutdown arm wins first.
            tracing::error!(
                category = "tunnel",
                reason = "dispatcher_ended",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "TUN→stream dispatcher ended — TX path gone, disconnecting"
            );
            Some(anyhow::anyhow!("dispatcher ended — TX path gone"))
        }
        kind = &mut recycle_trigger => {
            tracing::warn!(
                category = "tunnel",
                reason = "recycle.deadline",
                trigger = kind,
                recycle_secs = dpi_recycle_secs.unwrap_or(0) as u64,
                recycle_bytes_cap = dpi_recycle_bytes.unwrap_or(0),
                bytes_rx = telemetry.bytes_rx.load(Ordering::Relaxed),
                bytes_tx = telemetry.bytes_tx.load(Ordering::Relaxed),
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "DPI recycle — session refresh"
            );
            // Sentinel prefix recognised by the supervisor: reconnect at once.
            Some(anyhow::anyhow!("recycle requested — DPI session refresh"))
        }
    };

    telemetry.tls_state.store(TLS_CLOSING, Ordering::Relaxed);
    tracing::debug!(
        category = "tunnel",
        tls_state = %tls_state_label(TLS_CLOSING),
        tx_dropped = telemetry.tx_dropped.load(Ordering::Relaxed),
        "teardown.start"
    );

    for h in stream_tasks {
        h.abort();
    }
    telem_task.abort();
    dead_watcher.abort();
    dispatcher.abort();
    rx_forwarder.abort();

    tokio::time::sleep(Duration::from_millis(50)).await;
    telemetry.tls_state.store(TLS_CLOSED, Ordering::Relaxed);
    tracing::debug!(category = "tunnel", tls_state = %tls_state_label(TLS_CLOSED), "teardown.complete");

    match exit_err {
        Some(e) => Err(e),
        None => Ok(()),
    }
}

#[cfg(test)]
mod death_watcher_tests {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    /// Mirror of the production death-watcher rule (v0.27.1 — B2 degraded-teardown
    /// REVERTED): the streak advances ONLY while `alive == 0`; a teardown fires
    /// once it reaches `ALL_STREAMS_DEAD_TIMEOUT_SECS`. A partial (alive>0) death
    /// resets the streak and never tears down. Returns (streak, torn_down) after
    /// `ticks` iterations over a fixed `alive` snapshot.
    fn run_watcher(alive: &[Arc<AtomicBool>], ticks: u32) -> (u32, bool) {
        let mut dead_streak_secs = 0u32;
        let mut torn_down = false;
        for _ in 0..ticks {
            let count = alive.iter().filter(|a| a.load(Ordering::Relaxed)).count();
            if count == 0 {
                dead_streak_secs += 1;
                if dead_streak_secs >= crate::ALL_STREAMS_DEAD_TIMEOUT_SECS {
                    torn_down = true;
                    break;
                }
            } else {
                dead_streak_secs = 0;
            }
        }
        (dead_streak_secs, torn_down)
    }

    #[tokio::test]
    async fn all_streams_dead_triggers_teardown_within_threshold() {
        let alive: Vec<Arc<AtomicBool>> =
            (0..4).map(|_| Arc::new(AtomicBool::new(false))).collect();
        let (streak, torn_down) = run_watcher(&alive, 5);
        assert!(torn_down, "0/4 alive must trigger teardown");
        assert!(streak >= crate::ALL_STREAMS_DEAD_TIMEOUT_SECS);
    }

    /// v0.27.1 (DPI fix): PARTIAL death (one stream down, others alive) must NOT
    /// tear down — the dead stream is reopened on its own.
    #[tokio::test]
    async fn partial_death_does_not_tear_down() {
        let alive: Vec<Arc<AtomicBool>> =
            (0..4).map(|_| Arc::new(AtomicBool::new(true))).collect();
        alive[2].store(false, Ordering::Relaxed); // 3/4 alive — degraded, must survive
        let (streak, torn_down) = run_watcher(&alive, 10);
        assert!(!torn_down, "3/4 alive (one stream dead) must NOT tear down");
        assert_eq!(streak, 0, "partial death keeps the all-dead streak at zero");
    }

    /// Full health (all N alive) never tears down and keeps the streak at zero.
    #[tokio::test]
    async fn full_health_never_tears_down() {
        let alive: Vec<Arc<AtomicBool>> =
            (0..4).map(|_| Arc::new(AtomicBool::new(true))).collect();
        let (streak, torn_down) = run_watcher(&alive, 10);
        assert!(!torn_down, "4/4 alive must never tear down");
        assert_eq!(streak, 0);
    }
}
