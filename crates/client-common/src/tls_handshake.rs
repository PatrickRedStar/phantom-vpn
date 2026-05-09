//! Raw TLS connection: TCP → TLS handshake (mTLS), returns split stream.
//! No HTTP/2 framing — just a bidirectional TLS byte stream.

use std::net::SocketAddr;
use std::sync::Arc;
use anyhow::Context;
use tokio::io::{ReadHalf, WriteHalf};
use tokio_rustls::client::TlsStream;

pub type TlsReadHalf = ReadHalf<TlsStream<tokio::net::TcpStream>>;
pub type TlsWriteHalf = WriteHalf<TlsStream<tokio::net::TcpStream>>;

/// Connect via TCP/TLS, return split read/write halves.
pub async fn connect(
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
pub async fn connect_with_tcp(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    do_connect(tcp, server_name, tls_config).await
}

async fn do_connect(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(TlsReadHalf, TlsWriteHalf)> {
    // TCP_NODELAY: disable Nagle (critical for upload latency).
    // Do NOT set SO_RCVBUF/SO_SNDBUF — disables TCP auto-tuning.
    let _ = tcp.set_nodelay(true);

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
