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
///
/// The server certificate is ALWAYS verified: the webpki public root store
/// (real CAs like Let's Encrypt — production servers present LE certs) plus any
/// `server_ca` provided for self-signed deployments. The hostname is checked
/// against the SNI passed to the TLS connector. Client identity (mTLS) is
/// attached when present.
///
/// v0.27.0: the `skip_server_verify` escape hatch was removed. It disabled all
/// server verification — a MITM vector — and was unnecessary because production
/// servers present real LE certs. mTLS authenticates the *client* to the
/// server, not the server to the client, so it never substituted for server
/// verification. See ADR 0011.
pub fn make_h2_client_tls(
    server_ca: Option<Vec<CertificateDer<'static>>>,
    client_identity: Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>,
) -> anyhow::Result<Arc<rustls::ClientConfig>> {
    let roots = crate::tls::build_root_store(server_ca)?;
    let mut tls_config: rustls::ClientConfig = match client_identity {
        Some((certs, key)) => rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_client_auth_cert(certs, key)?,
        None => rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    };

    tls_config.alpn_protocols = vec![b"h2".to_vec()];

    Ok(Arc::new(tls_config))
}
