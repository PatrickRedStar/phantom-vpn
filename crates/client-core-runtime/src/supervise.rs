//! Tunnel supervisor FSM with exponential backoff reconnect.
//!
//! `supervise()` runs one `drive_tunnel()` attempt at a time and, on failure,
//! sleeps a backoff delay before retrying. An explicit `cancel` `Notify`
//! interrupts any pending sleep (issued by the caller on explicit disconnect).

use anyhow::Context;
use bytes::Bytes;
use std::net::SocketAddr;
use std::os::unix::io::AsRawFd;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use client_common::helpers;
use client_common::{tls_connect, tls_connect_with_tcp, tls_rx_loop, tls_tx_loop, write_handshake};
use ghoststream_gui_ipc::{ConnState, ConnectProfile, StatusFrame, TunnelSettings};
use phantom_core::wire::{flow_stream_idx, n_data_streams};
use tokio::sync::{watch, Mutex};

use crate::telemetry::{spawn_telem_task, Telemetry};
use crate::{ProtectSocket, BACKOFF_SECS, MAX_ATTEMPTS};

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
pub async fn supervise(
    profile: ConnectProfile,
    settings: TunnelSettings,
    tun_factory: TunFactory,
    status_tx: watch::Sender<StatusFrame>,
    cancel: Arc<tokio::sync::Notify>,
    shared_telem: Arc<Mutex<Option<Arc<Telemetry>>>>,
    protect_socket: Option<ProtectSocket>,
) {
    let mut attempt: u32 = 0;

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
                fail(&status_tx, format!("parse conn_string: {:#}", e));
                break;
            }
        };

        let raw_addr = client_common::with_default_port(&cfg.network.server_addr, 443);
        let server_addr: SocketAddr = match raw_addr.parse() {
            Ok(a) => a,
            Err(_) => match tokio::net::lookup_host(&raw_addr).await {
                Ok(mut it) => match it.next() {
                    Some(a) => a,
                    None => {
                        fail(&status_tx, format!("no DNS results for {}", raw_addr));
                        if !should_reconnect(&settings, &status_tx, &cancel, attempt).await {
                            break;
                        }
                        attempt += 1;
                        continue;
                    }
                },
                Err(e) => {
                    fail(&status_tx, format!("DNS lookup: {}", e));
                    if !should_reconnect(&settings, &status_tx, &cancel, attempt).await {
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
                fail(&status_tx, format!("tls identity: {:#}", e));
                break;
            }
        };
        let server_ca = match helpers::load_server_ca(&cfg) {
            Ok(v) => v,
            Err(e) => {
                fail(&status_tx, format!("server CA: {:#}", e));
                break;
            }
        };
        let skip_verify = cfg.network.insecure;

        let tun_addr = cfg.network.tun_addr.clone().unwrap_or_default();
        let sni = cfg.network.server_name.clone().unwrap_or_default();
        let n_streams = n_data_streams();

        let telemetry = Arc::new(Telemetry::new(
            n_streams,
            tun_addr.clone(),
            server_addr.to_string(),
            sni.clone(),
        ));
        *shared_telem.lock().await = Some(telemetry.clone());

        tracing::info!(
            target: "client_core_runtime",
            profile = %profile.name,
            server = %server_addr,
            sni = ?cfg.network.server_name,
            attempt,
            "attempting tunnel"
        );

        // Instantiate TUN I/O for this attempt.
        let tun_channels = match tun_factory() {
            Ok(ch) => ch,
            Err(e) => {
                fail(&status_tx, format!("tun factory: {:#}", e));
                *shared_telem.lock().await = None;
                break;
            }
        };

        let result = drive_tunnel(
            cfg,
            server_addr,
            skip_verify,
            server_ca,
            client_identity,
            status_tx.clone(),
            telemetry.clone(),
            tun_channels,
            protect_socket.clone(),
            cancel.clone(),
        )
        .await;

        let explicit_shutdown = telemetry.shutdown.load(Ordering::SeqCst);
        *shared_telem.lock().await = None;

        match &result {
            Ok(()) => tracing::info!(target: "client_core_runtime", "tunnel exited cleanly"),
            Err(e) => tracing::error!(
                target: "client_core_runtime",
                error = %format!("{:#}", e),
                "tunnel failed"
            ),
        }

        if explicit_shutdown {
            let mut f = status_tx.borrow().clone();
            f.state = ConnState::Disconnected;
            f.streams_up = 0;
            f.stream_activity = [0.0; 16];
            f.reconnect_attempt = None;
            f.reconnect_next_delay_secs = None;
            let _ = status_tx.send(f);
            break;
        }

        if let Err(e) = &result {
            let mut f = status_tx.borrow().clone();
            f.last_error = Some(format!("{:#}", e));
            let _ = status_tx.send(f);
        }

        if !should_reconnect(&settings, &status_tx, &cancel, attempt).await {
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
    tracing::error!(target: "client_core_runtime", %msg, "supervisor fatal");
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
async fn should_reconnect(
    settings: &TunnelSettings,
    status_tx: &watch::Sender<StatusFrame>,
    cancel: &tokio::sync::Notify,
    attempt: u32,
) -> bool {
    if !settings.auto_reconnect {
        return false;
    }
    if attempt + 1 > MAX_ATTEMPTS {
        return false;
    }
    let delay = BACKOFF_SECS.get(attempt as usize).copied().unwrap_or(60);
    tracing::info!(
        target: "client_core_runtime",
        attempt = attempt + 1,
        delay_secs = delay,
        "scheduling reconnect"
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
    let notified = cancel.notified();
    tokio::pin!(notified);
    tokio::select! {
        _ = &mut sleep => true,
        _ = &mut notified => {
            tracing::info!(target: "client_core_runtime", "reconnect cancelled");
            false
        }
    }
}

/// Connect TLS streams, spawn I/O tasks, and run until shutdown or error.
///
/// Does NOT manage Linux-specific guards (DnsGuard, Ipv6Guard, RouteGuard) —
/// those remain in the linux-helper crate and are set up around this call.
async fn drive_tunnel(
    cfg: phantom_core::config::ClientConfig,
    server_addr: SocketAddr,
    skip_verify: bool,
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
    protect_socket: Option<ProtectSocket>,
    cancel: Arc<tokio::sync::Notify>,
) -> anyhow::Result<()> {
    let client_tls =
        phantom_core::h2_transport::make_h2_client_tls(skip_verify, server_ca, client_identity)
            .context("build TLS client config")?;
    let n_streams = n_data_streams();

    let server_name = cfg
        .network
        .server_name
        .as_deref()
        .unwrap_or("phantom")
        .to_string();

    let mut tls_writers = Vec::with_capacity(n_streams);
    let mut tls_readers = Vec::with_capacity(n_streams);
    for idx in 0..n_streams {
        let (r, mut w) = if let Some(ref protect) = protect_socket {
            // Android: create socket, protect it from VPN routing, then connect.
            let socket = if server_addr.is_ipv4() {
                tokio::net::TcpSocket::new_v4()
            } else {
                tokio::net::TcpSocket::new_v6()
            }.with_context(|| format!("stream {} socket create", idx))?;

            let fd = socket.as_raw_fd();
            if !protect(fd) {
                anyhow::bail!("stream {} VpnService.protect() failed", idx);
            }

            let tcp = socket.connect(server_addr)
                .await
                .with_context(|| format!("stream {} tcp connect", idx))?;

            tls_connect_with_tcp(tcp, server_name.clone(), client_tls.clone())
                .await
                .with_context(|| format!("stream {} tls connect", idx))?
        } else {
            // Linux/iOS: no socket protection needed.
            tls_connect(server_addr, server_name.clone(), client_tls.clone())
                .await
                .with_context(|| format!("stream {} tls connect", idx))?
        };
        write_handshake(&mut w, idx as u8, n_streams as u8)
            .await
            .with_context(|| format!("stream {} handshake", idx))?;
        tracing::info!(target: "client_core_runtime", "stream {} connected", idx);
        telemetry.streams_alive[idx].store(true, Ordering::Relaxed);
        tls_readers.push(r);
        tls_writers.push(w);
    }
    tracing::info!(target: "client_core_runtime", "all {} streams up", n_streams);

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

    // Dispatcher: TUN → per-stream channel with per-stream TX byte counting.
    let tx_senders_clone = tx_senders.clone();
    let tele = telemetry.clone();
    let dispatcher = tokio::spawn(async move {
        while let Some(pkt) = tun_pkt_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams);
            let len = pkt.len() as u64;
            if tx_senders_clone[idx].try_send(pkt).is_ok() {
                tele.bytes_tx.fetch_add(len, Ordering::Relaxed);
                tele.stream_tx_bytes[idx].fetch_add(len, Ordering::Relaxed);
            }
        }
    });
    drop(tx_senders);

    // RX sink forwarder: count bytes then push into TUN writer.
    let tun_write_tx = tun_pkt_tx.clone();
    let tele_rx = telemetry.clone();
    let rx_forwarder = tokio::spawn(async move {
        while let Some(pkt) = rx_sink_rx.recv().await {
            tele_rx
                .bytes_rx
                .fetch_add(pkt.len() as u64, Ordering::Relaxed);
            if tun_write_tx.send(pkt).await.is_err() {
                return;
            }
        }
    });
    drop(tun_pkt_tx);

    // Per-stream TX + RX tasks.
    let mut tx_handles = Vec::with_capacity(n_streams);
    let mut rx_handles = Vec::with_capacity(n_streams);
    for (idx, (w, rxc)) in tls_writers
        .into_iter()
        .zip(tx_receivers.into_iter())
        .enumerate()
    {
        let tele = telemetry.clone();
        tx_handles.push(tokio::spawn(async move {
            let res = tls_tx_loop(w, rxc).await;
            tele.streams_alive[idx].store(false, Ordering::Relaxed);
            tracing::warn!(
                target: "client_core_runtime",
                "stream {} tx ended: {:?}", idx, res
            );
            res
        }));
    }
    for (idx, r) in tls_readers.into_iter().enumerate() {
        let sink = rx_sink_tx.clone();
        let tele = telemetry.clone();
        rx_handles.push(tokio::spawn(async move {
            let res = tls_rx_loop(r, sink).await;
            tele.streams_alive[idx].store(false, Ordering::Relaxed);
            tracing::warn!(
                target: "client_core_runtime",
                "stream {} rx ended: {:?}", idx, res
            );
            res
        }));
    }
    drop(rx_sink_tx);

    // Telemetry task.
    let telem_task = spawn_telem_task(telemetry.clone(), status_tx.clone());

    // Shutdown flag poll.
    let shutdown_poll = {
        let tele = telemetry.clone();
        async move {
            loop {
                if tele.shutdown.load(Ordering::Relaxed) {
                    break;
                }
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        }
    };

    tokio::select! {
        _ = cancel.notified() => {
            tracing::info!(target: "client_core_runtime", "explicit disconnect (cancel notified)");
            telemetry.shutdown.store(true, Ordering::SeqCst);
        }
        _ = shutdown_poll => {
            tracing::info!(target: "client_core_runtime", "shutdown flag set");
        }
        _ = async {
            for h in &mut tx_handles { let _ = h.await; }
        } => {
            tracing::warn!(target: "client_core_runtime", "all TX ended");
        }
        _ = async {
            for h in &mut rx_handles { let _ = h.await; }
        } => {
            tracing::warn!(target: "client_core_runtime", "all RX ended");
        }
    }

    tracing::info!(target: "client_core_runtime", "draining tunnel teardown");

    for h in tx_handles {
        h.abort();
    }
    for h in rx_handles {
        h.abort();
    }
    telem_task.abort();
    dispatcher.abort();
    rx_forwarder.abort();

    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    tracing::info!(target: "client_core_runtime", "tunnel teardown complete");
    Ok(())
}
