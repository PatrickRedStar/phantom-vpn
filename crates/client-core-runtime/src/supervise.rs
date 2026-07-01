//! Tunnel supervisor FSM with exponential backoff reconnect.
//!
//! `supervise()` runs one `drive_tunnel()` attempt at a time and, on failure,
//! sleeps a backoff delay before retrying. An explicit `cancel`
//! `watch::Receiver<bool>` interrupts any pending sleep (issued by the
//! caller on explicit disconnect; survives missed signals because `watch`
//! stores the latest value).

use anyhow::Context;
use bytes::Bytes;
use std::net::SocketAddr;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Instant;

use client_common::helpers;
use client_common::{tls_connect, tls_connect_with_tcp, tls_rx_loop, tls_tx_loop, write_handshake};
use ghoststream_gui_ipc::{ConnState, ConnectProfile, StatusFrame, TunnelSettings};
use phantom_core::wire::{flow_stream_idx, n_data_streams_with_override};
use tokio::sync::{watch, Mutex};

use crate::log_bridge::{packet_rx_log_sample_should_emit, packet_tx_log_sample_should_emit};
use crate::telemetry::{
    classify_error, disconnect_kind_label, spawn_telem_task, tls_state_label, Telemetry,
    KIND_RX_FORWARDER_DEAD, KIND_USER_DISCONNECT, TLS_CLOSED, TLS_CLOSING, TLS_ESTABLISHED,
    TLS_HANDSHAKING,
};
use crate::{ProtectSocket, MAX_ATTEMPTS};

/// Callback invoked by `supervise()` each attempt to create fresh TUN I/O
/// channels. Returns `(packet_reader, packet_writer)` — the same pair that
/// `phantom_core::tun_uring::spawn()` or `tun_simple::spawn()` returns.
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
    let mut attempt: u32 = 0;
    let mut last_error_str: Option<String> = None;
    // v0.26.5: removed W3-7 peak_rate_rx_bps carry. The v0.25.1 throttle
    // detector compared current RX vs lifetime peak; carrying peak across
    // reconnect was the only way to keep classification stable. The new
    // TSPU-128 signature detector is stateful in `telem_task` only (counter
    // of in-band ticks) and intentionally re-earns Throttled after every
    // reconnect — fresh tunnel, fresh evaluation.

    loop {
        // Surface Connecting / Reconnecting to GUI.
        {
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

        let cfg = match client_common::helpers::parse_conn_string(&profile.conn_string) {
            Ok(c) => c,
            Err(e) => {
                // SEC-R2-N06: only the top-level context — never the full chain.
                // `format!("{:#}", e)` can leak raw bytes through
                // `base64::DecodeError` and `FromUtf8Error` Display impls
                // which surface offset/surrounding bytes from invalid PEM.
                fail(&status_tx, format!("parse conn_string: {}", e), "parse_conn_string");
                break;
            }
        };
        // settings.profile.loaded — fired once per attempt (cheap, signals
        // reload after a reconnect re-parsed conn_string).
        tracing::info!(
            category = "settings",
            name = %profile.name,
            server = %cfg.network.server_addr,
            sni = %cfg.network.server_name.as_deref().unwrap_or(""),
            "profile.loaded"
        );

        let raw_addr = client_common::with_default_port(&cfg.network.server_addr, 443);
        let server_addr: SocketAddr = match raw_addr.parse() {
            Ok(a) => a,
            Err(_) => match tokio::net::lookup_host(&raw_addr).await {
                Ok(it) => {
                    // v0.25.0: prefer IPv4 — наши серверы v4-only, на IPv6-only
                    // сетях (T-Mobile US, Иран) `it.next()` без фильтра может
                    // выдать IPv6 → TCP connect timeout. Берём v4 если есть.
                    // Bug #9.
                    let all: Vec<SocketAddr> = it.collect();
                    let v4 = all.iter().find(|a| a.is_ipv4()).copied();
                    let v6 = all.iter().find(|a| a.is_ipv6()).copied();
                    let chosen = v4.or(v6);
                    if let Some(a) = chosen {
                        let v4_count = all.iter().filter(|a| a.is_ipv4()).count() as u64;
                        let v6_count = all.iter().filter(|a| a.is_ipv6()).count() as u64;
                        tracing::info!(
                            category = "network",
                            event = "dns.resolved",
                            host = %raw_addr,
                            chosen = %a,
                            v4_count = v4_count,
                            v6_count = v6_count,
                            stack = if a.is_ipv4() { "v4" } else { "v6" },
                            "DNS resolved"
                        );
                        a
                    } else {
                        let msg = format!("no DNS results for {}", raw_addr);
                        last_error_str = Some(msg.clone());
                        fail(&status_tx, msg, "dns_lookup");
                        if !should_reconnect(&settings, &status_tx, &mut cancel, attempt, last_error_str.as_deref()).await {
                            break;
                        }
                        attempt += 1;
                        continue;
                    }
                }
                Err(e) => {
                    let msg = format!("DNS lookup: {}", e);
                    last_error_str = Some(msg.clone());
                    fail(&status_tx, msg, "dns_lookup");
                    if !should_reconnect(&settings, &status_tx, &mut cancel, attempt, last_error_str.as_deref()).await {
                        break;
                    }
                    attempt += 1;
                    continue;
                }
            },
        };

        let client_identity = match helpers::load_tls_identity(&cfg) {
            Ok(v) => v,
            Err(e) => {
                fail(&status_tx, format!("tls identity: {:#}", e), "tls_identity");
                break;
            }
        };
        let server_ca = match helpers::load_server_ca(&cfg) {
            Ok(v) => v,
            Err(e) => {
                fail(&status_tx, format!("server CA: {:#}", e), "server_ca");
                break;
            }
        };

        let tun_addr = cfg.network.tun_addr.clone().unwrap_or_default();
        let sni = cfg.network.server_name.clone().unwrap_or_default();
        let n_streams = n_data_streams_with_override(settings.streams);

        let telemetry = Arc::new(Telemetry::new(
            n_streams,
            tun_addr.clone(),
            server_addr.to_string(),
            sni.clone(),
        ));
        *shared_telem.lock().await = Some(telemetry.clone());

        if attempt == 0 {
            // tunnel.start: lifecycle event for the very first attempt.
            tracing::info!(
                category = "tunnel",
                profile_id = %profile.name,
                server = %server_addr,
                sni = %cfg.network.server_name.as_deref().unwrap_or(""),
                streams = n_streams as u64,
                "start"
            );
        } else {
            // tunnel.reconnect.attempt — retrying after a previous drop.
            tracing::info!(
                category = "tunnel",
                attempt = attempt as u64,
                "reconnect.attempt"
            );
        }

        // Instantiate TUN I/O for this attempt.
        let tun_channels = match tun_factory() {
            Ok(ch) => ch,
            Err(e) => {
                fail(&status_tx, format!("tun factory: {:#}", e), "tun_factory");
                *shared_telem.lock().await = None;
                break;
            }
        };

        let result = drive_tunnel(
            cfg,
            server_addr,
            server_ca,
            client_identity,
            status_tx.clone(),
            telemetry.clone(),
            tun_channels,
            n_streams,
            protect_socket.clone(),
            cancel.clone(),
            settings.dpi_recycle_secs,
            settings.dpi_recycle_bytes,
        )
        .await;

        let explicit_shutdown = telemetry.shutdown.load(Ordering::SeqCst);
        *shared_telem.lock().await = None;

        match &result {
            Ok(()) => {
                // v0.25.0: clear any residual error from prior failed attempts
                // so the next failure starts fresh (and
                // `should_reconnect`/`f.last_error` aren't polluted from
                // earlier attempts). `drive_tunnel` Ok means we successfully
                // ran the Connected loop until either explicit shutdown or a
                // clean drop — either way, prior errors are no longer relevant.
                last_error_str = None;
                tracing::info!(
                    category = "tunnel",
                    reason = "clean",
                    "disconnect"
                );
            }
            Err(e) => {
                // SEC-R2-N06: top-level context only — see parse_conn_string note.
                let err_str = format!("{}", e);
                last_error_str = Some(err_str.clone());
                tracing::error!(
                    category = "tunnel",
                    phase = "drive",
                    error = %err_str,
                    err_kind = %disconnect_kind_label(classify_error(&err_str)),
                    "error"
                );
            }
        }

        if explicit_shutdown {
            tracing::info!(category = "tunnel", reason = "user", "disconnect");
            let mut f = status_tx.borrow().clone();
            f.state = ConnState::Disconnected;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
            let _ = status_tx.send(f);
            break;
        }

        // v0.27.0 (W10): DPI recycle path. drive_tunnel returned the
        // sentinel string when its periodic recycle timer fired. Skip the
        // attempt counter, last_error_str, status frame Error churn, and
        // backoff sleep — go straight to the next handshake. status_tx
        // already shows Connected from the live session, so the UI sees
        // no transitional flicker beyond the natural handshake latency.
        if matches!(&result, Err(e) if e.to_string().starts_with("recycle requested")) {
            tracing::info!(
                category = "tunnel",
                reason = "recycle",
                "session refreshed — reconnecting immediately"
            );
            last_error_str = None;
            attempt = 0;
            continue;
        }

        if let Err(e) = &result {
            let mut f = status_tx.borrow().clone();
            // SEC-R2-N06: see parse_conn_string note — top-level only.
            f.last_error = Some(format!("{}", e));
            let _ = status_tx.send(f);
        }

        if !should_reconnect(&settings, &status_tx, &mut cancel, attempt, last_error_str.as_deref()).await {
            // tunnel.reconnect.giveup — all retries exhausted (or auto_reconnect off).
            let last = last_error_str.clone().unwrap_or_default();
            tracing::error!(
                category = "tunnel",
                attempts = (attempt + 1) as u64,
                last_error = %last,
                err_kind = %disconnect_kind_label(classify_error(&last)),
                "reconnect.giveup"
            );
            let mut f = status_tx.borrow().clone();
            f.state = ConnState::Error;
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
            let _ = status_tx.send(f);
            break;
        }
        attempt += 1;
    }
}

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

