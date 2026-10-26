//! HTTP client for the phantom-server admin API.
//!
//! Used by the Admin screen. Same scheme as Android/macOS: mTLS to
//! `https://<tunnel gateway>:8080` with the profile's own client cert — only
//! reachable through the VPN tunnel, so the Admin screen works only while
//! connected. The server accepts a Bearer token only from its loopback (bot),
//! so none is sent. The admin-server cert is self-signed: it is pinned by
//! SHA-256 on first use (`Profile::admin_server_cert_fp`), later answers from
//! a different cert are rejected.

use anyhow::Context;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::WebPkiSupportedAlgorithms;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use std::time::Duration;

use crate::profiles::Profile;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerStatus {
    #[serde(default)] pub uptime_secs: u64,
    #[serde(default)] pub active_sessions: u64,
    #[serde(default)] pub server_ip: Option<String>,
    #[serde(default)] pub cpu_pct: Option<f64>,
    // tolerate additional fields
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientEntry {
    pub name: String,
    #[serde(default)] pub fingerprint: String,
    #[serde(default)] pub tun_addr: String,
    #[serde(default)] pub enabled: bool,
    #[serde(default)] pub connected: bool,
    #[serde(default)] pub bytes_rx: u64,
    #[serde(default)] pub bytes_tx: u64,
    #[serde(default)] pub created_at: Option<String>,
    #[serde(default)] pub last_seen_secs: Option<u64>,
    /// Unix timestamp; None = unlimited.
    #[serde(default)] pub expires_at: Option<i64>,
    #[serde(default)] pub is_admin: bool,
}

impl ClientEntry {
    /// Days remaining until expiry. `None` if unlimited. Negative if expired.
    pub fn days_left(&self) -> Option<i64> {
        let exp = self.expires_at?;
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        Some((exp - now) / 86_400)
    }
}

pub struct AdminClient {
    /// Profile this client was built from — where a new pin is saved.
    pub profile_id: String,
    base_url: String,
    pin: Arc<PinVerifier>,
    http: reqwest::Client,
}

impl AdminClient {
    pub fn new(profile: &Profile) -> anyhow::Result<Self> {
        let cfg = client_common::helpers::parse_conn_string(&profile.conn_string)?;
        let tls = cfg.tls.unwrap_or_default();
        let (Some(cert), Some(key)) = (tls.cert_pem, tls.key_pem) else {
            anyhow::bail!("profile has no client certificate — the admin API needs it (mTLS)");
        };
        let (certs, key) = client_common::phantom_core::tls::parse_pem_identity(cert.as_bytes(), key.as_bytes())
            .context("client certificate from the profile")?;
        // The admin listener is TLS-only; old profiles stored an http:// URL.
        let base_url = match profile.admin_url.as_deref().map(str::trim) {
            Some(u) if !u.is_empty() => u.replacen("http://", "https://", 1),
            _ => format!("https://{}:8080", gateway(&profile.tun_addr)),
        };
        let provider = rustls::crypto::ring::default_provider();
        let pin = Arc::new(PinVerifier {
            pinned: profile.admin_server_cert_fp.as_deref().map(normalize_fp),
            seen: Default::default(),
            algs: provider.signature_verification_algorithms,
        });
        let tls = rustls::ClientConfig::builder_with_provider(Arc::new(provider))
            .with_safe_default_protocol_versions()?
            .dangerous()
            .with_custom_certificate_verifier(pin.clone())
            .with_client_auth_cert(certs, key)?;
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .use_preconfigured_tls(tls)
            .build()
            .context("reqwest client")?;
        Ok(Self {
            profile_id: profile.id.clone(),
            base_url: base_url.trim_end_matches('/').to_string(),
            pin,
            http,
        })
    }

    fn url(&self, path: &str) -> String { format!("{}{}", self.base_url, path) }

    async fn send(&self, req: reqwest::RequestBuilder) -> anyhow::Result<reqwest::Response> {
        Ok(req.send().await?.error_for_status()?)
    }

    /// The admin-server cert seen while nothing was pinned yet. The caller
    /// saves it as the pin after a successful answer (trust on first use).
    pub fn new_pin(&self) -> Option<String> {
        if self.pin.pinned.is_some() {
            return None;
        }
        self.pin.seen.lock().unwrap().clone()
    }

    pub async fn list_clients(&self) -> anyhow::Result<Vec<ClientEntry>> {
        let resp = self.send(self.http.get(self.url("/api/clients"))).await?;
        Ok(resp.json::<Vec<ClientEntry>>().await?)
    }

    pub async fn server_status(&self) -> anyhow::Result<ServerStatus> {
        let resp = self.send(self.http.get(self.url("/api/status"))).await?;
        // Server returns arbitrary JSON; we tolerate.
        let v: serde_json::Value = resp.json().await?;
        Ok(serde_json::from_value(v).unwrap_or(ServerStatus {
            uptime_secs: 0, active_sessions: 0, server_ip: None, cpu_pct: None,
        }))
    }

    pub async fn create_client(&self, name: &str, expires_days: Option<u32>) -> anyhow::Result<()> {
        #[derive(Serialize)]
        struct Req<'a> { name: &'a str, #[serde(skip_serializing_if = "Option::is_none")] expires_days: Option<u32> }
        let req = Req { name, expires_days };
        self.send(self.http.post(self.url("/api/clients")).json(&req)).await?;
        Ok(())
    }

    pub async fn get_conn_string(&self, name: &str) -> anyhow::Result<String> {
        let resp = self.send(self.http.get(self.url(&format!("/api/clients/{name}/conn_string")))).await?;
        // The server returns either plain-text or `{"conn_string":"..."}`; tolerate both.
        let txt = resp.text().await?;
        let trimmed = txt.trim();
        if trimmed.starts_with('{') {
            let v: serde_json::Value = serde_json::from_str(trimmed)?;
            if let Some(s) = v.get("conn_string").and_then(|x| x.as_str()) {
                return Ok(s.to_string());
            }
        }
        Ok(trimmed.to_string())
    }

    pub async fn delete_client(&self, name: &str) -> anyhow::Result<()> {
        self.send(self.http.delete(self.url(&format!("/api/clients/{name}")))).await?;
        Ok(())
    }

    pub async fn toggle_enabled(&self, name: &str, enabled: bool) -> anyhow::Result<()> {
        let path = if enabled {
            format!("/api/clients/{name}/enable")
        } else {
            format!("/api/clients/{name}/disable")
        };
        self.send(self.http.post(self.url(&path))).await?;
        Ok(())
    }

    pub async fn extend_subscription(&self, name: &str, days: u32) -> anyhow::Result<()> {
        #[derive(Serialize)]
        struct Req<'a> { action: &'a str, days: u32 }
        let req = Req { action: "extend", days };
        self.send(self.http.post(self.url(&format!("/api/clients/{name}/subscription"))).json(&req)).await?;
        Ok(())
    }
}

