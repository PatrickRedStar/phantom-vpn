//! TLS certificate management: PEM loading, parsing, self-signed generation.

use std::path::Path;
use std::sync::Arc;

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

// ─── Internal helpers ────────────────────────────────────────────────────────

pub fn build_root_store(
    ca_certs: Option<Vec<CertificateDer<'static>>>,
) -> anyhow::Result<Arc<rustls::RootCertStore>> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    if let Some(certs) = ca_certs {
        for cert in certs {
            roots.add(cert)?;
        }
    }
    Ok(Arc::new(roots))
}

// ─── Certificate verification skip (legacy self-signed mode) ─────────────────

#[derive(Debug)]
pub struct SkipVerification;

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
