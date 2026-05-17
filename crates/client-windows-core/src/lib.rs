//! `client-windows-core` — headless Rust core for the GhostStream Windows
//! client.
//!
//! Hosts the cross-platform pieces (profile load/save, mock TUN backend,
//! re-exports of the runtime's `TunBackend` trait) so that the bulk of
//! the Windows client can be developed and tested on a Mac. The Wintun-
//! specific backend is gated behind `cfg(windows)` and only links when
//! targeting Windows.

pub mod profile;
pub mod routing;
pub mod tun_backend;

pub use tun_backend::{MockBackend, TunBackend};

#[cfg(windows)]
pub use tun_backend::{WintunBackend, WintunConfig};

// `RouteScope` bookkeeping and the `CommandRunner` trait compile on every
// host — useful for the unit tests in `routing.rs` and for the dev loop
// on Mac. `discover_default_gateway` is the only piece that actually
// requires Windows (the Mac stub bails out loudly).
pub use routing::{discover_default_gateway, CommandRunner, RouteScope, ShellRunner};
