//! IPv6 kill switch.
//!
//! Our tunnel only carries IPv4. Without this guard, an application can
//! reach the internet over the host's native IPv6 (e.g. SLAAC), leaking
//! around the tunnel.
//!
//! We install three `ip6tables` rules, tagged with a unique `--comment` so
//! we can `-D` them precisely on teardown:
//!
//!   INPUT   : allow ESTABLISHED,RELATED (don't break in-flight replies)
//!   OUTPUT  : REJECT everything with icmp6-adm-prohibited
//!   FORWARD : REJECT (we don't forward, but belt + suspenders)
//!
//! If `ip6tables` is missing the guard is a no-op and logs a warning. Same
//! best-effort contract as the DNS guard.

use std::process::Command;

const COMMENT: &str = "ghoststream-killswitch";

pub struct Ipv6Guard {
    installed: bool,
}

impl Ipv6Guard {
    pub fn activate() -> anyhow::Result<Self> {
        if !ip6tables_present() {
            tracing::warn!(target: "helper",
                "ip6tables not found — IPv6 kill switch disabled (best-effort)");
            return Ok(Self { installed: false });
        }

        // Insert at position 1 so we dominate any existing rules.
        let rules: &[&[&str]] = &[
            &["-I", "INPUT", "1",
              "-m", "state", "--state", "ESTABLISHED,RELATED",
              "-m", "comment", "--comment", COMMENT,
              "-j", "ACCEPT"],
            &["-I", "OUTPUT", "1",
              "-m", "comment", "--comment", COMMENT,
              "-j", "REJECT", "--reject-with", "icmp6-adm-prohibited"],
            &["-I", "FORWARD", "1",
              "-m", "comment", "--comment", COMMENT,
              "-j", "REJECT", "--reject-with", "icmp6-adm-prohibited"],
        ];

        for r in rules {
            let mut cmd = Command::new("ip6tables");
            cmd.args(*r);
            run_or_warn(cmd, "ip6tables insert");
        }

        tracing::info!(target: "helper", "IPv6 kill switch active");
        Ok(Self { installed: true })
    }
}

impl Drop for Ipv6Guard {
    fn drop(&mut self) {
        if !self.installed { return; }
        // Delete-by-comment sweep: list each chain, match our tag, delete by
        // rule spec. Simpler: issue symmetric -D commands.
        let rules: &[&[&str]] = &[
            &["-D", "INPUT",
              "-m", "state", "--state", "ESTABLISHED,RELATED",
              "-m", "comment", "--comment", COMMENT,
              "-j", "ACCEPT"],
            &["-D", "OUTPUT",
              "-m", "comment", "--comment", COMMENT,
              "-j", "REJECT", "--reject-with", "icmp6-adm-prohibited"],
            &["-D", "FORWARD",
              "-m", "comment", "--comment", COMMENT,
              "-j", "REJECT", "--reject-with", "icmp6-adm-prohibited"],
        ];
        for r in rules {
            let mut cmd = Command::new("ip6tables");
            cmd.args(*r);
            // Ignore individual failures — may have been cleared externally.
            let _ = cmd.output();
        }
        tracing::info!(target: "helper", "IPv6 kill switch revoked");
    }
}

fn ip6tables_present() -> bool {
    Command::new("ip6tables")
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
