//! GhostStream Windows GUI — Phase 3 working build.
//!
//! At this point the binary wires up the Wintun backend behind the same
//! `TunBackend` trait the runtime drives. The Slint UI and the tray icon
//! land in Phase 4; for now the binary prints what it found and exits.

#[cfg(windows)]
mod wintun_loader;

use client_windows_core::{MockBackend, TunBackend};

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("GhostStream Windows client — Phase 3 build");

    // Exercise the cross-platform mock so the headless smoke is identical
    // on Mac and Windows.
    let mock = MockBackend::new();
    mock.push_rx(vec![0xDE, 0xAD, 0xBE, 0xEF]);
    let mut buf = [0u8; 8];
    let n = mock.read(&mut buf)?;
    tracing::info!(n, "mock backend OK");

    // On Windows, try to locate the Wintun DLL. We don't open the adapter
    // here yet — that needs a real connection profile, which the GUI in
    // Phase 4 will provide. This call just verifies the DLL discovery
    // path so an end user sees a clear error early ("wintun.dll not
    // found next to the exe") rather than getting bitten later.
    #[cfg(windows)]
    match wintun_loader::locate_wintun_dll() {
        Ok(path) => tracing::info!(path = %path.display(), "wintun.dll located"),
        Err(e) => tracing::warn!(error = %e, "wintun.dll discovery failed"),
    }

    Ok(())
}
