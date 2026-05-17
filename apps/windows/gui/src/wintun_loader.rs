//! Resolve the location of `wintun.dll` for the running binary.
//!
//! The CI artifact and the eventual installer both place `wintun.dll`
//! next to `ghoststream.exe`. As a last resort we fall back to System32
//! in case the user installed Wintun system-wide (the bundled DLL is
//! always preferred for version stability).

use std::path::PathBuf;

use anyhow::{Context, Result};

pub fn locate_wintun_dll() -> Result<PathBuf> {
    let exe = std::env::current_exe().context("get current_exe path")?;
    let dir = exe
        .parent()
        .context("exe path has no parent directory")?;
    let bundled = dir.join("wintun.dll");
    if bundled.exists() {
        return Ok(bundled);
    }

    #[cfg(windows)]
    {
        let system32 = PathBuf::from(r"C:\Windows\System32\wintun.dll");
        if system32.exists() {
            tracing::warn!(
                "using wintun.dll from System32 ({}); the bundled DLL was not found at {}",
                system32.display(),
                bundled.display()
            );
            return Ok(system32);
        }
    }

    anyhow::bail!(
        "wintun.dll not found. Expected it next to ghoststream.exe at {}",
        bundled.display()
    )
}
