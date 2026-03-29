//! client_common: общая логика клиента PhantomVPN.
//! Содержит tunnel loops, handshake, key loading — всё, что не зависит от платформы.

pub mod tunnel;
pub mod helpers;
pub mod quic_tunnel;
pub mod quic_handshake;
pub mod h2_handshake;
pub mod h2_tunnel;

pub use tunnel::{udp_rx_loop, tun_to_udp_loop};
pub use helpers::Args;
pub use quic_tunnel::{quic_stream_rx_loop, quic_stream_tx_loop};
pub use quic_handshake::connect_and_handshake;
pub use h2_handshake::{connect_and_handshake as h2_connect_and_handshake, connect_with_tcp_stream as h2_connect_with_tcp_stream};
pub use h2_tunnel::{h2_stream_rx_loop, h2_stream_tx_loop};

// Re-export CLI args для единообразия
pub use clap;
pub use phantom_core;
