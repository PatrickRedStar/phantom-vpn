//! ghoststream-helper — privileged tunnel daemon for `ghoststream-gui`.
//!
//! Launch model: GUI invokes `pkexec /usr/bin/ghoststream-helper` when it
//! can't find the socket. Helper runs as root (EUID=0), bound to the user
//! who triggered pkexec via `PKEXEC_UID`.
//!
//! The helper owns:
//!   * the unix socket at `/run/user/<uid>/ghoststream.sock`
//!   * the TUN interface (created via /dev/net/tun ioctl)
//!   * default route / policy routing rules
//!   * tokio runtime driving the TLS tunnel (via client_common)
//!
//! It accepts exactly one GUI connection at a time. If a second connection
//! arrives while the first is still active, we drop the old one (user
//! restarted their GUI).

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("ghoststream-helper is Linux-only.");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux;

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::run()
}
