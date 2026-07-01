//! Raw TLS connection: TCP → TLS handshake (mTLS), returns split stream.
//! No HTTP/2 framing — just a bidirectional TLS byte stream.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;
use anyhow::{anyhow, Context};
use tokio::io::{ReadHalf, WriteHalf};
use tokio_rustls::client::TlsStream;

pub type TlsReadHalf = ReadHalf<TlsStream<tokio::net::TcpStream>>;
pub type TlsWriteHalf = WriteHalf<TlsStream<tokio::net::TcpStream>>;

/// Maximum wall time a single TCP+TLS handshake may consume.
///
/// CONC-C1 / bug‑bash 2026-05-17 #7: without an explicit cap the host kernel's
/// `TCP_SYN_RETRIES` default (≈75 s) holds the supervisor inside one
/// `tls_connect()` call, so a Disconnect issued mid-handshake had no chance to
/// be observed until the doomed attempt finally errored. 15 s is generous
/// enough that healthy networks finish well inside (typical p99 < 2 s on LTE)
/// while clearly bounding the "hung handshake" tail.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(15);

/// Connect via TCP/TLS, return split read/write halves.
///
/// Bounded by [`HANDSHAKE_TIMEOUT`]; if exceeded, returns a `handshake timeout`
/// error so the supervisor can surface a clean retry instead of waiting for
/// SYN_RETRIES.
pub async fn connect(
    server_addr: SocketAddr,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tokio::time::timeout(
        HANDSHAKE_TIMEOUT,
        connect_inner(server_addr, server_name, tls_config),
    )
    .await
    .map_err(|_| anyhow!("handshake timeout after {:?}", HANDSHAKE_TIMEOUT))?
}

async fn connect_inner(
    server_addr: SocketAddr,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tracing::debug!(
        category = "handshake",
        peer = %server_addr,
        local = "",
        "tcp.connect"
    );

    let tcp = tokio::net::TcpStream::connect(server_addr)
        .await
        .context("TCP connect failed")?;

    let local = tcp
        .local_addr()
        .map(|a| a.to_string())
        .unwrap_or_default();
    tracing::debug!(
        category = "handshake",
        peer = %server_addr,
        local = %local,
        "tcp.connected"
    );

    do_connect(tcp, server_name, tls_config).await
}

/// Perform TLS handshake on an already-connected TCP stream.
/// Used by Android where VpnService.protect() must be called on the raw socket
/// before any I/O (including TLS handshake).
///
/// Bounded by [`HANDSHAKE_TIMEOUT`] so a server that accepts the TCP connection
/// but never finishes the TLS ClientHello can't pin the supervisor.
pub async fn connect_with_tcp(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    tokio::time::timeout(
        HANDSHAKE_TIMEOUT,
        do_connect(tcp, server_name, tls_config),
    )
    .await
    .map_err(|_| anyhow!("handshake timeout after {:?}", HANDSHAKE_TIMEOUT))?
}

async fn do_connect(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    // TCP_NODELAY: disable Nagle (critical for upload latency).
    // Do NOT set SO_RCVBUF/SO_SNDBUF — disables TCP auto-tuning.
    let _ = tcp.set_nodelay(true);

    // v0.27.1 (DPI fix): SO_KEEPALIVE REMOVED (restores v0.22.4). It was added in
    // v0.25.0 against mobile-NAT eviction, but it emits deterministic empty TCP
    // keepalive segments every 30 s in lock-step across all 8 sockets — a periodic
    // on-wire signal that carrier-DPI uses to fingerprint a long-lived tunnel
    // (v0.22.4 had none). NAT is kept alive instead by the application-layer
    // heartbeat (random 15-45 s per stream, see `wire::build_heartbeat_frame`),
    // which is < typical NAT idle timeouts and is already de-correlated per stream
    // — exactly the mechanism v0.22.4 relied on.

    let sni_str = server_name.clone();
    tracing::debug!(
        category = "handshake",
        sni = %sni_str,
        alpn = "",
        "tls.client_hello"
    );
    let server_name = rustls::pki_types::ServerName::try_from(server_name)
        .context("Invalid server name")?;
    let tls_connector = tokio_rustls::TlsConnector::from(tls_config);
    let tls_stream = tls_connector
        .connect(server_name, tcp)
        .await
        .context("TLS handshake failed")?;

    tracing::debug!(
        category = "handshake",
        proto = "tls1.3",
        sni = %sni_str,
        "tls.alpn_negotiated"
    );
    Ok(tokio::io::split(tls_stream))
}
