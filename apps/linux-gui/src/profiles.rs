//! Connection-profile storage: `~/.config/ghoststream/profiles.json`.

use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub conn_string: String,
    pub last_connected: Option<i64>,
    /// Cached server addr/sni for display before first connect.
    #[serde(default)]
    pub server_addr: String,
    #[serde(default)]
    pub sni: String,
    #[serde(default)]
    pub tun_addr: String,

    // ─── Admin panel credentials (optional) ───
    /// Base URL of admin API, e.g. "http://10.7.0.1:8080" (reached via tunnel).
    #[serde(default)]
    pub admin_url: Option<String>,
    /// Bearer token for /api/* endpoints.
    #[serde(default)]
    pub admin_token: Option<String>,
    /// SHA-256 fingerprint (hex, colon-separated) of admin listener cert — TOFU pin.
    #[serde(default)]
    pub admin_server_cert_fp: Option<String>,
}

impl Profile {
    pub fn from_conn_string(name: String, conn_string: String) -> anyhow::Result<Self> {
        let cfg = client_common::helpers::parse_conn_string(&conn_string)?;
        Ok(Self {
            id: uuid::Uuid::new_v4().to_string(),
            name,
            conn_string,
            last_connected: None,
            server_addr: cfg.network.server_addr,
            sni: cfg.network.server_name.unwrap_or_default(),
            tun_addr: cfg.network.tun_addr.unwrap_or_default(),
            admin_url: None,
            admin_token: None,
            admin_server_cert_fp: None,
        })
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct Store {
    pub profiles: Vec<Profile>,
    pub active_id: Option<String>,
}

impl Store {
    fn config_dir() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join("ghoststream")
    }

    fn file_path() -> PathBuf {
        Self::config_dir().join("profiles.json")
    }

    pub fn load() -> Self {
        let p = Self::file_path();
        match std::fs::read_to_string(&p) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> anyhow::Result<()> {
        let dir = Self::config_dir();
        std::fs::create_dir_all(&dir).with_context(|| format!("mkdir {}", dir.display()))?;
        let p = Self::file_path();
        let s = serde_json::to_string_pretty(self)?;
        std::fs::write(&p, s).with_context(|| format!("write {}", p.display()))?;
        Ok(())
    }

    pub fn add(&mut self, p: Profile) -> String {
        let id = p.id.clone();
        self.profiles.push(p);
        if self.active_id.is_none() {
            self.active_id = Some(id.clone());
        }
        id
    }

    pub fn remove(&mut self, id: &str) {
        self.profiles.retain(|p| p.id != id);
        if self.active_id.as_deref() == Some(id) {
            self.active_id = self.profiles.first().map(|p| p.id.clone());
        }
    }

    pub fn set_active(&mut self, id: &str) {
        if self.profiles.iter().any(|p| p.id == id) {
            self.active_id = Some(id.to_string());
        }
    }

    pub fn active(&self) -> Option<&Profile> {
        let id = self.active_id.as_deref()?;
        self.profiles.iter().find(|p| p.id == id)
    }

    pub fn update_admin(
        &mut self,
        id: &str,
        admin_url: Option<String>,
        admin_token: Option<String>,
        admin_fp: Option<String>,
    ) {
        if let Some(p) = self.profiles.iter_mut().find(|p| p.id == id) {
            p.admin_url = admin_url.filter(|s| !s.trim().is_empty());
            p.admin_token = admin_token.filter(|s| !s.trim().is_empty());
            p.admin_server_cert_fp = admin_fp.filter(|s| !s.trim().is_empty());
        }
    }
}
