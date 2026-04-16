//! Tunnel lifecycle manager: arbitrates connect/disconnect, drives the TLS
//! tunnel, updates `StatusFrame` telemetry.

use anyhow::Context;
use bytes::Bytes;
use std::net::SocketAddr;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::{watch, Mutex};

use client_common::helpers;
use client_common::{tls_connect, tls_rx_loop, tls_tx_loop, write_handshake};
use ghoststream_gui_ipc::{ConnState, ConnectProfile, StatusFrame, TunnelSettings};
use phantom_core::wire::{flow_stream_idx, n_data_streams};

use super::dns::DnsGuard;
use super::ipv6::Ipv6Guard;
use super::tun;

/// Reconnect backoff schedule. Index = attempt-1 (after first drop). After
/// `MAX_ATTEMPTS` we give up and surface Error to the GUI.
const BACKOFF_SECS: &[u32] = &[3, 6, 12, 24, 48, 60, 60, 60];
const MAX_ATTEMPTS: u32 = 8;

pub struct Manager {
    inner: Mutex<Inner>,
    status_tx: watch::Sender<StatusFrame>,
    client_count: AtomicUsize,
}

struct Inner {
    /// JoinHandle for the supervisor task (wraps reconnect loop + driver).
    supervisor: Option<tokio::task::JoinHandle<()>>,
    /// Live telemetry for the *current* attempt (supervisor swaps this on
    /// each reconnect). `Manager::disconnect` flips `.shutdown = true` here.
    telemetry: Arc<Mutex<Option<Arc<Telemetry>>>>,
    /// Notified on explicit Disconnect to abort any pending backoff sleep
    /// and signal the supervisor "do not reconnect, just exit".
    reconnect_cancel: Arc<tokio::sync::Notify>,
}

#[allow(dead_code)]
struct Telemetry {
    started_at: Instant,
    bytes_rx: AtomicU64,
    bytes_tx: AtomicU64,
    /// Per-stream TX byte counters for activity indicator.
    stream_tx_bytes: Vec<AtomicU64>,
    n_streams: usize,
    streams_alive: Vec<AtomicBool>,
    tun_addr: String,
    server_addr: String,
    sni: String,
    shutdown: AtomicBool,
}

impl Manager {
    pub fn new(status_tx: watch::Sender<StatusFrame>) -> Self {
        Self {
            inner: Mutex::new(Inner {
                supervisor: None,
                telemetry: Arc::new(Mutex::new(None)),
                reconnect_cancel: Arc::new(tokio::sync::Notify::new()),
            }),
            status_tx,
            client_count: AtomicUsize::new(0),
        }
    }

    pub fn inc_clients(&self) { self.client_count.fetch_add(1, Ordering::Relaxed); }
    pub fn dec_clients(&self) { self.client_count.fetch_sub(1, Ordering::Relaxed); }
    pub fn client_count(&self) -> usize { self.client_count.load(Ordering::Relaxed) }
    pub fn is_connected(&self) -> bool { self.status_tx.borrow().state == ConnState::Connected }

    pub fn current_status(&self) -> StatusFrame {
        self.status_tx.borrow().clone()
    }

    pub async fn connect(&self, profile: ConnectProfile) -> anyhow::Result<()> {
        // Tear down any existing tunnel first.
        self.disconnect().await;

        self.publish(|f| {
            f.state = ConnState::Connecting;
            f.last_error = None;
            f.session_secs = 0;
            f.bytes_rx = 0;
            f.bytes_tx = 0;
            f.rate_rx_bps = 0.0;
            f.rate_tx_bps = 0.0;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
        });

        // Validate the conn string *before* we commit to a supervisor — if
        // it's garbage, fail fast with an error directly to the GUI.
        let _ = client_common::helpers::parse_conn_string(&profile.conn_string)
            .context("parse conn_string")?;

        let status_tx = self.status_tx.clone();
        let settings = profile.settings.clone();

        // Fresh Notify so stale notifications from a prior session don't
        // immediately cancel us.
        let cancel = {
            let mut g = self.inner.lock().await;
            g.reconnect_cancel = Arc::new(tokio::sync::Notify::new());
            g.reconnect_cancel.clone()
        };

        // Clear previous telemetry slot; supervisor will populate on each
        // attempt. Manager::disconnect reads this same Arc to signal shutdown.
        let shared_telem = {
            let g = self.inner.lock().await;
            *g.telemetry.lock().await = None;
            g.telemetry.clone()
        };

        let supervisor = tokio::spawn(supervise(
            profile,
            settings,
            status_tx,
            cancel,
            shared_telem,
        ));

        let mut g = self.inner.lock().await;
        g.supervisor = Some(supervisor);
        Ok(())
    }