/// The admin-server cert is self-signed and carries no name worth checking:
/// accept only the pinned one (any, while nothing is pinned yet), but still
/// verify the handshake signature, so a copy of the cert without its key does
/// not pass.
#[derive(Debug)]
struct PinVerifier {
    pinned: Option<String>,
    seen: std::sync::Mutex<Option<String>>,
    algs: WebPkiSupportedAlgorithms,
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let fp = hex(&Sha256::digest(end_entity));
        if self.pinned.as_ref().is_some_and(|p| *p != fp) {
            return Err(rustls::Error::General(format!(
                "admin server certificate changed (got {fp}); clear the pin in the profile if this is expected"
            )));
        }
        *self.seen.lock().unwrap() = Some(fp);
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.algs)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.algs)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.algs.supported_schemes()
    }
}

/// Admin API lives on the tunnel gateway: x.y.z.1 of the profile's TUN subnet.
fn gateway(tun_addr: &str) -> String {
    let ip = tun_addr.split('/').next().unwrap_or_default();
    match ip.rsplit_once('.') {
        Some((net, _)) if ip.split('.').count() == 4 => format!("{net}.1"),
        _ => "10.7.0.1".into(),
    }
}

/// Pins are compared as lowercase hex without separators ("AB:CD…" is fine too).
fn normalize_fp(fp: &str) -> String {
    fp.chars().filter(char::is_ascii_hexdigit).collect::<String>().to_ascii_lowercase()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gateway_and_pin_format() {
        assert_eq!(gateway("10.7.0.5/24"), "10.7.0.1");
        assert_eq!(gateway(""), "10.7.0.1");
        assert_eq!(normalize_fp("AB:cd:01"), "abcd01");
        assert_eq!(hex(&[0xab, 0x01]), "ab01");
    }
}