/// Decide whether to keep retrying. Publishes countdown into `StatusFrame`
/// before sleeping so the GUI can show "reconnecting in N s".
///
/// Returns `false` when auto_reconnect is off, attempt count is exhausted, or
/// an explicit disconnect cancel arrived mid-sleep.
///
/// v0.25.1 (W3-2): `cancel` is a `watch::Receiver<bool>`. We use the
/// `wait_cancelled` helper to survive the case where `true` was already
/// stored before this function suspended on the channel — `Notify`'s
/// old `notified()` future missed that signal.
async fn should_reconnect(
    settings: &TunnelSettings,
    status_tx: &watch::Sender<StatusFrame>,
    cancel: &mut watch::Receiver<bool>,
    attempt: u32,
    last_error_str: Option<&str>,
) -> bool {
    if !settings.auto_reconnect {
        return false;
    }
    if attempt + 1 > MAX_ATTEMPTS {
        return false;
    }
    // v0.24.0: classify the error so we can override the generic backoff
    // table for common transient drops (hard reset, idle timeout, DNS) —
    // useful under TSPU "shaky network" conditions where the default
    // exponential backoff (1, 2, 5, 10, 20, 30 s) is still too slow on the
    // first attempt for a clean RST.
    let category = last_error_str
        .map(crate::classify_tunnel_error)
        .unwrap_or(crate::TunnelErrorCategory::Other);
    let delay = crate::reconnect_delay_secs(category, attempt);
    // tunnel.reconnect.scheduled — published *before* sleeping so the GUI
    // sees the upcoming delay even if cancel arrives mid-sleep.
    tracing::warn!(
        category = "tunnel",
        attempt = (attempt + 1) as u64,
        delay_secs = delay as u64,
        error_category = category.as_str(),
        "reconnect.scheduled"
    );

    // BUG FIX: publish the pending delay into StatusFrame *before* sleeping,
    // so the GUI can display a countdown rather than a blank/stale field.
    {
        let mut f = status_tx.borrow().clone();
        f.reconnect_next_delay_secs = Some(delay);
        let _ = status_tx.send(f);
    }

    let sleep = tokio::time::sleep(std::time::Duration::from_secs(delay as u64));
    tokio::pin!(sleep);
    tokio::select! {
        _ = &mut sleep => true,
        _ = crate::wait_cancelled(cancel) => {
            tracing::info!(category = "tunnel", reason = "user", "reconnect.cancelled");
            false
        }
    }
}

