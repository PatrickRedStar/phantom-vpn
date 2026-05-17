//! Tunnel lifecycle controller — orchestrates Connect / Disconnect from
//! within the tokio worker thread.
//!
//! On Windows this drives the real `client_core_runtime::run()` with a
//! `WintunBackend`. On non-Windows hosts (Mac for development, future
//! Linux test runs) we keep the same UI surface alive but stub the
//! tunnel — the worker simulates Connecting → Connected → Disconnected
//! transitions and a low rate of synthetic RX/TX so the GUI can be
//! exercised without admin rights or a real adapter.

use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use ghoststream_gui_ipc::{ConnState, ConnectProfile, LogFrame, StatusFrame};
use slint::Weak;
use tokio::sync::{mpsc, watch};

use crate::bridge::{apply_log_to_ui, apply_status_to_ui};
use crate::MainWindow;

/// Handles to a running tunnel session. Dropping does not cancel — the
/// caller must explicitly send `cancel` and `.await` the join handle to
/// shut down cleanly.
pub struct ActiveTunnel {
    pub cancel: watch::Sender<bool>,
    pub join: tokio::task::JoinHandle<Result<()>>,
}

impl ActiveTunnel {
    /// Send the shutdown signal and wait for the supervisor task to
    /// fully unwind. Logs any panic from the join but never panics
    /// itself, so the worker loop stays alive across reconnect attempts.
    pub async fn stop(self) {
        let _ = self.cancel.send(true);
        if let Err(e) = self.join.await {
            tracing::warn!(error = ?e, "tunnel join error");
        }
    }
}

/// Spawn a new tunnel session and a pair of forwarders that push status
/// updates and log frames into the UI.
pub async fn start_tunnel(
    profile: ConnectProfile,
    weak: Weak<MainWindow>,
) -> Result<ActiveTunnel> {
    let (status_tx, status_rx) = watch::channel(StatusFrame::default());
    let (log_tx, log_rx) = mpsc::channel::<LogFrame>(256);

    // Fork: real Wintun path on Windows, simulator on every other host.
    #[cfg(windows)]
    let (cancel, join) = start_real_tunnel(profile, status_tx, log_tx).await?;

    #[cfg(not(windows))]
    let (cancel, join) = start_simulated_tunnel(profile, status_tx, log_tx);

    // Status forwarder: watch::Receiver → UI.
    spawn_status_forwarder(weak.clone(), status_rx);
    // Log forwarder: mpsc::Receiver → UI.
    spawn_log_forwarder(weak, log_rx);

    Ok(ActiveTunnel { cancel, join })
}

fn spawn_status_forwarder(weak: Weak<MainWindow>, mut rx: watch::Receiver<StatusFrame>) {
    tokio::spawn(async move {
        // Initial snapshot — surface the StatusFrame::default() to the UI
        // immediately so the user sees "Handshaking" before the first
        // change event arrives.
        apply_status_to_ui(weak.clone(), rx.borrow().clone());
        while rx.changed().await.is_ok() {
            apply_status_to_ui(weak.clone(), rx.borrow().clone());
        }
    });
}

fn spawn_log_forwarder(weak: Weak<MainWindow>, mut rx: mpsc::Receiver<LogFrame>) {
    tokio::spawn(async move {
        while let Some(frame) = rx.recv().await {
            apply_log_to_ui(weak.clone(), frame);
        }
    });
}

// ── Windows: real Wintun-backed tunnel ────────────────────────────────────

