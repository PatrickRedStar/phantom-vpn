//! QUIC transport helpers: quinn config builders.
//! PEM certificate loading moved to `tls` module.

use std::sync::Arc;

use quinn::crypto::rustls::QuicClientConfig;
use quinn::crypto::rustls::QuicServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

// Re-export cert helpers for backwards compatibility
pub use crate::tls::{
    self_signed_cert, load_pem_certs, parse_pem_identity,
    load_pem_cert_chain, parse_pem_cert_chain,
};

// ─── Quinn server config ────────────────────────────────────────────────────

/// Builds a `quinn::ServerConfig`.
pub fn make_server_config(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
    idle_timeout_secs: u64,
    client_ca: Option<Vec<CertificateDer<'static>>>,
) -> anyhow::Result<quinn::ServerConfig> {
    let mut tls_config = if let Some(ca_certs) = client_ca {
        let mut roots = rustls::RootCertStore::empty();
        for cert in ca_certs {
            roots.add(cert)?;
        }
        let verifier = rustls::server::WebPkiClientVerifier::builder(Arc::new(roots))
            .allow_unauthenticated()
            .build()
            .map_err(|e| anyhow::anyhow!("Failed to build client cert verifier: {}", e))?;
        rustls::ServerConfig::builder()
            .with_client_cert_verifier(verifier)
            .with_single_cert(certs, key)?
    } else {
        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, key)?
    };

    tls_config.alpn_protocols = vec![b"h3".to_vec()];
    tls_config.max_early_data_size = 0;

    let quic_server_config = QuicServerConfig::try_from(tls_config)?;
    let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(quic_server_config));

    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(
        quinn::IdleTimeout::try_from(std::time::Duration::from_secs(idle_timeout_secs))
            .map_err(|e| anyhow::anyhow!("Invalid idle timeout: {}", e))?,
    ));
    transport.keep_alive_interval(Some(std::time::Duration::from_secs(10)));
    transport.initial_mtu(1450);
    transport.mtu_discovery_config(Some(quinn::MtuDiscoveryConfig::default()));
    transport.receive_window(quinn::VarInt::from_u32(32 * 1024 * 1024));
    transport.stream_receive_window(quinn::VarInt::from_u32(16 * 1024 * 1024));
    transport.send_window(16 * 1024 * 1024);
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    transport.congestion_controller_factory(Arc::new(crate::congestion::UnlimitedConfig));

    server_config.transport_config(Arc::new(transport));
    Ok(server_config)
}

// ─── Quinn client config ────────────────────────────────────────────────────

/// Builds a `quinn::ClientConfig`.
pub fn make_client_config(
    skip_server_verify: bool,
    server_ca: Option<Vec<CertificateDer<'static>>>,
    client_identity: Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>,
) -> anyhow::Result<quinn::ClientConfig> {
    let mut tls_config: rustls::ClientConfig = match (skip_server_verify, client_identity) {
        (true, Some((certs, key))) => rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(crate::tls::SkipVerification))
            .with_client_auth_cert(certs, key)?,
        (true, None) => rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(crate::tls::SkipVerification))
            .with_no_client_auth(),
        (false, Some((certs, key))) => rustls::ClientConfig::builder()
            .with_root_certificates(crate::tls::build_root_store(server_ca)?)
            .with_client_auth_cert(certs, key)?,
        (false, None) => rustls::ClientConfig::builder()
            .with_root_certificates(crate::tls::build_root_store(server_ca)?)
            .with_no_client_auth(),
    };

    tls_config.alpn_protocols = vec![b"h3".to_vec()];

    let quic_client_config = QuicClientConfig::try_from(tls_config)
        .map_err(|e| anyhow::anyhow!("Failed to create QUIC client config: {}", e))?;
    let mut client_config = quinn::ClientConfig::new(Arc::new(quic_client_config));

    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(
        quinn::IdleTimeout::try_from(std::time::Duration::from_secs(120)).unwrap(),
    ));
    transport.keep_alive_interval(Some(std::time::Duration::from_secs(10)));
    transport.initial_mtu(1450);
    transport.mtu_discovery_config(Some(quinn::MtuDiscoveryConfig::default()));
    transport.receive_window(quinn::VarInt::from_u32(32 * 1024 * 1024));
    transport.stream_receive_window(quinn::VarInt::from_u32(16 * 1024 * 1024));
    transport.send_window(16 * 1024 * 1024);
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    transport.congestion_controller_factory(Arc::new(crate::congestion::UnlimitedConfig));

    client_config.transport_config(Arc::new(transport));
    Ok(client_config)
}
