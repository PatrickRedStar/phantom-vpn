//! client_common: общая логика клиента PhantomVPN.
//! Содержит tunnel loops, handshake, key loading — всё, что не зависит от платформы.

pub mod tunnel;
pub mod helpers;
pub mod quic_tunnel;
pub mod quic_handshake;

pub use tunnel::{udp_rx_loop, tun_to_udp_loop};
pub use helpers::{perform_handshake, load_client_keys, load_server_public_key, load_shared_secret};
pub use quic_tunnel::{quic_stream_rx_loop, quic_stream_tx_loop};
pub use quic_handshake::connect_and_handshake;

// Re-export CLI args для единообразия
pub use clap;
pub use phantom_core;
