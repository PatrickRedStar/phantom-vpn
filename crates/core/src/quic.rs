//! QUIC transport helpers: TLS certificate management and quinn config builders.

use std::path::Path;
use std::sync::Arc;

use quinn::crypto::rustls::QuicClientConfig;
use quinn::crypto::rustls::QuicServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

// ─── Self-signed certificate generation ─────────────────────────────────────

pub fn self_signed_cert(
    subjects: Vec<String>,
) -> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let certified_key = rcgen::generate_simple_self_signed(subjects)?;
    let cert_der = CertificateDer::from(certified_key.cert.der().to_vec());
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        certified_key.key_pair.serialize_der(),
    ));
    Ok((vec![cert_der], key_der))
}

// ─── PEM certificate loading ────────────────────────────────────────────────

pub fn load_pem_certs(
    cert_path: &Path,
    key_path: &Path,
) -> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let cert_data = std::fs::read(cert_path)?;
    let key_data = std::fs::read(key_path)?;
    parse_pem_identity(&cert_data, &key_data)
}

/// Parse certificate + private key from PEM byte slices (inline or from file).
pub fn parse_pem_identity(
    cert_pem: &[u8],
    key_pem: &[u8],
) -> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut &cert_pem[..])
        .collect::<Result<Vec<_>, _>>()?;
    if certs.is_empty() {
        anyhow::bail!("No certificates found in PEM data");
    }
    let key = rustls_pemfile::private_key(&mut &key_pem[..])?
        .ok_or_else(|| anyhow::anyhow!("No private key found in PEM data"))?;
    Ok((certs, key))
}

/// Loads only the PEM certificate chain (no key).
pub fn load_pem_cert_chain(cert_path: &Path) -> anyhow::Result<Vec<CertificateDer<'static>>> {
    let cert_data = std::fs::read(cert_path)?;
    parse_pem_cert_chain(&cert_data)
}

/// Parse certificate chain from PEM byte slice (inline or from file).
pub fn parse_pem_cert_chain(cert_pem: &[u8]) -> anyhow::Result<Vec<CertificateDer<'static>>> {
    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut &cert_pem[..])
        .collect::<Result<Vec<_>, _>>()?;
    if certs.is_empty() {
        anyhow::bail!("No certificates found in PEM data");
    }
    Ok(certs)
}

// ─── Quinn server config ────────────────────────────────────────────────────

/// Builds a `quinn::ServerConfig`.
/// If `client_ca` is Some, enables optional mTLS:
///   - clients WITH a valid cert → tunnel mode
///   - clients WITHOUT cert → fallback mode (REALITY-style)
/// This ensures DPI probes see a normal TLS handshake, not a connection error.
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
        // allow_unauthenticated: if client has cert → verify it; if no cert → allow anyway
        // This is key for REALITY-style fallback: DPI probes connect without cert and see a normal site
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
/// - `skip_server_verify`: accept any server cert (legacy self-signed mode)
/// - `server_ca`: CA cert chain to verify server cert (used instead of system roots)
/// - `client_identity`: (cert_chain, key) for mTLS client authentication
pub fn make_client_config(
    skip_server_verify: bool,
    server_ca: Option<Vec<CertificateDer<'static>>>,
    client_identity: Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>,
) -> anyhow::Result<quinn::ClientConfig> {
    let mut tls_config: rustls::ClientConfig = match (skip_server_verify, client_identity) {
        (true, Some((certs, key))) => rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SkipVerification))
            .with_client_auth_cert(certs, key)?,
        (true, None) => rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SkipVerification))
            .with_no_client_auth(),
        (false, Some((certs, key))) => rustls::ClientConfig::builder()
            .with_root_certificates(build_root_store(server_ca)?)
            .with_client_auth_cert(certs, key)?,
        (false, None) => rustls::ClientConfig::builder()
            .with_root_certificates(build_root_store(server_ca)?)
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
    transport.receive_window(quinn::VarInt::from_u32(32 * 1024 * 1024));
    transport.stream_receive_window(quinn::VarInt::from_u32(16 * 1024 * 1024));
    transport.send_window(16 * 1024 * 1024);
    transport.datagram_receive_buffer_size(Some(4 * 1024 * 1024));
    transport.datagram_send_buffer_size(4 * 1024 * 1024);
    transport.congestion_controller_factory(Arc::new(crate::congestion::UnlimitedConfig));

    client_config.transport_config(Arc::new(transport));
    Ok(client_config)
}

// ─── Internal helpers ────────────────────────────────────────────────────────

fn build_root_store(
    ca_certs: Option<Vec<CertificateDer<'static>>>,
) -> anyhow::Result<Arc<rustls::RootCertStore>> {
    let mut roots = rustls::RootCertStore::empty();
    if let Some(certs) = ca_certs {
        for cert in certs {
            roots.add(cert)?;
        }
    } else {
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    }
    Ok(Arc::new(roots))
}

// ─── Certificate verification skip (legacy self-signed mode) ─────────────────

#[derive(Debug)]
struct SkipVerification;

impl rustls::client::danger::ServerCertVerifier for SkipVerification {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
            rustls::SignatureScheme::RSA_PKCS1_SHA256,
            rustls::SignatureScheme::RSA_PKCS1_SHA384,
            rustls::SignatureScheme::RSA_PKCS1_SHA512,
        ]
    }
}
