//! GhostStream Windows GUI — entry point.
//!
//! Two threads cooperate:
//!   * Slint event loop on the main thread — owns `MainWindow`.
//!   * Tokio worker on a spawned thread — owns the tunnel runtime, drives
//!     `client_core_runtime::run()` on Windows and a simulator on other
//!     hosts so the UI loop can be exercised without admin rights.
//!
//! They communicate through two channels:
//!   * `UiCommand` (UI → tokio): user gestures.
//!   * `slint::Weak::upgrade_in_event_loop` (tokio → UI): status / log
//!     frames re-projected onto MainWindow properties via `bridge.rs`.

#![cfg_attr(all(target_os = "windows", not(debug_assertions)), windows_subsystem = "windows")]

mod bridge;
mod controller;

#[cfg(windows)]
mod wintun_loader;

slint::include_modules!();

use anyhow::Result;
use ghoststream_gui_ipc::{ConnectProfile, TunnelSettings};
use slint::{ModelRc, SharedString, VecModel};
use std::rc::Rc;
use tokio::sync::mpsc;

use bridge::{clear_logs, reset_ui_to_idle, UiCommand};
use controller::{start_tunnel, ActiveTunnel};

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("GhostStream Windows client — Phase 4.3 tokio bridge");

    let window = MainWindow::new()?;
    seed_initial_state(&window);

    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel::<UiCommand>();

    // Wire UI callbacks → tokio commands.
    {
        let tx = cmd_tx.clone();
        window.on_connect_clicked(move || {
            let _ = tx.send(UiCommand::Connect);
        });
    }
    {
        let tx = cmd_tx.clone();
        window.on_disconnect_clicked(move || {
            let _ = tx.send(UiCommand::Disconnect);
        });
    }
    {
        let tx = cmd_tx.clone();
        window.on_change_profile_clicked(move || {
            let _ = tx.send(UiCommand::ChangeProfile);
        });
    }
    {
        let tx = cmd_tx.clone();
        window.on_quit_clicked(move || {
            let _ = tx.send(UiCommand::Quit);
            let _ = slint::quit_event_loop();
        });
    }
    {
        let weak = window.as_weak();
        window.on_toggle_logs_clicked(move || {
            if let Some(w) = weak.upgrade() {
                w.set_logs_open(!w.get_logs_open());
            }
        });
    }

    // Spawn tokio worker on a dedicated OS thread so the Slint event loop
    // stays free to repaint without contention.
    let weak = window.as_weak();
    std::thread::Builder::new()
        .name("ghoststream-worker".into())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("build tokio runtime");
            runtime.block_on(async move {
                run_worker(weak, cmd_rx).await;
            });
        })
        .expect("spawn worker thread");

    window.run()?;
    Ok(())
}

async fn run_worker(
    weak: slint::Weak<MainWindow>,
    mut cmd_rx: mpsc::UnboundedReceiver<UiCommand>,
) {
    let profile = load_profile_or_default();

    // Surface the profile name into the UI so the user can see whose
    // profile is loaded even before the first connect.
    let profile_label = profile.name.clone();
    let _ = weak.upgrade_in_event_loop(move |w| {
        w.set_profile_name(SharedString::from(profile_label));
    });
    reset_ui_to_idle(weak.clone());

    let mut active: Option<ActiveTunnel> = None;

    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            UiCommand::Connect => {
                if active.is_some() {
                    tracing::debug!("connect ignored: tunnel already active");
                    continue;
                }
                clear_logs(weak.clone());
                match start_tunnel(profile.clone(), weak.clone()).await {
                    Ok(tunnel) => {
                        tracing::info!("tunnel started");
                        active = Some(tunnel);
                    }
                    Err(e) => {
                        tracing::error!(error = %e, "tunnel start failed");
                        let weak2 = weak.clone();
                        let msg = format!("{:#}", e);
                        let _ = weak2.upgrade_in_event_loop(move |w| {
                            w.set_state_kind(SharedString::from("error"));
                            w.set_state_word(SharedString::from("Severed"));
                            w.set_last_error(SharedString::from(msg));
                        });
                    }
                }
            }
            UiCommand::Disconnect => {
                if let Some(tunnel) = active.take() {
                    tracing::info!("tunnel stopping");
                    tunnel.stop().await;
                    tracing::info!("tunnel stopped");
                    reset_ui_to_idle(weak.clone());
                }
            }
            UiCommand::ChangeProfile => {
                // Phase 4.5 will open the profile editor. For now log
                // and surface a hint via last_error so it's discoverable.
                tracing::info!("change profile not implemented yet");
                let weak2 = weak.clone();
                let _ = weak2.upgrade_in_event_loop(move |w| {
                    w.set_last_error(SharedString::from(
                        "Profile editor coming in next release",
                    ));
                });
            }
            UiCommand::Quit => {
                if let Some(tunnel) = active.take() {
                    tunnel.stop().await;
                }
                break;
            }
        }
    }
}

fn seed_initial_state(window: &MainWindow) {
    window.set_version_label(SharedString::from(concat!("v", env!("CARGO_PKG_VERSION"))));
    window.set_state_kind(SharedString::from("disconnected"));
    window.set_state_word(SharedString::from("Dormant"));
    window.set_session_timer(SharedString::from("00:00:00"));
    window.set_session_active(false);
    window.set_exit_label(SharedString::from("NL"));
    window.set_exit_server_name(SharedString::from("vdsina"));
    window.set_exit_endpoint(SharedString::from(""));
    window.set_rtt_text(SharedString::from("—"));
    window.set_rx_value(SharedString::from("0"));
    window.set_rx_unit(SharedString::from("B/s"));
    window.set_tx_value(SharedString::from("0"));
    window.set_tx_unit(SharedString::from("B/s"));
    window.set_streams_up(0);
    window.set_streams_total(4);
    window.set_streams(ModelRc::new(Rc::new(VecModel::from(Vec::<StreamBar>::new()))));
    window.set_profile_name(SharedString::from("—"));
    window.set_last_error(SharedString::from(""));
    window.set_logs_open(false);
    window.set_logs(ModelRc::new(Rc::new(VecModel::from(Vec::<LogLine>::new()))));
}

/// Load the persisted profile or fall back to a demo profile pointing at
/// the production exit. We intentionally do NOT auto-connect on launch —
/// `last_error` warns the user when they hit Connect with a placeholder.
fn load_profile_or_default() -> ConnectProfile {
    match client_windows_core::profile::load() {
        Ok(Some(p)) => {
            tracing::info!(name = %p.name, "loaded profile");
            p
        }
        Ok(None) => {
            tracing::info!("no saved profile, using built-in demo");
            demo_profile()
        }
        Err(e) => {
            tracing::warn!(error = %e, "profile load failed, using demo");
            demo_profile()
        }
    }
}

fn demo_profile() -> ConnectProfile {
    ConnectProfile {
        name: "vdsina · NL exit".into(),
        conn_string: "ghs://example/replace-with-real-conn-string".into(),
        settings: TunnelSettings::default(),
    }
}

