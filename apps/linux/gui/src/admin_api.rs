//! HTTP client for the phantom-server admin API.
//!
//! Used by the Admin screen. Base URL + bearer token come from the active
//! profile (`Profile::admin_url`, `Profile::admin_token`). Usually the URL is
//! `http://10.7.0.1:8080` — only reachable through the VPN tunnel itself, so
//! the Admin screen is useful only while connected.
//!
//! HTTPS with pinning (`admin_server_cert_fp`) is a future hardening; for the
//! MVP we accept invalid certs on https:// URLs (TODO: implement TOFU).

use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::time::Duration;

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
    base_url: String,
    token: String,
    http: reqwest::Client,
}

impl AdminClient {
    pub fn new(base_url: &str, token: &str, _cert_fp: Option<&str>) -> anyhow::Result<Self> {
        let base_url = base_url.trim_end_matches('/').to_string();
        // TODO(TOFU): when cert_fp is set, plug a custom verifier that checks
        // SHA-256 match. For MVP we accept invalid certs on https:// — traffic
        // is loopback-via-tunnel to 10.7.0.1, already authenticated mTLS.
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .danger_accept_invalid_certs(base_url.starts_with("https://"))
            .build()
            .context("reqwest client")?;
        Ok(Self {
            base_url,
            token: token.to_string(),
            http,
        })
    }

    fn url(&self, path: &str) -> String { format!("{}{}", self.base_url, path) }

    pub async fn list_clients(&self) -> anyhow::Result<Vec<ClientEntry>> {
        let resp = self.http.get(self.url("/api/clients"))
            .bearer_auth(&self.token).send().await?;
        let resp = resp.error_for_status()?;
        Ok(resp.json::<Vec<ClientEntry>>().await?)
    }

    pub async fn server_status(&self) -> anyhow::Result<ServerStatus> {
        let resp = self.http.get(self.url("/api/status"))
            .bearer_auth(&self.token).send().await?;
        let resp = resp.error_for_status()?;
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
        let resp = self.http.post(self.url("/api/clients"))
            .bearer_auth(&self.token).json(&req).send().await?;
        resp.error_for_status()?;
        Ok(())
    }

    pub async fn get_conn_string(&self, name: &str) -> anyhow::Result<String> {
        let resp = self.http.get(self.url(&format!("/api/clients/{name}/conn_string")))
            .bearer_auth(&self.token).send().await?;
        let resp = resp.error_for_status()?;
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
        let resp = self.http.delete(self.url(&format!("/api/clients/{name}")))
            .bearer_auth(&self.token).send().await?;
        resp.error_for_status()?;
        Ok(())
    }

    pub async fn toggle_enabled(&self, name: &str, enabled: bool) -> anyhow::Result<()> {
        let path = if enabled {
            format!("/api/clients/{name}/enable")
        } else {
            format!("/api/clients/{name}/disable")
        };
        let resp = self.http.post(self.url(&path))
            .bearer_auth(&self.token).send().await?;
        resp.error_for_status()?;
        Ok(())
    }

    pub async fn extend_subscription(&self, name: &str, days: u32) -> anyhow::Result<()> {
        #[derive(Serialize)]
        struct Req<'a> { action: &'a str, days: u32 }
        let req = Req { action: "extend", days };
        let resp = self.http.post(self.url(&format!("/api/clients/{name}/subscription")))
            .bearer_auth(&self.token).json(&req).send().await?;
        resp.error_for_status()?;
        Ok(())
    }
}
