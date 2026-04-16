//! Unix socket bind + chown helper.

use anyhow::Context;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use tokio::net::UnixListener;

pub fn bind(path: &Path, uid: u32, gid: u32) -> anyhow::Result<UnixListener> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
        // Ensure parent is owned by target user (it usually is for /run/user/<uid>).
    }
    // Remove any stale socket.
    let _ = std::fs::remove_file(path);

    let listener = UnixListener::bind(path)
        .with_context(|| format!("bind unix socket {}", path.display()))?;

    // chown + 0600 so only the target user can speak to us.
    nix::unistd::chown(
        path,
        Some(nix::unistd::Uid::from_raw(uid)),
        Some(nix::unistd::Gid::from_raw(gid)),
    ).context("chown socket")?;

    let mut perms = std::fs::metadata(path)?.permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(path, perms).context("chmod socket")?;

    Ok(listener)
}