    pub async fn disconnect(&self) {
        let (handle, cancel) = {
            let mut g = self.inner.lock().await;
            // Flip shutdown on whatever attempt is live right now.
            if let Some(t) = g.telemetry.lock().await.as_ref() {
                t.shutdown.store(true, Ordering::SeqCst);
            }
            let handle = g.supervisor.take();
            let cancel = g.reconnect_cancel.clone();
            // Supervisor will clear its own slot; don't race with it.
            (handle, cancel)
        };

        // Wake any pending backoff sleep in the supervisor.
        cancel.notify_waiters();

        if let Some(h) = handle {
            // Supervisor does its own teardown (route_guard, TUN link del,
            // io_uring thread exit). Grace window for orderly shutdown.
            let grace = tokio::time::timeout(
                std::time::Duration::from_secs(3),
                h,
            ).await;
            if grace.is_err() {
                tracing::warn!(target: "helper", "teardown timeout — task still running, leaking");
            }
        }

        self.publish(|f| {
            f.state = ConnState::Disconnected;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.session_secs = 0;
            f.rate_rx_bps = 0.0;
            f.rate_tx_bps = 0.0;
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
        });
    }

    fn publish(&self, mut f: impl FnMut(&mut StatusFrame)) {
        let mut cur = self.status_tx.borrow().clone();
        f(&mut cur);
        let _ = self.status_tx.send(cur);
    }
}

