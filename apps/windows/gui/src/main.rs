//! GhostStream Windows GUI — Phase 1 skeleton.
//!
//! At this stage the binary just exercises the public API of
//! `client-windows-core` so we have something concrete to build against
//! while the Slint UI and the runtime integration land in later phases.

use client_windows_core::{MockBackend, TunBackend};

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    tracing::info!("GhostStream Windows client — Phase 1 skeleton");

    let backend = MockBackend::new();
    backend.push_rx(vec![0xDE, 0xAD, 0xBE, 0xEF]);
    let mut buf = [0u8; 8];
    let n = backend.read(&mut buf)?;
    tracing::info!(n, "mock backend read OK");

    Ok(())
}
