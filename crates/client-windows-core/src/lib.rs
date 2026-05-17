//! `client-windows-core` — headless Rust core for the GhostStream Windows
//! client.
//!
//! Hosts the cross-platform pieces (profile load/save, TUN trait, mock
//! backend) so that the bulk of the Windows client can be developed and
//! tested on a Mac. The Wintun-specific backend is gated behind
//! `cfg(windows)` and only links when targeting Windows.

pub mod profile;
pub mod tun_backend;

pub use tun_backend::{MockBackend, TunBackend};

#[cfg(windows)]
pub use tun_backend::WintunBackend;
