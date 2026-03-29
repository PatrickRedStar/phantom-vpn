//! HTTP/2 connection establishment.
//! Connects via TCP/TLS, performs HTTP/2 handshake, opens tunnel streams.

use std::net::SocketAddr;
use std::sync::Arc;
use anyhow::Context;
use phantom_core::wire::N_DATA_STREAMS;

/// Connects to the server via TCP/TLS (mTLS or insecure), performs HTTP/2 handshake,
/// and opens N_DATA_STREAMS for the tunnel.
///
/// Returns: (h2::client::SendRequest, Vec<(h2::SendStream, h2::RecvStream)>)
pub async fn connect_and_handshake(
    server_addr: SocketAddr,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(h2::client::SendRequest<bytes::Bytes>, Vec<(h2::SendStream<bytes::Bytes>, h2::RecvStream)>)> {

    tracing::info!("Connecting to {} (SNI: {}) via TCP/TLS...", server_addr, server_name);

    // 1. TCP connect
    let tcp = tokio::net::TcpStream::connect(server_addr)
        .await
        .context("Failed to connect TCP")?;
    tracing::debug!("TCP connected to {}", server_addr);

    do_connect_and_handshake(tcp, server_name, tls_config).await
}

/// Performs HTTP/2 handshake using an already-connected TCP stream.
/// This is used by Android to call VpnService.protect() on the socket before TLS.
///
/// Returns: (h2::client::SendRequest, Vec<(h2::SendStream, h2::RecvStream)>)
pub async fn connect_with_tcp_stream(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(h2::client::SendRequest<bytes::Bytes>, Vec<(h2::SendStream<bytes::Bytes>, h2::RecvStream)>)> {
    tracing::info!("Performing HTTP/2 handshake on protected TCP stream...");
    do_connect_and_handshake(tcp, server_name, tls_config).await
}

async fn do_connect_and_handshake(
    tcp: tokio::net::TcpStream,
    server_name: String,
    tls_config: Arc<rustls::ClientConfig>,
) -> anyhow::Result<(h2::client::SendRequest<bytes::Bytes>, Vec<(h2::SendStream<bytes::Bytes>, h2::RecvStream)>)> {
    tracing::debug!("TCP connected");

    // TCP_NODELAY: disable Nagle algorithm (critical for upload throughput).
    // Do NOT set SO_RCVBUF/SO_SNDBUF explicitly — explicit setsockopt disables TCP
    // auto-tuning and caps buffers at rmem_max (~208KB on most VPS). Auto-tuning
    // grows buffers up to tcp_rmem max (6MB) as needed, which is far better.
    let _ = tcp.set_nodelay(true);

    // 2. TLS handshake
    let server_name = rustls::pki_types::ServerName::try_from(server_name)
        .context("Invalid server name")?;
    let tls_connector = tokio_rustls::TlsConnector::from(tls_config);
    let tls_stream = tls_connector
        .connect(server_name, tcp)
        .await
        .context("TLS handshake failed")?;
    tracing::debug!("TLS handshake completed");

    // 3. HTTP/2 handshake (moderate windows: 4MB/stream, 16MB connection)
    //    Avoid extreme values — they cause 128MB+ memory pressure on Android.
    //    BDP at 500Mbps/30ms ≈ 1.9MB, so 4MB/stream is ~2x headroom.
    let mut h2_builder = h2::client::Builder::default();
    h2_builder.initial_window_size(4 * 1024 * 1024);
    h2_builder.initial_connection_window_size(16 * 1024 * 1024);
    let (mut send_request, connection) = h2_builder.handshake(tls_stream).await
        .context("HTTP/2 handshake failed")?;
    tracing::debug!("HTTP/2 handshake completed");

    // Spawn connection driver in background
    tokio::spawn(async move {
        // Drive the HTTP/2 connection to completion
        if let Err(e) = connection.await {
            tracing::debug!("HTTP/2 connection error: {}", e);
        }
    });

    // 4. Open N_DATA_STREAMS tunnel streams: POST /v1/tunnel/{0..N-1}
    let mut streams = Vec::with_capacity(N_DATA_STREAMS);
    for i in 0..N_DATA_STREAMS {
        let path = format!("/v1/tunnel/{}", i);
        let request = http::Request::builder()
            .method(http::Method::POST)
            .uri(&path)
            .header("content-type", "application/grpc")
            .body(())
            .context("Failed to build request")?;

        let (response, send) = send_request
            .send_request(request, false)
            .context("Failed to send request")?;

        // Wait for 200 OK response
        let response = response.await.context("Failed to get response")?;
        if response.status() != http::StatusCode::OK {
            anyhow::bail!("Stream {} returned status {}", i, response.status());
        }

        let recv = response.into_body();
        streams.push((send, recv));
    }

    tracing::info!("{} HTTP/2 tunnel streams opened", N_DATA_STREAMS);
    Ok((send_request, streams))
}
