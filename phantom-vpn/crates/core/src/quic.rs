//! QUIC transport helpers: TLS certificate management and quinn config builders.

use std::path::Path;
use std::sync::Arc;

use quinn::crypto::rustls::QuicClientConfig;
use quinn::crypto::rustls::QuicServerConfig;
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

// ─── Self-signed certificate generation ─────────────────────────────────────

/// Generates a self-signed certificate for the given subject alternative names.
/// Subjects can be domain names or IP addresses (e.g. ["myserver.com", "1.2.3.4"]).
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

/// Loads PEM-encoded certificate chain and private key from disk.
/// Works with Let's Encrypt fullchain.pem + privkey.pem.
pub fn load_pem_certs(
    cert_path: &Path,
    key_path: &Path,
) -> anyhow::Result<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)> {
    let cert_data = std::fs::read(cert_path)?;
    let key_data = std::fs::read(key_path)?;

    let certs: Vec<CertificateDer<'static>> = rustls_pemfile::certs(&mut &cert_data[..])
        .collect::<Result<Vec<_>, _>>()?;

    if certs.is_empty() {
        anyhow::bail!("No certificates found in {}", cert_path.display());
    }

    let key = rustls_pemfile::private_key(&mut &key_data[..])?
        .ok_or_else(|| anyhow::anyhow!("No private key found in {}", key_path.display()))?;

    Ok((certs, key))
}

// ─── Quinn server config ────────────────────────────────────────────────────

/// Builds a `quinn::ServerConfig` with QUIC datagrams enabled and ALPN "h3".
pub fn make_server_config(
    certs: Vec<CertificateDer<'static>>,
    key: PrivateKeyDer<'static>,
    idle_timeout_secs: u64,
) -> anyhow::Result<quinn::ServerConfig> {
    let mut tls_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)?;

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
    transport.initial_mtu(1400);

    // High-throughput stream tuning
    transport.receive_window(quinn::VarInt::from_u32(32 * 1024 * 1024)); // 32 MB connection window
    transport.stream_receive_window(quinn::VarInt::from_u32(16 * 1024 * 1024)); // 16 MB per-stream window
    transport.send_window(16 * 1024 * 1024); // 16 MB send buffer
    // BBR congestion control — гораздо лучше NewReno для high-BDP каналов
    transport.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));

    server_config.transport_config(Arc::new(transport));

    Ok(server_config)
}

// ─── Quinn client config ────────────────────────────────────────────────────

/// Builds a `quinn::ClientConfig`.
/// If `skip_verify` is true, accepts any server certificate (for self-signed mode).
pub fn make_client_config(skip_verify: bool) -> quinn::ClientConfig {
    let tls_config = if skip_verify {
        let mut config = rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(SkipVerification))
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h3".to_vec()];
        config
    } else {
        let mut roots = rustls::RootCertStore::empty();
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        let mut config = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();
        config.alpn_protocols = vec![b"h3".to_vec()];
        config
    };

    let quic_client_config = QuicClientConfig::try_from(tls_config)
        .expect("Failed to create QUIC client config");
    let mut client_config = quinn::ClientConfig::new(Arc::new(quic_client_config));

    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(
        quinn::IdleTimeout::try_from(std::time::Duration::from_secs(30)).unwrap(),
    ));
    transport.keep_alive_interval(Some(std::time::Duration::from_secs(10)));
    transport.initial_mtu(1400);

    // High-throughput stream tuning
    transport.receive_window(quinn::VarInt::from_u32(32 * 1024 * 1024)); // 32 MB connection window
    transport.stream_receive_window(quinn::VarInt::from_u32(16 * 1024 * 1024)); // 16 MB per-stream window
    transport.send_window(16 * 1024 * 1024); // 16 MB send buffer
    // BBR congestion control — гораздо лучше NewReno для high-BDP каналов
    transport.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));

    client_config.transport_config(Arc::new(transport));

    client_config
}

// ─── Certificate verification skip (self-signed mode) ───────────────────────

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
