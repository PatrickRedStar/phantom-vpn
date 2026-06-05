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

    // v0.25.0: SO_KEEPALIVE — мобильные NAT'ы выкидывают idle TCP entry
    // за 60-180s. Heartbeat ходит через TLS-layer, но если NAT уже выпилен
    // до того как heartbeat пройдёт — пакет получает RST. Keepalive
    // проактивно держит NAT entry живой. Bug #8.
    // v0.26.21: ранее `let _ =` глотал ошибку. На Android setsockopt мог
    // тихо фейлиться — фантом-туннель сохранялся «несмотря на keepalive».
    // Теперь Err видна в logcat.
    {
        use socket2::{SockRef, TcpKeepalive};
        let keepalive = TcpKeepalive::new()
            .with_time(std::time::Duration::from_secs(30))
            .with_interval(std::time::Duration::from_secs(15))
            .with_retries(3);
        if let Err(e) = SockRef::from(&tcp).set_tcp_keepalive(&keepalive) {
            tracing::warn!(
                category = "handshake",
                event = "tcp_keepalive_failed",
                error = %e,
                "set_tcp_keepalive failed — NAT timeout may strike"
            );
        } else {
            tracing::debug!(
                category = "handshake",
                event = "tcp_keepalive_set",
                time_secs = 30u64,
                interval_secs = 15u64,
                retries = 3u64,
                "tcp keepalive configured"
            );
        }
    }

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