/// Top-level session supervisor. Runs one attempt, then — if auto-reconnect
/// is on and we weren't explicitly disconnected — sleeps a backoff and tries
/// again. Handles state transitions Connecting → Connected → Reconnecting.
async fn supervise(
    profile: ConnectProfile,
    settings: TunnelSettings,
    status_tx: watch::Sender<StatusFrame>,
    cancel: Arc<tokio::sync::Notify>,
    shared_telem: Arc<Mutex<Option<Arc<Telemetry>>>>,
) {
    let mut attempt: u32 = 0;

    loop {
        // Surface Connecting / Reconnecting state to GUI.
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
                fail(&status_tx, format!("parse conn_string: {:#}", e));
                break;
            }
        };

        let raw_addr = client_common::with_default_port(&cfg.network.server_addr, 443);
        let server_addr: SocketAddr = match raw_addr.parse() {
            Ok(a) => a,
            Err(_) => {
                match tokio::net::lookup_host(&raw_addr).await {
                    Ok(mut it) => match it.next() {
                        Some(a) => a,
                        None => {
                            fail(&status_tx, format!("no DNS results for {}", raw_addr));
                            if !should_reconnect(&settings, &cancel, attempt).await { break; }
                            attempt += 1;
                            continue;
                        }
                    },
                    Err(e) => {
                        fail(&status_tx, format!("DNS lookup: {}", e));
                        if !should_reconnect(&settings, &cancel, attempt).await { break; }
                        attempt += 1;
                        continue;
                    }
                }
            }
        };

        let client_identity = match helpers::load_tls_identity(&cfg) {
            Ok(v) => v,
            Err(e) => { fail(&status_tx, format!("tls identity: {:#}", e)); break; }
        };
        let server_ca = match helpers::load_server_ca(&cfg) {
            Ok(v) => v,
            Err(e) => { fail(&status_tx, format!("server CA: {:#}", e)); break; }
        };
        let skip_verify = cfg.network.insecure;

        let telemetry = Arc::new(Telemetry {
            started_at: Instant::now(),
            bytes_rx: AtomicU64::new(0),
            bytes_tx: AtomicU64::new(0),
            stream_tx_bytes: (0..16).map(|_| AtomicU64::new(0)).collect(),
            n_streams: 0,
            streams_alive: (0..16).map(|_| AtomicBool::new(false)).collect(),
            tun_addr: cfg.network.tun_addr.clone().unwrap_or_default(),
            server_addr: server_addr.to_string(),
            sni: cfg.network.server_name.clone().unwrap_or_default(),
            shutdown: AtomicBool::new(false),
        });
        *shared_telem.lock().await = Some(telemetry.clone());

        tracing::info!(target: "helper",
            profile = %profile.name,
            server = %server_addr,
            sni = ?cfg.network.server_name,
            attempt,
            "attempting tunnel"
        );

        let result = drive_tunnel(
            cfg,
            server_addr,
            skip_verify,
            server_ca,
            client_identity,
            status_tx.clone(),
            telemetry.clone(),
            settings.clone(),
        ).await;

        let explicit_shutdown = telemetry.shutdown.load(Ordering::SeqCst);
        *shared_telem.lock().await = None;

        match &result {
            Ok(()) => tracing::info!(target: "helper", "tunnel exited cleanly"),
            Err(e) => tracing::error!(target: "helper",
                error = %format!("{:#}", e), "tunnel failed"),
        }

        if explicit_shutdown {
            // User asked us to stop. Publish Disconnected and exit loop.
            let mut f = status_tx.borrow().clone();
            f.state = ConnState::Disconnected;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
            let _ = status_tx.send(f);
            break;
        }

        // Natural exit or drop — decide whether to reconnect.
        if let Err(e) = &result {
            let mut f = status_tx.borrow().clone();
            f.last_error = Some(format!("{:#}", e));
            let _ = status_tx.send(f);
        }

        if !should_reconnect(&settings, &cancel, attempt).await {
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

fn fail(status_tx: &watch::Sender<StatusFrame>, msg: String) {
    tracing::error!(target: "helper", %msg, "supervisor fatal");
    let mut f = status_tx.borrow().clone();
    f.state = ConnState::Error;
    f.last_error = Some(msg);
    f.streams_up = 0;
    f.stream_activity = [0.0; 16];
    f.reconnect_attempt = None;
    f.reconnect_next_delay_secs = None;
    let _ = status_tx.send(f);
}

/// Decide whether to keep retrying. Publishes countdown into StatusFrame so
/// the GUI can render "reconnecting in N s". Returns false when either:
///   * auto_reconnect is disabled, or
///   * attempt count is exhausted, or
///   * an explicit Disconnect cancel arrived mid-sleep.
async fn should_reconnect(
    settings: &TunnelSettings,
    cancel: &tokio::sync::Notify,
    attempt: u32,
) -> bool {
    if !settings.auto_reconnect { return false; }
    if attempt + 1 > MAX_ATTEMPTS { return false; }
    let delay = BACKOFF_SECS.get(attempt as usize).copied().unwrap_or(60);
    tracing::info!(target: "helper",
        attempt = attempt + 1,
        delay_secs = delay,
        "scheduling reconnect");
    let sleep = tokio::time::sleep(std::time::Duration::from_secs(delay as u64));
    tokio::pin!(sleep);
    let notified = cancel.notified();
    tokio::pin!(notified);
    tokio::select! {
        _ = &mut sleep => true,
        _ = &mut notified => {
            tracing::info!(target: "helper", "reconnect cancelled");
            false
        }
    }
}

/// Build + run the tunnel. Exits on shutdown flag or fatal error.
async fn drive_tunnel(
    cfg: phantom_core::config::ClientConfig,
    server_addr: SocketAddr,
    skip_verify: bool,
    server_ca: Option<Vec<rustls::pki_types::CertificateDer<'static>>>,
    client_identity: Option<(Vec<rustls::pki_types::CertificateDer<'static>>,
                              rustls::pki_types::PrivateKeyDer<'static>)>,
    status_tx: watch::Sender<StatusFrame>,
    telemetry: Arc<Telemetry>,
    settings: TunnelSettings,
) -> anyhow::Result<()> {
    let client_tls =
        phantom_core::h2_transport::make_h2_client_tls(skip_verify, server_ca, client_identity)
            .context("build TLS client config")?;
    let n_streams = n_data_streams();

    let server_name = cfg.network.server_name.as_deref().unwrap_or("phantom").to_string();

    let mut tls_writers = Vec::with_capacity(n_streams);
    let mut tls_readers = Vec::with_capacity(n_streams);
    for idx in 0..n_streams {
        let (r, mut w) = tls_connect(server_addr, server_name.clone(), client_tls.clone())
            .await
            .with_context(|| format!("stream {} tls connect", idx))?;
        write_handshake(&mut w, idx as u8, n_streams as u8)
            .await
            .with_context(|| format!("stream {} handshake", idx))?;
        tracing::info!(target: "helper", "stream {} connected", idx);
        telemetry.streams_alive[idx].store(true, Ordering::Relaxed);
        tls_readers.push(r);
        tls_writers.push(w);
    }
    tracing::info!(target: "helper", "all {} streams up", n_streams);

    // TUN
    let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

    let tun_device = tun::create_tun(tun_name, tun_addr, tun_mtu)?;
    let tun_fd = tun_device.file.as_raw_fd();
    // tun_device lives to end of drive_tunnel — on Drop it runs `ip link del`,
    // forcing kernel to reclaim the device. io_uring worker threads see EBADF
    // on their next submit and exit naturally.

    let route_guard = if cfg.network.default_gw.is_some() {
        match tun::add_default_route(tun_name, &server_addr) {
            Ok(g) => Some(g),
            Err(e) => { tracing::warn!(target:"helper", "route setup: {}", e); None }
        }
    } else { None };

    // IPv6 kill switch — block all v6 egress so apps can't leak around our
    // v4-only tunnel. Dropped *before* route_guard in teardown (see below).
    let ipv6_guard = if settings.ipv6_killswitch {
        match Ipv6Guard::activate() {
            Ok(g) => Some(g),
            Err(e) => { tracing::warn!(target:"helper", "ipv6 guard: {:#}", e); None }
        }
    } else { None };

    // DNS leak protection — pin systemd-resolved to route all DNS through
    // the tunnel. Use the default gateway (typically 10.7.0.1) as the
    // resolver; most servers run a local recursor there.
    let dns_guard = if settings.dns_leak_protection {
        // Derive the resolver IP: prefer default_gw, else first hop inferred
        // from tun_addr by swapping the host bits to .1.
        let dns_ip = cfg.network.default_gw.as_deref()
            .and_then(|s| s.parse::<std::net::IpAddr>().ok())
            .or_else(|| {
                // Fallback: extract network from tun_addr CIDR, use .1.
                cfg.network.tun_addr.as_deref()
                    .and_then(|s| s.split('/').next())
                    .and_then(|ip| ip.parse::<std::net::Ipv4Addr>().ok())
                    .map(|v4| {
                        let o = v4.octets();
                        std::net::IpAddr::V4(std::net::Ipv4Addr::new(o[0], o[1], o[2], 1))
                    })
            });
        match dns_ip {
            Some(ip) => match DnsGuard::activate(tun_name, &[ip], &[]) {
                Ok(g) => Some(g),
                Err(e) => { tracing::warn!(target:"helper", "dns guard: {:#}", e); None }
            },
            None => {
                tracing::warn!(target:"helper",
                    "could not infer DNS server — leak protection skipped");
                None
            }
        }
    } else { None };

    let (mut tun_pkt_rx, tun_pkt_tx) = phantom_core::tun_uring::spawn(tun_fd, 4096)
        .context("tun_uring spawn")?;

    // Transition to Connected state.
    {
        let mut f = status_tx.borrow().clone();
        f.state = ConnState::Connected;
        f.n_streams = n_streams as u8;
        f.streams_up = n_streams as u8;
        f.tun_addr = Some(tun_addr.to_string());
        f.server_addr = Some(server_addr.to_string());
        f.sni = Some(server_name.clone());
        let _ = status_tx.send(f);
    }

    // Per-stream tx channels.
    let mut tx_senders: Vec<tokio::sync::mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
    let mut tx_receivers: Vec<tokio::sync::mpsc::Receiver<Bytes>> = Vec::with_capacity(n_streams);
    for _ in 0..n_streams {
        let (t, r) = tokio::sync::mpsc::channel::<Bytes>(2048);
        tx_senders.push(t);
        tx_receivers.push(r);
    }

    let (rx_sink_tx, mut rx_sink_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);

    // Dispatcher: TUN → per-stream channel, with per-stream TX byte counting.
    let tx_senders_clone = tx_senders.clone();
    let tele = telemetry.clone();
    let dispatcher = tokio::spawn(async move {
        while let Some(pkt) = tun_pkt_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams);
            let len = pkt.len() as u64;
            match tx_senders_clone[idx].try_send(pkt) {
                Ok(()) => {
                    tele.bytes_tx.fetch_add(len, Ordering::Relaxed);
                    tele.stream_tx_bytes[idx].fetch_add(len, Ordering::Relaxed);
                }
                Err(_) => {}
            }
        }
    });
    drop(tx_senders);

    // RX sink forwarder: count bytes then push into tun_uring writer.
    let tun_write_tx = tun_pkt_tx.clone();
    let tele_rx = telemetry.clone();
    let rx_forwarder = tokio::spawn(async move {
        while let Some(pkt) = rx_sink_rx.recv().await {
            tele_rx.bytes_rx.fetch_add(pkt.len() as u64, Ordering::Relaxed);
            if tun_write_tx.send(pkt).await.is_err() { return; }
        }
    });
    drop(tun_pkt_tx);

    // Per-stream TX + RX tasks.
    let mut tx_handles = Vec::with_capacity(n_streams);
    let mut rx_handles = Vec::with_capacity(n_streams);
    for (idx, (w, rxc)) in tls_writers.into_iter().zip(tx_receivers.into_iter()).enumerate() {
        let tele = telemetry.clone();
        tx_handles.push(tokio::spawn(async move {
            let res = tls_tx_loop(w, rxc).await;
            tele.streams_alive[idx].store(false, Ordering::Relaxed);
            tracing::warn!(target:"helper", "stream {} tx ended: {:?}", idx, res);
            res
        }));
    }
    for (idx, r) in tls_readers.into_iter().enumerate() {
        let sink = rx_sink_tx.clone();
        let tele = telemetry.clone();
        rx_handles.push(tokio::spawn(async move {
            let res = tls_rx_loop(r, sink).await;
            tele.streams_alive[idx].store(false, Ordering::Relaxed);
            tracing::warn!(target:"helper", "stream {} rx ended: {:?}", idx, res);
            res
        }));
    }
    drop(rx_sink_tx);

    // Telemetry poller: 4 Hz snapshot with EMA rate computation + per-stream activity.
    let telem_task = {
        let tele = telemetry.clone();
        let status_tx = status_tx.clone();
        tokio::spawn(async move {
            let mut last_rx = 0u64;
            let mut last_tx = 0u64;
            let mut last_instant = Instant::now();
            let mut last_per_stream: [u64; 16] = [0; 16];
            let alpha = 0.35f64;
            let mut ema_rx = 0.0f64;
            let mut ema_tx = 0.0f64;
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                if tele.shutdown.load(Ordering::Relaxed) { break; }

                let now = Instant::now();
                let dt = now.duration_since(last_instant).as_secs_f64().max(0.001);
                last_instant = now;

                let br = tele.bytes_rx.load(Ordering::Relaxed);
                let bt = tele.bytes_tx.load(Ordering::Relaxed);
                let drx = br.saturating_sub(last_rx);
                let dtx = bt.saturating_sub(last_tx);
                last_rx = br; last_tx = bt;

                let inst_rx_bps = (drx as f64 * 8.0) / dt;
                let inst_tx_bps = (dtx as f64 * 8.0) / dt;
                ema_rx = ema_rx * (1.0 - alpha) + inst_rx_bps * alpha;
                ema_tx = ema_tx * (1.0 - alpha) + inst_tx_bps * alpha;

                // Per-stream activity: normalize by max over window.
                let mut per_stream_delta = [0u64; 16];
                let mut max_delta: u64 = 1;
                for i in 0..16 {
                    let v = tele.stream_tx_bytes[i].load(Ordering::Relaxed);
                    let d = v.saturating_sub(last_per_stream[i]);
                    last_per_stream[i] = v;
                    per_stream_delta[i] = d;
                    if d > max_delta { max_delta = d; }
                }
                let mut act = [0.0f32; 16];
                let mut up: u8 = 0;
                for i in 0..16 {
                    if tele.streams_alive[i].load(Ordering::Relaxed) {
                        up += 1;
                        // mix of raw normalized activity and a floor so idle streams show faint
                        let base = (per_stream_delta[i] as f64 / max_delta as f64) as f32;
                        act[i] = (0.12 + 0.88 * base).clamp(0.05, 1.0);
                    } else {
                        act[i] = 0.0;
                    }
                }

                let mut cur = status_tx.borrow().clone();
                cur.state = ConnState::Connected;
                cur.session_secs = tele.started_at.elapsed().as_secs();
                cur.bytes_rx = br;
                cur.bytes_tx = bt;
                cur.rate_rx_bps = ema_rx;
                cur.rate_tx_bps = ema_tx;
                cur.streams_up = up;
                cur.stream_activity = act;
                let _ = status_tx.send(cur);
            }
        })
    };

    // Wait for either shutdown flag or any loop to die.
    let shutdown_poll = {
        let tele = telemetry.clone();
        async move {
            loop {
                if tele.shutdown.load(Ordering::Relaxed) { break; }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        }
    };

    tokio::select! {
        _ = shutdown_poll => {
            tracing::info!(target:"helper", "shutdown flag set");
        }
        _ = async {
            for h in &mut tx_handles { let _ = h.await; }
        } => {
            tracing::warn!(target:"helper", "all TX ended");
        }
        _ = async {
            for h in &mut rx_handles { let _ = h.await; }
        } => {
            tracing::warn!(target:"helper", "all RX ended");
        }
    }

    tracing::info!(target: "helper", "draining tunnel teardown");

    // 1a. DNS guard first — revert systemd-resolved so any teardown-time
    //     resolution from this process (shouldn't happen, but defense in
    //     depth) uses system defaults again.
    drop(dns_guard);

    // 1b. IPv6 kill switch — remove ip6tables rules before we un-route,
    //     avoiding a brief window where v6 is still blocked but v4 is
    //     already back on the host default.
    drop(ipv6_guard);

    // 1c. Drop route_guard → restores default route + rules + iptables
    //     BEFORE we tear down TUN, so kernel has a valid default for any
    //     in-flight replies.
    drop(route_guard);

    // 2. Abort per-stream TLS loops (they hold TCP sockets).
    for h in tx_handles { h.abort(); }
    for h in rx_handles { h.abort(); }
    telem_task.abort();

    // 3. Abort dispatcher & rx forwarder (owners of tun_pkt channels).
    dispatcher.abort();
    rx_forwarder.abort();

    // 4. Drop TUN device — runs `ip link del <name>`, closes fd.
    //    io_uring worker threads see EBADF on next syscall and exit.
    drop(tun_device);

    // Give io_uring threads a moment to notice EBADF and exit cleanly.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    tracing::info!(target: "helper", "tunnel teardown complete");
    Ok(())
}
