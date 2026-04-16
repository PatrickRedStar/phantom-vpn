//! User-level GUI settings: `~/.config/ghoststream/settings.json`.
//!
//! These are UI / client-side toggles. Some (dns_leak_protection, ipv6_killswitch,
//! auto_reconnect) are also passed to the helper through `TunnelSettings` at
//! Connect time. Autostart is implemented via systemd user unit.

use anyhow::Context;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::process::Command;

fn default_true() -> bool { true }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserSettings {
    #[serde(default = "default_true")]
    pub dns_leak_protection: bool,
    #[serde(default = "default_true")]
    pub ipv6_killswitch: bool,
    #[serde(default = "default_true")]
    pub auto_reconnect: bool,
    #[serde(default)]
    pub autostart: bool,
    #[serde(default)]
    pub start_minimized: bool,
    /// Hex colour override for accent (reserved — not yet used).
    #[serde(default)]
    pub theme_accent: Option<String>,
}

impl Default for UserSettings {
    fn default() -> Self {
        Self {
            dns_leak_protection: true,
            ipv6_killswitch: true,
            auto_reconnect: true,
            autostart: false,
            start_minimized: false,
            theme_accent: None,
        }
    }
}

impl UserSettings {
    fn config_dir() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("/tmp"))
            .join("ghoststream")
    }

    fn file_path() -> PathBuf {
        Self::config_dir().join("settings.json")
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
}

// ─── systemd --user autostart helpers ────────────────────────────────────────

/// True when `systemctl --user is-enabled ghoststream.service` succeeds.
pub fn systemd_autostart_is_enabled() -> bool {
    match Command::new("systemctl")
        .args(["--user", "is-enabled", "ghoststream.service"])
        .output()
    {
        Ok(out) => out.status.success(),
        Err(_) => false,
    }
}

/// Returns Ok(()) on success. If the unit doesn't exist, returns the stderr.
pub fn systemd_autostart_set(enabled: bool) -> anyhow::Result<()> {
    let verb = if enabled { "enable" } else { "disable" };
    let out = Command::new("systemctl")
        .args(["--user", verb, "ghoststream.service"])
        .output()
        .context("spawn systemctl")?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).trim().to_string();
        anyhow::bail!(
            "systemctl --user {verb} failed: {}",
            if stderr.is_empty() { "unit not installed?".into() } else { stderr }
        );
    }
    Ok(())
}
