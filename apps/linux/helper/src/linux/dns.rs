//! DNS leak protection via systemd-resolved.
//!
//! When the tunnel comes up, we pin the TUN interface's DNS servers + a
//! catch-all routing domain (`~.`) so that **all** DNS queries resolve
//! through the VPN's upstream (typically 10.7.0.1). On teardown, we revert
//! the interface to its defaults.
//!
//! Implementation: shells out to `resolvectl`. D-Bus (`org.freedesktop.
//! resolve1`) would be equivalent but pulls in zbus and more dependencies;
//! the CLI tool is guaranteed-present on any systemd-resolved system.
//!
//! If `resolvectl` is missing (Alpine, Void, Gentoo-without-systemd, etc.)
//! we log a warning and become a no-op. DNS leak protection is best-effort.

use std::net::IpAddr;
use std::process::Command;

/// RAII guard. Activates DNS pinning on construction; reverts on Drop.
pub struct DnsGuard {
    iface: String,
    active: bool,
}

impl DnsGuard {
    /// Pin `dns_servers` + catch-all routing domain on `iface`.
    /// `search_domains` is appended as extra routing domains.
    ///
    /// Returns `Ok(guard)` even when `resolvectl` is missing — the guard is
    /// just inert in that case.
    pub fn activate(
        iface: &str,
        dns_servers: &[IpAddr],
        search_domains: &[&str],
    ) -> anyhow::Result<Self> {
        if !resolvectl_present() {
            tracing::warn!(target: "helper",
                "resolvectl not found — DNS leak protection disabled (best-effort)");
            return Ok(Self { iface: iface.to_string(), active: false });
        }

        if dns_servers.is_empty() {
            tracing::warn!(target: "helper",
                "no DNS servers supplied — skipping DNS guard");
            return Ok(Self { iface: iface.to_string(), active: false });
        }

        // resolvectl dns <iface> <ip1> <ip2> ...
        let mut cmd = Command::new("resolvectl");
        cmd.arg("dns").arg(iface);
        for ip in dns_servers {
            cmd.arg(ip.to_string());
        }
        run_or_warn(cmd, "resolvectl dns");

        // resolvectl domain <iface> ~. [extras...]
        // "~." = routing-only catch-all. Queries for anything not matching a
        // more specific domain go through this interface.
        let mut cmd = Command::new("resolvectl");
        cmd.arg("domain").arg(iface).arg("~.");
        for d in search_domains {
            cmd.arg(d);
        }
        run_or_warn(cmd, "resolvectl domain");

        // Pin default-route flag — without this some queries still leak to
        // whichever link resolved first at boot.
        let mut cmd = Command::new("resolvectl");
        cmd.arg("default-route").arg(iface).arg("yes");
        run_or_warn(cmd, "resolvectl default-route");

        tracing::info!(target: "helper",
            iface = iface,
            dns = ?dns_servers,
            "DNS guard active — catch-all routing via tunnel");

        Ok(Self { iface: iface.to_string(), active: true })
    }
}

impl Drop for DnsGuard {
    fn drop(&mut self) {
        if !self.active { return; }
        let mut cmd = Command::new("resolvectl");
        cmd.arg("revert").arg(&self.iface);
        run_or_warn(cmd, "resolvectl revert");
        tracing::info!(target: "helper", iface = %self.iface, "DNS guard reverted");
    }
}

fn resolvectl_present() -> bool {
    Command::new("resolvectl")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run_or_warn(mut cmd: Command, label: &str) {
    let repr = format!("{:?}", cmd);
    match cmd.output() {
        Ok(o) if o.status.success() => {}
        Ok(o) => {
            let err = String::from_utf8_lossy(&o.stderr);
            tracing::warn!(target: "helper", cmd = %repr,
                "{} failed: {}", label, err.trim());
        }
        Err(e) => {
            tracing::warn!(target: "helper", cmd = %repr,
                "{} spawn failed: {}", label, e);
        }
    }
}
