//! client_common: общая логика клиента PhantomVPN.
//! Raw TLS tunnel (no HTTP/2 framing), handshake, key loading — всё, что не зависит от платформы.

pub mod helpers;
pub mod tls_handshake;
pub mod tls_tunnel;

pub use helpers::Args;
pub use tls_handshake::{connect as tls_connect, connect_with_tcp as tls_connect_with_tcp};
pub use tls_tunnel::{tls_rx_loop, tls_tx_loop, write_stream_idx};

pub use clap;
pub use phantom_core;
