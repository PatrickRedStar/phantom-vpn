//! HTTP/2 transport: TLS config builders and constants.
//! Shared between server and client.

use std::sync::Arc;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

/// Tunnel stream path prefix: POST /v1/tunnel/{0..N}
pub const H2_TUNNEL_PATH: &str = "/v1/tunnel/";

/// TCP MSS for HTTP/2 transport (TCP+TLS overhead > QUIC overhead)
pub const H2_TUNNEL_MSS: u16 = 1360;

/// Build a `rustls::ServerConfig` for HTTP/2 (ALPN=["h2"], optional mTLS).
/// Same mTLS logic as QUIC: if `client_ca` is Some, clients without cert get fallback.
pub fn make_h2_server_tls(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
    client_ca: Option<Vec<CertificateDer<'static>>>,
) -> anyhow::Result<Arc<rustls::ServerConfig>> {
    let mut tls_config = if let Some(ca_certs) = client_ca {
        let mut roots = rustls::RootCertStore::empty();
        for cert in ca_certs {
            roots.add(cert)?;
        }
        let verifier = rustls::server::WebPkiClientVerifier::builder(Arc::new(roots))
            .allow_unauthenticated()
            .build()
            .map_err(|e| anyhow::anyhow!("Failed to build client verifier: {}", e))?;
        rustls::ServerConfig::builder()
            .with_client_cert_verifier(verifier)
            .with_single_cert(certs, key)?
    } else {
        rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(certs, key)?
    };

    tls_config.alpn_protocols = vec![b"h2".to_vec()];
    tls_config.max_early_data_size = 0;

    Ok(Arc::new(tls_config))
}

/// Build a `rustls::ClientConfig` for HTTP/2 (ALPN=["h2"]).
pub fn make_h2_client_tls(
    skip_server_verify: bool,
    server_ca: Option<Vec<CertificateDer<'static>>>,
    client_identity: Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>,
) -> anyhow::Result<Arc<rustls::ClientConfig>> {
    let tls_config: rustls::ClientConfig = match (skip_server_verify, client_identity) {
        (true, Some((certs, key))) => rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(crate::quic::SkipVerification))
            .with_client_auth_cert(certs, key)?,
        (true, None) => rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(crate::quic::SkipVerification))
            .with_no_client_auth(),
        (false, Some((certs, key))) => rustls::ClientConfig::builder()
            .with_root_certificates(crate::quic::build_root_store(server_ca)?)
            .with_client_auth_cert(certs, key)?,
        (false, None) => rustls::ClientConfig::builder()
            .with_root_certificates(crate::quic::build_root_store(server_ca)?)
            .with_no_client_auth(),
    };

    // Note: we don't set ALPN here — the caller wraps in tokio-rustls
    // where ALPN=["h2"] is set via the connector
    // Actually, set it here for consistency:
    let mut cfg = tls_config;
    cfg.alpn_protocols = vec![b"h2".to_vec()];

    Ok(Arc::new(cfg))
}