#[cfg(windows)]
async fn start_real_tunnel(
    profile: ConnectProfile,
    status_tx: watch::Sender<StatusFrame>,
    log_tx: mpsc::Sender<LogFrame>,
) -> Result<(watch::Sender<bool>, tokio::task::JoinHandle<Result<()>>)> {
    use client_core_runtime::TunIo;
    use client_windows_core::{WintunBackend, WintunConfig};
    use std::net::Ipv4Addr;

    // Resolve wintun.dll path next to the .exe.
    let dll_path = crate::wintun_loader::locate_wintun_dll()
        .context("locate wintun.dll")?;

    // For Phase 4 MVP we hard-code the tunnel-side IP / netmask / MTU
    // (10.7.0.2/30, MTU 1350) — these are the GhostStream defaults shared
    // with every other client. Future work: derive from the server
    // response or expose them in the profile editor (Phase 4.5+).
    let cfg = WintunConfig {
        adapter_name: "GhostStream".into(),
        tunnel_type: "GhostStream Tunnel".into(),
        dll_path,
        address: Ipv4Addr::new(10, 7, 0, 2),
        netmask: Ipv4Addr::new(255, 255, 255, 252),
        mtu: 1350,
        dns_servers: vec![],
    };
    let backend = WintunBackend::new(&cfg).context("create wintun backend")?;

    let (handles, join) = client_core_runtime::run(
        profile,
        TunIo::Backend(Arc::new(backend)),
        status_tx,
        log_tx,
        None, // ProtectSocket is Android-only
    )
    .await
    .context("client-core-runtime::run")?;

    Ok((handles.cancel, join))
}

// ── Non-Windows: simulated tunnel for the dev loop ────────────────────────

#[cfg(not(windows))]
fn start_simulated_tunnel(
    profile: ConnectProfile,
    status_tx: watch::Sender<StatusFrame>,
    log_tx: mpsc::Sender<LogFrame>,
) -> (watch::Sender<bool>, tokio::task::JoinHandle<Result<()>>) {
    let (cancel_tx, mut cancel_rx) = watch::channel::<bool>(false);

    let join = tokio::spawn(async move {
        let _ = log_tx
            .send(LogFrame {
                ts_unix_ms: now_ms(),
                ts_unix_us: 0,
                level: "INF".into(),
                msg: format!("simulator: connecting to {}", profile.conn_string),
                category: Some("tunnel".into()),
                fields: None,
            })
            .await;

        // Connecting phase — show "Handshaking" for ~1s.
        publish(&status_tx, |s| {
            s.state = ConnState::Connecting;
            s.server_addr = Some(profile.conn_string.clone());
        });

        if cancel_rx.changed().await.is_ok() && *cancel_rx.borrow() {
            return Ok(());
        }
        // Actually we want a short sleep _without_ being cancelled — use
        // a tokio::select! so cancel cuts the wait short.
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_secs(1)) => {}
            _ = cancel_rx.changed() => { return Ok(()); }
        }

        publish(&status_tx, |s| {
            s.state = ConnState::Connected;
            s.n_streams = 4;
            s.streams_up = 4;
            s.rtt_ms = Some(23);
            s.server_addr = Some(profile.conn_string.clone());
        });

        let _ = log_tx
            .send(LogFrame {
                ts_unix_ms: now_ms(),
                ts_unix_us: 0,
                level: "INF".into(),
                msg: "simulator: tunnel.up · 4 streams".into(),
                category: Some("tunnel".into()),
                fields: None,
            })
            .await;

        // Live phase — bump session_secs every second, fake RX/TX rates.
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        let mut session_secs: u64 = 0;
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    session_secs += 1;
                    publish(&status_tx, |s| {
                        s.session_secs = session_secs;
                        s.rate_rx_bps = 16_000_000.0 + (session_secs as f64 % 5.0) * 1_500_000.0;
                        s.rate_tx_bps = 1_200_000.0 + (session_secs as f64 % 5.0) * 300_000.0;
                    });
                }
                _ = cancel_rx.changed() => {
                    if *cancel_rx.borrow() {
                        let _ = log_tx
                            .send(LogFrame {
                                ts_unix_ms: now_ms(),
                                ts_unix_us: 0,
                                level: "INF".into(),
                                msg: "simulator: shutdown".into(),
                                category: Some("tunnel".into()),
                                fields: None,
                            })
                            .await;
                        publish(&status_tx, |s| { s.state = ConnState::Disconnected; });
                        break;
                    }
                }
            }
        }
        Ok::<(), anyhow::Error>(())
    });

    (cancel_tx, join)
}

#[cfg(not(windows))]
fn publish(tx: &watch::Sender<StatusFrame>, mutate: impl FnOnce(&mut StatusFrame)) {
    let mut f = tx.borrow().clone();
    mutate(&mut f);
    let _ = tx.send(f);
}

#[cfg(not(windows))]
fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
