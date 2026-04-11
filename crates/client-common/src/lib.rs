//! client_common: общая логика клиента PhantomVPN.
//! Raw TLS tunnel (no HTTP/2 framing), handshake, key loading — всё, что не зависит от платформы.

pub mod helpers;
pub mod tls_handshake;
pub mod tls_tunnel;

pub use helpers::Args;
pub use tls_handshake::{connect as tls_connect, connect_with_tcp as tls_connect_with_tcp};
pub use tls_tunnel::{tls_rx_loop, tls_tx_loop, write_handshake};

/// If `addr` lacks a port, append `:<default_port>`. Handles plain hostnames
/// and bare IPv4 — IPv6 literals must already be in `[::1]:443` form from the
/// caller. Motivation: Android UI lets the user edit `serverAddr` by hand and
/// it's easy to drop the `:443`, which then fails `lookup_host` with the
/// cryptic "invalid socket address". Call before `lookup_host`.
pub fn with_default_port(addr: &str, default_port: u16) -> String {
    // Already has a port if the last ':' is followed by digits (and it's not
    // an unbracketed IPv6 literal). Accept if parses as SocketAddr OR the
    // tail after last ':' is a valid u16.
    if addr.parse::<std::net::SocketAddr>().is_ok() {
        return addr.to_string();
    }
    if let Some(idx) = addr.rfind(':') {
        // For IPv6-literal `::1` the rfind is at the wrong spot; bail on any
        // string with multiple ':' and no brackets — user must use `[..]:port`.
        let head_has_colon = addr[..idx].contains(':');
        let tail_is_port = addr[idx + 1..].parse::<u16>().is_ok();
        if !head_has_colon && tail_is_port {
            return addr.to_string();
        }
    }
    format!("{}:{}", addr, default_port)
}

pub use clap;
pub use phantom_core;
