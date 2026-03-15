//! QUIC connection establishment + Noise IK handshake over control stream.
//! After handshake, opens a bidirectional data stream for the tunnel.

use std::net::SocketAddr;

use anyhow::Context;

use phantom_core::crypto::{KeyPair, NoiseHandshake, NoiseSession};
use phantom_core::wire::N_DATA_STREAMS;

/// Connects to the server via QUIC, performs Noise IK handshake over a control stream,
/// then opens N_DATA_STREAMS bidirectional data streams for the tunnel.
///
/// Returns: (connection, noise_session, Vec<(send_stream, recv_stream)>)
pub async fn connect_and_handshake(
    endpoint:      &quinn::Endpoint,
    server_addr:   SocketAddr,
    server_name:   &str,
    client_keys:   &KeyPair,
    server_public: &[u8; 32],
) -> anyhow::Result<(quinn::Connection, NoiseSession, Vec<(quinn::SendStream, quinn::RecvStream)>)> {
    // 1. Connect to server (TLS 1.3 handshake happens automatically via quinn)
    tracing::info!("Connecting to {} (SNI: {}) via QUIC...", server_addr, server_name);
    let connection = endpoint
        .connect(server_addr, server_name)
        .context("Failed to start QUIC connection")?
        .await
        .context("QUIC connection failed")?;

    tracing::info!("QUIC connection established ({})", connection.remote_address());

    // 2. Open bidirectional control stream for Noise handshake
    let (mut send, mut recv) = connection
        .open_bi()
        .await
        .context("Failed to open control stream")?;

    // 3. Noise IK initiate: -> e, es, s, ss
    let (mut hs, init_msg) = NoiseHandshake::initiate(client_keys, server_public)
        .context("Noise initiate failed")?;

    // Frame: [4B length][payload]
    let len_bytes = (init_msg.len() as u32).to_be_bytes();
    send.write_all(&len_bytes).await.context("Failed to send handshake init length")?;
    send.write_all(&init_msg).await.context("Failed to send handshake init")?;

    tracing::debug!("Sent Noise IK init ({} bytes)", init_msg.len());

    // 4. Read server response: <- e, ee, se
    let mut resp_len_buf = [0u8; 4];
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        recv.read_exact(&mut resp_len_buf),
    )
    .await
    .context("Handshake response timeout (10s)")?
    .context("Failed to read response length")?;

    let resp_len = u32::from_be_bytes(resp_len_buf) as usize;
    if resp_len > 4096 {
        anyhow::bail!("Handshake response too large: {} bytes", resp_len);
    }

    let mut resp_buf = vec![0u8; resp_len];
    recv.read_exact(&mut resp_buf)
        .await
        .context("Failed to read handshake response")?;

    tracing::debug!("Received Noise IK response ({} bytes)", resp_len);

    // 5. Process server response
    hs.read_response(&resp_buf)
        .context("Noise read_response failed")?;

    // 6. Transition to transport mode
    let session = hs.into_transport()
        .context("Noise into_transport failed")?;

    // 7. Close control stream (handshake complete)
    let _ = send.finish();

    tracing::info!("Noise handshake completed over QUIC");

    // 8. Open N_DATA_STREAMS bidirectional data streams for tunnel traffic
    let mut streams = Vec::with_capacity(N_DATA_STREAMS);
    for i in 0..N_DATA_STREAMS {
        let pair = connection
            .open_bi()
            .await
            .with_context(|| format!("Failed to open data stream {}", i))?;
        streams.push(pair);
    }

    tracing::info!("{} data streams opened", N_DATA_STREAMS);

    Ok((connection, session, streams))
}
