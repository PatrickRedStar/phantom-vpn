//! GhostStream Windows GUI — entry point.
//!
//! At this phase we wire up the Slint UI shell. The tokio bridge that
//! actually drives `client-core-runtime` lives in subsequent commits.

// Disable the console window on release Windows builds — `windowed`
// applications should not flash a black cmd.exe when launched from
// Explorer. Debug builds keep the console so panics are visible.
#![cfg_attr(all(target_os = "windows", not(debug_assertions)), windows_subsystem = "windows")]

#[cfg(windows)]
mod wintun_loader;

slint::include_modules!();

use anyhow::Result;
use client_windows_core::{MockBackend, TunBackend};

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("GhostStream Windows client — Phase 4 UI scaffolding");

    // Brand fonts ship in `assets/fonts/`. Slint 1.15 doesn't expose a
    // public `register_font_from_memory` for the femtovg backend, so we
    // either:
    //   1. embed via `slint-build` (Phase 4 polish — needs @font-face
    //      directives in the .slint files), or
    //   2. fall back to system fonts (Segoe UI on Windows) for now.
    // The bytes are still in the repo so the embed path stays an
    // incremental change rather than a font-rights question.

    // Headless smoke — exercise MockBackend even from the GUI binary so
    // the cross-platform code path stays warm.
    let mock = MockBackend::new();
    mock.push_rx(vec![0xDE, 0xAD, 0xBE, 0xEF]);
    let mut buf = [0u8; 8];
    let _ = mock.read(&mut buf);

    #[cfg(windows)]
    if let Err(e) = wintun_loader::locate_wintun_dll() {
        tracing::warn!(error = %e, "wintun.dll discovery failed; Connect will not work");
    }

    let window = MainWindow::new()?;
    seed_demo_state(&window);
    window.on_connect_clicked(|| tracing::info!("connect clicked (no-op in Phase 4.2)"));
    window.on_disconnect_clicked(|| tracing::info!("disconnect clicked (no-op)"));
    window.on_change_profile_clicked(|| tracing::info!("change profile clicked (no-op)"));
    window.on_quit_clicked(|| {
        let _ = slint::quit_event_loop();
    });
    {
        let weak = window.as_weak();
        window.on_toggle_logs_clicked(move || {
            if let Some(w) = weak.upgrade() {
                w.set_logs_open(!w.get_logs_open());
            }
        });
    }

    window.run()?;
    Ok(())
}

fn seed_demo_state(window: &MainWindow) {
    use slint::{ModelRc, SharedString, VecModel};
    use std::rc::Rc;

    window.set_version_label(SharedString::from("v0.1.0"));
    window.set_state_kind(SharedString::from("disconnected"));
    window.set_state_word(SharedString::from("Dormant"));
    window.set_session_timer(SharedString::from("00:00:00"));
    window.set_session_active(false);
    window.set_exit_label(SharedString::from("NL"));
    window.set_exit_server_name(SharedString::from("vdsina"));
    window.set_exit_endpoint(SharedString::from("89.110.109.128 : 443"));
    window.set_rtt_text(SharedString::from("—"));
    window.set_rx_value(SharedString::from("0"));
    window.set_rx_unit(SharedString::from("B/s"));
    window.set_tx_value(SharedString::from("0"));
    window.set_tx_unit(SharedString::from("B/s"));
    window.set_streams_up(0);
    window.set_streams_total(4);
    window.set_streams(ModelRc::new(VecModel::from(Vec::<StreamBar>::new())));
    window.set_profile_name(SharedString::from("vdsina · NL exit"));
    window.set_last_error(SharedString::from(""));
    window.set_logs_open(false);
    window.set_logs(ModelRc::new(Rc::new(VecModel::from(Vec::<LogLine>::new()))));
}
