//! Spawn the privileged helper via pkexec.
//!
//! We try, in order:
//!   1. `/usr/bin/ghoststream-helper`       (packaged install)
//!   2. `../target/release/ghoststream-helper` relative to the GUI binary
//!      (development / unpackaged use)
//!   3. `$GHOSTSTREAM_HELPER` env override
//!
//! pkexec preserves `PKEXEC_UID` (the launching user's UID) — the helper
//! uses that to locate `$XDG_RUNTIME_DIR/<uid>`.

use std::path::PathBuf;
use std::process::Stdio;
use tokio::process::Command;

pub fn resolve_helper_path() -> Option<PathBuf> {
    if let Ok(over) = std::env::var("GHOSTSTREAM_HELPER") {
        let p = PathBuf::from(over);
        if p.exists() { return Some(p); }
    }
    let prod = PathBuf::from("/usr/bin/ghoststream-helper");
    if prod.exists() { return Some(prod); }
    if let Ok(self_exe) = std::env::current_exe() {
        if let Some(dir) = self_exe.parent() {
            let dev = dir.join("ghoststream-helper");
            if dev.exists() { return Some(dev); }
        }
    }
    None
}

/// Spawn helper in background. pkexec will pop an auth dialog, then fork the
/// helper. This function returns once pkexec has forked (the helper is a
/// long-running daemon that outlives this call).
///
/// Returns the child handle so the caller can keep it (dropping it does NOT
/// kill the helper — pkexec already detached by then).
pub fn spawn_via_pkexec() -> anyhow::Result<tokio::process::Child> {
    let helper = resolve_helper_path()
        .ok_or_else(|| anyhow::anyhow!(
            "ghoststream-helper not found. Install the package, or build via \
             `cargo build --release -p ghoststream-helper` and point \
             $GHOSTSTREAM_HELPER at it."))?;

    tracing::info!(path = %helper.display(), "launching helper via pkexec");

    let child = Command::new("pkexec")
        .arg(helper.as_os_str())
        // Leave stdio inherited — pkexec needs a tty or gui auth agent.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()?;
    Ok(child)
}
