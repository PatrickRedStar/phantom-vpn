//! HTTP/2 transport: the client TLS config.

use std::sync::Arc;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};

/// Build a `rustls::ClientConfig` (ALPN offer `["h2", "http/1.1"]`, like a
/// browser; our server prefers `h2` and always selects it).
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

    tls_config.alpn_protocols = vec![b"h2".to_vec(), b"http/1.1".to_vec()];

    Ok(Arc::new(tls_config))
}
