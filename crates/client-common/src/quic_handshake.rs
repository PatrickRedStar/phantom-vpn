//! QUIC connection establishment.
//! Authentication is handled by mTLS at the TLS layer — no additional handshake needed.
//! After connecting, opens N_DATA_STREAMS bidirectional data streams for the tunnel.

use std::net::SocketAddr;
use anyhow::Context;
use phantom_core::wire::N_DATA_STREAMS;

/// Connects to the server via QUIC (mTLS or insecure), then opens N_DATA_STREAMS
/// bidirectional data streams for the tunnel.
///
/// Returns: (connection, Vec<(send_stream, recv_stream)>)
pub async fn connect_and_handshake(
    endpoint:    &quinn::Endpoint,
    server_addr: SocketAddr,
    server_name: &str,
) -> anyhow::Result<(quinn::Connection, Vec<(quinn::SendStream, quinn::RecvStream)>)> {
    tracing::info!("Connecting to {} (SNI: {}) via QUIC...", server_addr, server_name);
    let connection = endpoint
        .connect(server_addr, server_name)
        .context("Failed to start QUIC connection")?
        .await
        .context("QUIC connection failed")?;

    tracing::info!("QUIC connection established ({})", connection.remote_address());

    // Open N_DATA_STREAMS bidirectional streams for tunnel traffic.
    // Send a probe frame immediately on each stream so the server's accept_bi()
    // sees the stream (QUIC only delivers a stream to the peer when data is sent).
    // Probe: [4B frame_len=4][2B 0x0000 end-of-batch][2B padding] — parses as empty batch.
    const PROBE: &[u8] = &[0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00];

    let mut streams = Vec::with_capacity(N_DATA_STREAMS);
    for i in 0..N_DATA_STREAMS {
        let (mut send, recv) = connection
            .open_bi()
            .await
            .with_context(|| format!("Failed to open data stream {}", i))?;
        tokio::io::AsyncWriteExt::write_all(&mut send, PROBE)
            .await
            .with_context(|| format!("Failed to probe stream {}", i))?;
        streams.push((send, recv));
    }

    tracing::info!("{} data streams opened", N_DATA_STREAMS);
    Ok((connection, streams))
}
