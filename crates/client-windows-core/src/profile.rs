//! Connection profile persistence.
//!
//! On Windows the file lands in `%APPDATA%\GhostStream\config\profile.json`;
//! on Linux/macOS hosts (used for headless tests and dev) the same code
//! follows the platform's XDG / `Application Support` convention via the
//! `directories` crate.

use std::path::PathBuf;

use anyhow::{Context, Result};
use ghoststream_gui_ipc::ConnectProfile;

const QUALIFIER: &str = "com";
const ORG: &str = "ghoststream";
const APP: &str = "GhostStream";

pub fn profile_path() -> Result<PathBuf> {
    let proj = directories::ProjectDirs::from(QUALIFIER, ORG, APP)
        .context("could not determine ProjectDirs for GhostStream")?;
    let dir = proj.config_dir();
    if let Err(e) = std::fs::create_dir_all(dir) {
        if e.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(e).with_context(|| format!("create {}", dir.display()));
        }
    }
    Ok(dir.join("profile.json"))
}

pub fn save(profile: &ConnectProfile) -> Result<()> {
    let path = profile_path()?;
    let json = serde_json::to_string_pretty(profile)?;
    std::fs::write(&path, json).with_context(|| format!("write {}", path.display()))?;
    Ok(())
}

pub fn load() -> Result<Option<ConnectProfile>> {
    let path = profile_path()?;
    if !path.exists() {
        return Ok(None);
    }
    let txt = std::fs::read_to_string(&path)
        .with_context(|| format!("read {}", path.display()))?;
    let profile: ConnectProfile = serde_json::from_str(&txt)
        .with_context(|| format!("parse {}", path.display()))?;
    Ok(Some(profile))
}