/// Pseudo-random ~50..149 ms backoff between per-stream handshake retries.
/// De-correlates concurrent re-dials (so a burst of simultaneous retries does
/// not present one synchronised fingerprint) without pulling in the `rand`
/// crate — `client-core-runtime` deliberately depends on tokio only. `idx` is
/// mixed in (Knuth multiplicative hash) so streams retrying in the same clock
/// tick — or on a coarse-resolution clock where `subsec_nanos` barely moves —
/// still diverge instead of collapsing onto one value.
fn stream_retry_jitter_ms(idx: usize) -> u64 {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let mixed = nanos ^ (idx as u32).wrapping_mul(2_654_435_761);
    50 + u64::from(mixed % 100)
}

/// Connect TLS streams, spawn I/O tasks, and run until shutdown or error.
///
/// Does NOT manage Linux-specific guards (DnsGuard, Ipv6Guard, RouteGuard) —
/// those remain in the linux-helper crate and are set up around this call.
async fn drive_tunnel(
    cfg: phantom_core::config::ClientConfig,
    server_addr: SocketAddr,
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(
        Vec<rustls::pki_types::CertificateDer<'static>>,
        rustls::pki_types::PrivateKeyDer<'static>,
    )>,
    status_tx: watch::Sender<StatusFrame>,
    telemetry: Arc<Telemetry>,
    tun_channels: (
        tokio::sync::mpsc::Receiver<Bytes>,
        tokio::sync::mpsc::Sender<Bytes>,
    ),
    n_streams: usize,
    protect_socket: Option<ProtectSocket>,
    mut cancel: watch::Receiver<bool>,
    // v0.27.0 (W10/W11): periodic session recycle to defeat net4people #490
    // silent-freeze. Two flavours:
    //  - `dpi_recycle_secs` (W10): time-based, fires every N seconds even
    //    when idle. Kept for debugging.
    //  - `dpi_recycle_bytes` (W11): byte-based, fires when bytes_rx +
    //    bytes_tx crosses N. Preferred — idle sessions don't get
    //    pointlessly recycled. Recommended value ≈ 100 KB (8 streams × ~14
    //    KB, just under the carrier's per-connection freeze threshold).
    // If both are set, whichever trips first wins. `None` / 0 = disabled.
    dpi_recycle_secs: Option<u32>,
    dpi_recycle_bytes: Option<u64>,
) -> anyhow::Result<()> {
    let client_tls =
        phantom_core::h2_transport::make_h2_client_tls(server_ca, client_identity)
            .context("build TLS client config")?;
    let server_name = cfg
        .network
        .server_name
        .as_deref()
        .unwrap_or("phantom")
        .to_string();

    // ── Cancellable handshake loop (CONC-C1) ──────────────────────────────
    //
    // The whole per-stream connect/TLS/H2-handshake sequence is wrapped in a
    // single `tokio::select!` against the supervisor's `cancel` watch. Without
    // this, a Disconnect issued while we were inside `TcpStream::connect`
    // could not be observed until the kernel's SYN_RETRIES (~75 s on macOS)
    // unblocked the call — the audit's bug‑bash #7 "Disconnect hangs 75 s".
    //
    // `tls_connect` / `tls_connect_with_tcp` are also bounded by the
    // `HANDSHAKE_TIMEOUT` from `client_common::tls_handshake`, giving us a
    // hard ceiling even when cancel never arrives.
    telemetry.tls_state.store(TLS_HANDSHAKING, Ordering::Relaxed);
    let handshake_fut = async {
        // CONC-A1/A2 (2026-06-13 TSPU fix): open streams CONCURRENTLY with
        // PER-STREAM RETRY instead of one sequential all-or-nothing loop.
        //
        // Under TSPU the handshake of *some* parallel streams is silently
        // blackholed and times out at HANDSHAKE_TIMEOUT (15 s). The old loop
        // opened streams one-by-one and propagated the first such failure with
        // `?`, discarding the streams that had already succeeded and forcing a
        // full reconnect — one dropped stream cost the whole attempt plus a
        // 15 s sequential stall. Now a failed stream is retried on a fresh
        // socket (the probabilistic drop almost always clears in 1-2 tries)
        // while the other streams handshake in parallel.
        //
        // INVARIANT PRESERVED — all N still required (no partial-quorum). The
        // data plane (`flow_stream_idx % n_streams` → `tx_senders[idx]`, and the
        // server's `effective_n`) assumes a full, contiguous `0..n_streams` set;
        // coming up partial would blackhole every flow hashing to a missing
        // index. If any stream is still down after its retries we return Err →
        // normal reconnect (no worse than before, just faster and far rarer).
        //
        // `open_one` opens ONE stream at a fixed `idx`, retrying on a fresh
        // socket with jitter. ADR 0008 §2: low-level handshake events
        // (`tcp.connect`, `tls.client_hello`, `tls.alpn_negotiated`) are emitted
        // by `client-common::tls_handshake::do_connect`; here we emit only the
        // per-stream events that need a `stream_id` correlator.
        let open_one = |idx: usize| {
            // Owned clones so the per-stream open future is Send + 'static and
            // self-contained (re-created per attempt). `server_addr` (SocketAddr)
            // and `n_streams` (usize) are Copy — the `async move` block captures
            // them by copy directly, no rebind needed.
            let server_name = server_name.clone();
            let client_tls = client_tls.clone();
            let protect_socket = protect_socket.clone();
            async move {
                // 1 initial attempt + 2 retries. (Retry fires only on a failed
                // dial — it's quieter on the wire than v0.22.4's full all-N
                // reconnect-on-any-stream-failure, and invisible on the happy
                // path. The streams themselves are opened SEQUENTIALLY by the
                // caller, so there is no synchronized SYN-burst — see below.)
                const STREAM_OPEN_RETRIES: u32 = 2;
                let mut last_err: Option<anyhow::Error> = None;
                for attempt in 0..=STREAM_OPEN_RETRIES {
                    if attempt > 0 {
                        tokio::time::sleep(std::time::Duration::from_millis(
                            stream_retry_jitter_ms(idx),
                        ))
                        .await;
                        tracing::debug!(
                            category = "handshake",
                            stream_id = idx as u64,
                            attempt = attempt as u64,
                            "stream.retry"
                        );
                    }
                    let attempt_res = async {
                        let (r, mut w) = if let Some(ref protect) = protect_socket {
                            // Android: create socket, protect it from VPN routing,
                            // then connect. protect(fd) MUST run for every socket
                            // including retries, else traffic loops back via tun.
                            let socket = if server_addr.is_ipv4() {
                                tokio::net::TcpSocket::new_v4()
                            } else {
                                tokio::net::TcpSocket::new_v6()
                            }
                            .with_context(|| format!("stream {} socket create", idx))?;

                            let fd = socket.as_raw_fd();
                            if !protect(fd) {
                                anyhow::bail!("stream {} VpnService.protect() failed", idx);
                            }

                            // Bound the raw TCP connect like the TLS phase does
                            // (tls_handshake::HANDSHAKE_TIMEOUT). Under the TSPU
                            // SYN-blackhole this fix targets, an unbounded connect()
                            // would block on kernel SYN_RETRIES (~75-130 s) and
                            // starve the per-stream retry below; the 15 s cap lets a
                            // dead SYN error out fast so the retry actually engages.
                            let tcp = tokio::time::timeout(
                                client_common::tls_handshake::HANDSHAKE_TIMEOUT,
                                socket.connect(server_addr),
                            )
                            .await
                            .with_context(|| format!("stream {} tcp connect timeout", idx))?
                            .with_context(|| format!("stream {} tcp connect", idx))?;

                            tls_connect_with_tcp(tcp, server_name.clone(), client_tls.clone())
                                .await
                                .with_context(|| format!("stream {} tls connect", idx))?
                        } else {
                            // Linux/iOS/macOS: no socket protection needed.
                            tls_connect(server_addr, server_name.clone(), client_tls.clone())
                                .await
                                .with_context(|| format!("stream {} tls connect", idx))?
                        };
                        tracing::debug!(
                            category = "handshake",
                            result = "ok",
                            subject = %server_name,
                            stream_id = idx as u64,
                            "mtls.cert_verify"
                        );
                        // Wire contract: the 2nd handshake byte is ALWAYS the full
                        // n_streams (never a live count). The server pins
                        // effective_n from it and evicts the session on mismatch.
                        write_handshake(&mut w, idx as u8, n_streams as u8)
                            .await
                            .with_context(|| format!("stream {} handshake", idx))?;
                        tracing::debug!(
                            category = "handshake",
                            max_concurrent = n_streams as u64,
                            initial_window = 0u64,
                            stream_id = idx as u64,
                            "h2.settings_sent"
                        );
                        anyhow::Ok((r, w))
                    }
                    .await;

                    match attempt_res {
                        Ok((r, w)) => {
                            let stream_priority = if idx == 0 { "high" } else { "normal" };
                            // stream.open — per ADR 0008 §2.
                            tracing::debug!(
                                category = "stream",
                                stream_id = idx as u64,
                                priority = %stream_priority,
                                "open"
                            );
                            return anyhow::Ok((idx, r, w));
                        }
                        Err(e) => {
                            tracing::warn!(
                                category = "handshake",
                                stream_id = idx as u64,
                                attempt = attempt as u64,
                                error = %format!("{:#}", e),
                                "stream.open_failed"
                            );
                            last_err = Some(e);
                        }
                    }
                }
                Err(last_err
                    .unwrap_or_else(|| anyhow::anyhow!("stream {} open failed", idx)))
            }
        };

        // v0.27.1 (DPI regression fix — restores v0.22.4): open streams STRICTLY
        // SEQUENTIALLY. Each stream's TCP+TLS+handshake fully completes before the
        // next is dialed, so the N ClientHellos are spread over their natural
        // RTT+handshake spacing — exactly like a browser progressively opening
        // connections. This replaces the concurrent JoinSet fan-out, which fired
        // 7 SYNs to one IP:port within ~25 ms — a synchronized SYN-burst that
        // carrier-DPI fingerprints as a VPN (the proven regression vs v0.22.4,
        // confirmed by pcap A/B: v0.22.4 spread 8 opens over ~6 s and was not
        // throttled). Stream 0 first also preserves the server coordinator /
        // mimicry-warmup ordering (warmup runs on stream_idx==0 && is_new).
        // Trade-off: full-Connected is a few RTTs slower than a burst, but this is
        // the proven DPI-evading behaviour. Per-stream retry inside `open_one`
        // still fires only on a failed dial (quieter than v0.22.4's
        // reconnect-all-N), invisible on the happy path.
        let mut opened = Vec::with_capacity(n_streams);
        for idx in 0..n_streams {
            opened.push(
                open_one(idx)
                    .await
                    .with_context(|| format!("stream {} handshake failed", idx))?,
            );
        }
        // Load-bearing invariant for the data plane: the dispatcher routes
        // `flow_stream_idx(pkt, n_streams) -> tx_senders[idx]` and the I/O spawn
        // loop binds idx by Vec position, so position MUST equal stream_idx. The
        // sequential open pushes in ascending idx order, so this already holds by
        // construction (no sort needed) — assert it so a future change (gapped or
        // short set) can't silently mis-route.
        debug_assert!(
            opened.len() == n_streams
                && opened.iter().enumerate().all(|(pos, (idx, _, _))| pos == *idx),
            "sequential open must yield a contiguous, sorted 0..n_streams stream set"
        );

        let mut tls_writers = Vec::with_capacity(n_streams);
        let mut tls_readers = Vec::with_capacity(n_streams);
        for (idx, r, w) in opened {
            // streams_alive set ONLY here, on final success of all N — never
            // mid-handshake — so the death-watcher / derive_health never observe
            // a transient or about-to-fail stream as alive.
            telemetry.streams_alive[idx].store(true, Ordering::Relaxed);
            tls_readers.push(r);
            tls_writers.push(w);
        }
        anyhow::Ok((tls_writers, tls_readers))
    };

    let (tls_writers, tls_readers) = tokio::select! {
        biased;
        _ = crate::wait_cancelled(&mut cancel) => {
            tracing::info!(
                category = "tunnel",
                phase = "handshake",
                "cancelled during handshake"
            );
            // Mark this as explicit shutdown so the supervisor exits cleanly
            // without retry. `telemetry.shutdown` is checked by the outer
            // `supervise` loop right after `drive_tunnel` returns.
            telemetry.shutdown.store(true, Ordering::SeqCst);
            anyhow::bail!("cancelled");
        }
        result = handshake_fut => result?,
    };
    telemetry.tls_state.store(TLS_ESTABLISHED, Ordering::Relaxed);
    // handshake.h2.ready — all streams complete the H2-equivalent setup.
    tracing::info!(
        category = "handshake",
        n_streams_open = n_streams as u64,
        tls_state = %tls_state_label(TLS_ESTABLISHED),
        "h2.ready"
    );
    // tunnel.connected — top-level lifecycle.
    tracing::info!(
        category = "tunnel",
        session_id = %format!("{:x}", telemetry.started_at.elapsed().as_nanos() as u64),
        negotiated_streams = n_streams as u64,
        "connected"
    );

    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
    let (mut tun_pkt_rx, tun_pkt_tx) = tun_channels;

    // Transition to Connected state.
    {
        let mut f = status_tx.borrow().clone();
        f.state = ConnState::Connected;
        f.n_streams = n_streams as u8;
        f.streams_up = n_streams as u8;
        f.tun_addr = Some(tun_addr.to_string());
        f.server_addr = Some(server_addr.to_string());
        f.sni = Some(server_name.clone());
        // v0.25.0: clear all per-attempt residue carried over from the previous
        // failed `drive_tunnel` iteration. Without this, the first frame after a
        // successful reconnect shows stale `last_rx_ms` (from previous session,
        // 60+ seconds ago) → derive_health flags Stale for 250-500 ms until
        // telem_task overwrites with fresh values. Also `last_error` from a
        // prior failed attempt stays in the frame until next failure — false
        // "DNS lookup failed" while we're actually Connected.
        f.last_rx_ms = 0;
        f.last_tx_ms = 0;
        f.idle_rx_secs = 0;
        f.last_error = None;
        f.reconnect_attempt = None;
        f.reconnect_next_delay_secs = None;
        f.health = ghoststream_gui_ipc::TunnelHealth::Healthy;
        f.bandwidth_class = ghoststream_gui_ipc::BandwidthClass::Normal;
        let _ = status_tx.send(f);
    }

    // Per-stream TX channels.
    let mut tx_senders: Vec<tokio::sync::mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
    let mut tx_receivers: Vec<tokio::sync::mpsc::Receiver<Bytes>> =
        Vec::with_capacity(n_streams);
    for _ in 0..n_streams {
        let (t, r) = tokio::sync::mpsc::channel::<Bytes>(2048);
        tx_senders.push(t);
        tx_receivers.push(r);
    }

    let (rx_sink_tx, mut rx_sink_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);

    // Dispatcher: TUN → per-stream channel.
    //
    // v0.27.1 (DPI regression fix — restores v0.22.4 semantics): NON-BLOCKING
    // `try_send` with drop-and-continue. A later "backpressure" rewrite to a
    // blocking `send().await` let ONE dead/full stream wedge ALL TX, which forced
    // the death-watcher to tear down + reconnect all N streams. Those repeated
    // synchronized N-stream reconnect bursts are a carrier-DPI VPN fingerprint
    // (proven by pcap A/B: v0.22.4 stayed quiet, HEAD got throttled). With
    // `try_send`, a dead/slow stream's flow simply drops its packets (TCP inside
    // the tunnel retransmits) while the other streams keep flowing — quiet on the
    // wire, exactly as v0.22.4 did. The dispatcher now only ends when the TUN
    // reader closes (`tun_pkt_rx` drained = shutdown/teardown).
    let tx_senders_clone = tx_senders.clone();
    let tele = telemetry.clone();
    let mut dispatcher = tokio::spawn(async move {
        // packet.tx.batch is sampled 1/N (default 100) to keep verbose logs
        // tractable. Counter is per-process inside `log_bridge`.
        let mut first_tx_logged: [bool; 16] = [false; 16];
        while let Some(pkt) = tun_pkt_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams);
            let len = pkt.len() as u64;
            // stream.first_packet_tx — once per stream lifetime.
            if idx < first_tx_logged.len() && !first_tx_logged[idx] {
                first_tx_logged[idx] = true;
                tracing::trace!(
                    category = "stream",
                    stream_id = idx as u64,
                    bytes = len,
                    "first_packet_tx"
                );
            }
            // Full or closed channel (slow/dead stream) → drop this flow's
            // packet and keep dispatching the rest. NEVER wedge all TX on one
            // bad stream (that was the root cause of the death-watcher churn).
            if tx_senders_clone[idx].try_send(pkt).is_ok() {
                tele.bytes_tx.fetch_add(len, Ordering::Relaxed);
                tele.stream_tx_bytes[idx].fetch_add(len, Ordering::Relaxed);
                // packet.tx.batch — sampled (default 1/100).
                if packet_tx_log_sample_should_emit() {
                    tracing::trace!(
                        category = "packet",
                        n_pkts = 1u64,
                        bytes = len,
                        stream_id = idx as u64,
                        "tx.batch"
                    );
                }
            }
        }
    });
    drop(tx_senders);

    // RX sink forwarder: count bytes then push into TUN writer.
    //
    // v0.25.1 (W3-1): a TUN writer that stops accepting (fd closed, OS hung,
    // VpnService teardown half-way) used to make `tun_write_tx.send().await`
    // block forever — and because the forwarder also held the rx_sink_rx
    // receiver, the per-stream RX loops could not drain either. The whole
    // tunnel froze with no visible signal. We now timeout the TUN write at
    // 5 s and, on expiry, signal `forwarder_dead_tx` so the supervisor
    // tears down and reconnects. 5 s is generous: TUN buffer-full normally
    // clears in ms; anything longer is structurally broken.
    let (forwarder_dead_tx, mut forwarder_dead_rx) =
        tokio::sync::oneshot::channel::<()>();
    // v0.26.21: death watcher → drive_tunnel teardown channel.
    // Отдельный от forwarder_dead_tx (тот владеется rx_forwarder'ом).
    let (dead_watcher_tx, mut dead_watcher_rx) =
        tokio::sync::oneshot::channel::<()>();
    let tun_write_tx = tun_pkt_tx.clone();
    let tele_rx = telemetry.clone();
    let rx_forwarder = tokio::spawn(async move {
        while let Some(pkt) = rx_sink_rx.recv().await {
            let len = pkt.len() as u64;
            tele_rx.bytes_rx.fetch_add(len, Ordering::Relaxed);
            match tokio::time::timeout(
                std::time::Duration::from_secs(5),
                tun_write_tx.send(pkt),
            )
            .await
            {
                Ok(Ok(())) => {}
                Ok(Err(_send_err)) => {
                    // TUN writer dropped — clean teardown path, not deadlock.
                    return;
                }
                Err(_elapsed) => {
                    // TUN writer hung for 5 s → forwarder is unresponsive.
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
                tracing::trace!(
                    category = "packet",
                    n_pkts = 1u64,
                    bytes = len,
                    "rx.batch"
                );
            }
        }
    });
    drop(tun_pkt_tx);

    // Per-stream TX + RX tasks.
    let mut tx_handles = Vec::with_capacity(n_streams);
    let mut rx_handles = Vec::with_capacity(n_streams);
    let stream_started_at = Instant::now();
    for (idx, (w, rxc)) in tls_writers
        .into_iter()
        .zip(tx_receivers.into_iter())
        .enumerate()
    {
        let tele = telemetry.clone();
        let started_at = stream_started_at;
        tx_handles.push(tokio::spawn(async move {
            let res = tls_tx_loop(w, rxc).await;
            tele.streams_alive[idx].store(false, Ordering::Relaxed);
            let lifetime_ms = started_at.elapsed().as_millis() as u64;
            match &res {
                Ok(()) => tracing::debug!(
                    category = "stream",
                    stream_id = idx as u64,
                    reason = "tx_ended",
                    lifetime_ms,
                    "close"
                ),
                Err(e) => {
                    // v0.27.0 W4-3: classify + record so tunnel teardown can
                    // surface "h2_goaway", "tcp_reset" etc. as the cause.
                    let err_str = format!("{}", e);
                    let kind = classify_error(&err_str);
                    tele.disconnect_kind.store(kind, Ordering::Relaxed);
                    tele.last_failed_stream.store(idx as i8, Ordering::Relaxed);
                    tracing::warn!(
                        category = "stream",
                        stream_id = idx as u64,
                        error = %err_str,
                        err_kind = %disconnect_kind_label(kind),
                        "kill"
                    );
                }
            }
            res
        }));
    }
    for (idx, r) in tls_readers.into_iter().enumerate() {
        let sink = rx_sink_tx.clone();
        let tele = telemetry.clone();
        let started_at = stream_started_at;
        rx_handles.push(tokio::spawn(async move {
            let res = tls_rx_loop(
                r,
                sink,
                Some(std::time::Duration::from_secs(
                    crate::RX_IDLE_TIMEOUT_SECS as u64,
                )),
            )
            .await;
            tele.streams_alive[idx].store(false, Ordering::Relaxed);
            let lifetime_ms = started_at.elapsed().as_millis() as u64;
            match &res {
                Ok(()) => tracing::debug!(
                    category = "stream",
                    stream_id = idx as u64,
                    reason = "rx_ended",
                    lifetime_ms,
                    "close"
                ),
                Err(e) => {
                    // v0.27.0 W4-3: classify + record so tunnel teardown can
                    // surface "h2_goaway", "tcp_reset" etc. as the cause.
                    let err_str = format!("{}", e);
                    let kind = classify_error(&err_str);
                    tele.disconnect_kind.store(kind, Ordering::Relaxed);
                    tele.last_failed_stream.store(idx as i8, Ordering::Relaxed);
                    tracing::warn!(
                        category = "stream",
                        stream_id = idx as u64,
                        error = %err_str,
                        err_kind = %disconnect_kind_label(kind),
                        "kill"
                    );
                }
            }
            res
        }));
    }
    drop(rx_sink_tx);

    // Telemetry task.
    let telem_task = spawn_telem_task(telemetry.clone(), status_tx.clone());

    // Death watcher (v0.26.21; B2 degraded-teardown REVERTED in v0.27.1 DPI fix):
    // reconnect ONLY when ALL streams are dead (alive == 0) for
    // ALL_STREAMS_DEAD_TIMEOUT_SECS. A single dead/degraded stream is NOT torn
    // down — its flow simply drops (dispatcher uses try_send drop-and-continue),
    // exactly like v0.22.4. Tearing the whole session down + reconnecting all N
    // on ANY single stream death (the B2 behaviour) produced repeated
    // synchronized N-stream reconnect bursts, which carrier-DPI fingerprints as a
    // VPN (proven by pcap A/B vs v0.22.4). honest-state is preserved:
    // derive_health still renders Degraded/Dead from streams_alive; we just don't
    // churn the wire on transient single-stream drops. NOTE: nothing ACTS on
    // Degraded anymore — a partially-dead tunnel keeps running (flows hashed to
    // dead streams drop, TCP-in-tunnel retransmits) until alive hits 0, when this
    // watcher reconnects all N. That is the accepted v0.22.4 behaviour.
    //
    // I1 fix (v0.26.22): watcher does NOT publish StatusFrame health — telem_task's
    // derive_health() is the single source of truth.
    let dead_watcher = {
        let tele = telemetry.clone();
        let status_tx_w = status_tx.clone();
        let n_streams = n_streams;
        let dead_tx = dead_watcher_tx; // moved into task
        tokio::spawn(async move {
            let mut dead_streak_secs: u32 = 0;
            loop {
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                let alive = (0..n_streams)
                    .filter(|i| tele.streams_alive[*i].load(Ordering::Relaxed))
                    .count();

                if alive == 0 {
                    dead_streak_secs += 1;
                    if dead_streak_secs >= crate::ALL_STREAMS_DEAD_TIMEOUT_SECS {
                        tracing::warn!(
                            category = "tunnel",
                            event = "all_streams_dead",
                            streak_secs = dead_streak_secs as u64,
                            n_streams = n_streams as u64,
                            "death watcher: 0/{} streams alive — triggering reconnect",
                            n_streams,
                        );
                        let mut f = status_tx_w.borrow().clone();
                        f.last_error = Some(format!("all streams dead ({}s)", dead_streak_secs));
                        let _ = status_tx_w.send(f);
                        let _ = dead_tx.send(()); // signal supervisor select!
                        return;
                    }
                } else {
                    dead_streak_secs = 0;
                }
            }
        })
    };

    // Shutdown flag poll.
    let shutdown_poll = {
        let tele = telemetry.clone();
        async move {
            loop {
                // v0.25.1 (W3-8): Acquire matches the SeqCst Release used by
                // the writers (Manager::disconnect, supervisor cancel arm).
                // Relaxed could let this poll observe a stale `false` after
                // a writer has committed `true` — Acquire makes the cross-
                // task signal trivially correct.
                if tele.shutdown.load(Ordering::Acquire) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        }
    };

    // v0.25.1 (W3-1): track whether the forwarder timed out so we can
    // return Err *after* teardown completes — otherwise the supervisor sees
    // Ok(()) and the user-facing "everything is fine" path runs even though
    // the TUN side froze and we triggered an internal reconnect.
    let mut forwarder_dead = false;
    // v0.26.21: death watcher detected all streams dead — surface as Err so
    // the supervisor reconnects (analogous to `forwarder_dead`).
    let mut all_streams_dead = false;
    // v0.27.0 (B3): dispatcher (TUN→stream) ended mid-session — the TX path is
    // gone. Since v0.27.1 the dispatcher's `try_send` never breaks on a stream,
    // so this only fires when the TUN reader closes `tun_pkt_tx` (genuine uplink
    // loss). Surface as Err so the supervisor reconnects instead of sitting
    // "connected" with a wedged uplink. On a clean stop the shutdown/cancel arm
    // wins first and the outer loop breaks on `explicit_shutdown` regardless.
    let mut dispatcher_died = false;
    // v0.27.0 (W10): track whether the periodic DPI-recycle timer fired so
    // we can return a sentinel Err that the supervisor recognises as
    // "intentional, reconnect immediately, don't bump the attempt counter".
    let mut recycle_fired = false;

    // Recycle trigger future. Pinned so the select! arm can be `&mut`-borrowed
    // alongside the other arms. Three modes:
    //   - both `dpi_recycle_secs` and `dpi_recycle_bytes` disabled → park on
    //     `pending()` forever (zero overhead, future is never polled)
    //   - `dpi_recycle_secs > 0` → fire at fixed wall-clock interval
    //   - `dpi_recycle_bytes > 0` → poll telemetry every 500 ms, fire when
    //     bytes_rx + bytes_tx crosses the threshold
    //   - both set → whichever trips first wins (select_either-style race
    //     baked into the closure with `tokio::select!{ ... }`)
    let recycle_tele = telemetry.clone();
    let recycle_trigger = async move {
        let time_arm = async {
            match dpi_recycle_secs {
                Some(s) if s > 0 => {
                    tokio::time::sleep(std::time::Duration::from_secs(s as u64)).await;
                    "time"
                }
                _ => std::future::pending::<&'static str>().await,
            }
        };
        let bytes_arm = async {
            match dpi_recycle_bytes {
                Some(cap) if cap > 0 => loop {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
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

    tokio::select! {
        _ = crate::wait_cancelled(&mut cancel) => {
            telemetry.disconnect_kind.store(KIND_USER_DISCONNECT, Ordering::Relaxed);
            tracing::info!(
                category = "tunnel",
                reason = "user",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "disconnect"
            );
            telemetry.shutdown.store(true, Ordering::SeqCst);
        }
        _ = shutdown_poll => {
            tracing::info!(
                category = "tunnel",
                reason = "shutdown_flag",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "disconnect"
            );
        }
        _ = &mut forwarder_dead_rx => {
            // v0.25.1 (W3-1): rx_forwarder timed out on TUN write — the
            // packet-IO side is structurally hung. Force reconnect.
            telemetry.disconnect_kind.store(KIND_RX_FORWARDER_DEAD, Ordering::Relaxed);
            tracing::error!(
                category = "tunnel",
                reason = "rx_forwarder_dead",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "RX forwarder timed out on TUN write — disconnecting"
            );
            forwarder_dead = true;
        }
        _ = &mut dead_watcher_rx => {
            // v0.26.21: death watcher детектил streams_up==0.
            // last_error выставлен watcher'ом; health придёт от derive_health
            // через telem_task (single source of truth). Возвращаем Err чтобы
            // supervisor вышел из drive_tunnel и запустил reconnect.
            tracing::warn!(
                category = "tunnel",
                event = "death_watcher.teardown",
                "drive_tunnel exiting — all streams dead"
            );
            all_streams_dead = true;
        }
        res = &mut dispatcher => {
            // v0.27.0 (B3): dispatcher task ended — the TUN reader closed
            // `tun_pkt_tx` (try_send never breaks the dispatcher on a stream).
            // The uplink is gone. Reconnect instead of zombie-ing.
            let _ = res;
            tracing::error!(
                category = "tunnel",
                reason = "dispatcher_ended",
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "TUN→stream dispatcher ended — TX path gone, disconnecting"
            );
            dispatcher_died = true;
        }
        kind = &mut recycle_trigger => {
            // v0.27.0 (W10/W11): periodic recycle fired. `kind` is "time"
            // or "bytes" depending on which arm of the trigger won. The
            // supervisor sees the sentinel Err and reconnects with
            // attempt counter reset.
            let cur_rx = telemetry.bytes_rx.load(Ordering::Relaxed);
            let cur_tx = telemetry.bytes_tx.load(Ordering::Relaxed);
            tracing::warn!(
                category = "tunnel",
                reason = "recycle.deadline",
                trigger = kind,
                recycle_secs = dpi_recycle_secs.unwrap_or(0) as u64,
                recycle_bytes_cap = dpi_recycle_bytes.unwrap_or(0),
                bytes_rx = cur_rx,
                bytes_tx = cur_tx,
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                "DPI recycle — session refresh"
            );
            recycle_fired = true;
        }
        _ = async {
            for h in &mut tx_handles { let _ = h.await; }
        } => {
            let kind = telemetry.disconnect_kind.load(Ordering::Relaxed);
            let failed_stream = telemetry.last_failed_stream.load(Ordering::Relaxed);
            let bytes_rx_since_start = telemetry.bytes_rx.load(Ordering::Relaxed);
            tracing::warn!(
                category = "tunnel",
                reason = "tx_drained",
                err_kind = %disconnect_kind_label(kind),
                failed_stream,
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                bytes_rx_since_start,
                "disconnect"
            );
        }
        _ = async {
            for h in &mut rx_handles { let _ = h.await; }
        } => {
            let kind = telemetry.disconnect_kind.load(Ordering::Relaxed);
            let failed_stream = telemetry.last_failed_stream.load(Ordering::Relaxed);
            let bytes_rx_since_start = telemetry.bytes_rx.load(Ordering::Relaxed);
            tracing::warn!(
                category = "tunnel",
                reason = "rx_drained",
                err_kind = %disconnect_kind_label(kind),
                failed_stream,
                tls_state = %tls_state_label(telemetry.tls_state.load(Ordering::Relaxed)),
                bytes_rx_since_start,
                "disconnect"
            );
        }
    }

    telemetry.tls_state.store(TLS_CLOSING, Ordering::Relaxed);
    tracing::debug!(
        category = "tunnel",
        tls_state = %tls_state_label(TLS_CLOSING),
        "teardown.start"
    );

    for h in tx_handles {
        h.abort();
    }
    for h in rx_handles {
        h.abort();
    }
    telem_task.abort();
    dead_watcher.abort();
    dispatcher.abort();
    rx_forwarder.abort();

    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    telemetry.tls_state.store(TLS_CLOSED, Ordering::Relaxed);
    tracing::debug!(
        category = "tunnel",
        tls_state = %tls_state_label(TLS_CLOSED),
        "teardown.complete"
    );

    if forwarder_dead {
        // Surface as error so the supervisor classifies this as a drop and
        // triggers reconnect (`should_reconnect` uses the error string for
        // category — "rx_forwarder dead" doesn't match any specific
        // pattern, so it falls into `Other` which uses the standard
        // backoff table).
        return Err(anyhow::anyhow!("rx_forwarder dead — TUN write blocked"));
    }
    if all_streams_dead {
        // v0.26.21: death watcher signalled — all streams dead ≥ 3 s.
        // Surface as error so the supervisor classifies this as a drop and
        // triggers reconnect.
        return Err(anyhow::anyhow!("all streams dead"));
    }
    if dispatcher_died {
        // v0.27.0 (B3): TUN→stream dispatcher ended → reconnect. Classified as
        // `Other` by should_reconnect (standard backoff table). On user stop the
        // outer loop already broke on `explicit_shutdown`, so this only fires for
        // genuine mid-session uplink loss.
        return Err(anyhow::anyhow!("dispatcher ended — TX path gone"));
    }
    if recycle_fired {
        // v0.27.0 (W10): sentinel — the supervisor recognises this exact
        // prefix and treats it as "intentional recycle, reconnect now,
        // don't increment attempt counter, no backoff". Any other Err
        // string would route through should_reconnect's exponential
        // backoff table.
        return Err(anyhow::anyhow!("recycle requested — DPI session refresh"));
    }
    Ok(())
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
    /// tear down — the dead stream's flow just drops (dispatcher try_send), like
    /// v0.22.4. Tearing down all N on a single drop caused the DPI-detected
    /// reconnect-burst churn.
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
