//! TUN creation + policy routing (extracted from crates/client-linux/main.rs).
//!
//! The helper calls `create_tun()` to open a TUN fd, then hands the fd into
//! `phantom_core::tun_uring::spawn` for I/O. `RouteGuard` reverts rules on
//! Drop — we `drop(guard)` when the tunnel tears down.

use anyhow::Context;
use std::fs::{File, OpenOptions};
use std::io;
use std::net::SocketAddr;
use std::os::unix::io::AsRawFd;
use std::process::{Command, Stdio};

/// Best-effort subprocess: suppress stdout+stderr, ignore exit status.
/// Used in teardown paths where "resource doesn't exist" is expected noise.
fn run_quiet(prog: &str, args: &[&str]) {
    let _ = Command::new(prog).args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

const TUNSETIFF: libc::c_ulong = 0x400454CA;
const IFF_TUN:   libc::c_short = 0x0001;
const IFF_NO_PI: libc::c_short = 0x1000;

#[repr(C)]
struct Ifreq {
    ifr_name:  [libc::c_char; libc::IFNAMSIZ],
    ifr_flags: libc::c_short,
    _pad:      [u8; 22],
}

const FWMARK: &str = "0x50";
const ROUTE_TABLE: &str = "51820";

pub struct RouteGuard {
    server_ip: String,
    old_gw: Option<String>,
    old_dev: Option<String>,
    tun_name: String,
    connmark_rules_installed: bool,
}

impl Drop for RouteGuard {
    fn drop(&mut self) {
        tracing::info!("Reverting policy routing rules");
        // All best-effort: quiet to avoid noisy stderr when the rule is
        // already gone (crash, double-drop, partial setup, etc.).
        run_quiet("ip", &["rule", "del", "not", "fwmark", FWMARK, "table", ROUTE_TABLE]);
        run_quiet("ip", &["rule", "del", "table", "main", "suppress_prefixlength", "0"]);
        run_quiet("ip", &["route", "del", "default", "dev", &self.tun_name, "table", ROUTE_TABLE]);
        if self.old_gw.is_some() && self.old_dev.is_some() {
            run_quiet("ip", &["route", "del", &format!("{}/32", self.server_ip)]);
        }
        if self.connmark_rules_installed {
            if let Some(ref dev) = self.old_dev {
                run_quiet(
                    "iptables",
                    &["-t", "mangle", "-D", "PREROUTING", "-i", dev,
                      "-j", "CONNMARK", "--set-mark", FWMARK],
                );
            }
            run_quiet(
                "iptables",
                &["-t", "mangle", "-D", "OUTPUT",
                  "-m", "connmark", "--mark", FWMARK,
                  "-j", "MARK", "--set-mark", FWMARK],
            );
        }
    }
}

/// RAII wrapper: owns TUN File + ensures `ip link del <name>` on drop.
/// Closing the File alone is not enough — kernel keeps the device until
/// the last fd closes *and* no userspace referers. Explicit `ip link del`
/// guarantees clean teardown so a reconnect won't fail with "File exists"
/// on `ip addr add`.
pub struct TunDevice {
    pub file: File,
    pub name: String,
}

impl Drop for TunDevice {
    fn drop(&mut self) {
        tracing::info!("Removing TUN device {}", self.name);
        // Best-effort; `ip link del` fails harmlessly if device is gone.
        run_quiet("ip", &["link", "del", &self.name]);
    }
}

pub fn create_tun(name: &str, addr_cidr: &str, mtu: u32) -> anyhow::Result<TunDevice> {
    // Clean up any orphan TUN device from a previous unclean teardown.
    // `ip link del` returns non-zero if device doesn't exist — ignore (quiet).
    run_quiet("ip", &["link", "del", name]);

    let file = OpenOptions::new()
        .read(true).write(true)
        .open("/dev/net/tun")
        .context("open /dev/net/tun (tun module loaded?)")?;

    let mut req = Ifreq {
        ifr_name:  [0; libc::IFNAMSIZ],
        ifr_flags: IFF_TUN | IFF_NO_PI,
        _pad:      [0; 22],
    };
    let name_bytes = name.as_bytes();
    let copy_len = name_bytes.len().min(libc::IFNAMSIZ - 1);
    for (i, &b) in name_bytes[..copy_len].iter().enumerate() {
        req.ifr_name[i] = b as libc::c_char;
    }

    #[allow(clippy::unnecessary_cast)]
    let ret = unsafe { libc::ioctl(file.as_raw_fd(), TUNSETIFF as _, &req as *const _) };
    if ret < 0 {
        anyhow::bail!("TUNSETIFF ioctl: {}", io::Error::last_os_error());
    }
    unsafe {
        let flags = libc::fcntl(file.as_raw_fd(), libc::F_GETFL, 0);
        libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    run("ip", &["addr", "add", addr_cidr, "dev", name])?;
    run("ip", &["link", "set", name,
        "mtu", &mtu.to_string(),
        "txqueuelen", "10000",
        "up"])?;
    tracing::info!("TUN {} up addr={} mtu={}", name, addr_cidr, mtu);
    Ok(TunDevice { file, name: name.to_string() })
}

pub fn add_default_route(tun_name: &str, server_addr: &SocketAddr) -> anyhow::Result<RouteGuard> {
    let server_ip = server_addr.ip().to_string();

    let output = Command::new("ip").args(["route", "show", "default"]).output()
        .context("ip route show default")?;
    let route_str = String::from_utf8_lossy(&output.stdout);
    let old_gw = route_str.split_whitespace()
        .skip_while(|&w| w != "via").nth(1).map(|s| s.to_string());
    let old_dev = route_str.split_whitespace()
        .skip_while(|&w| w != "dev").nth(1).map(|s| s.to_string());

    if let (Some(ref gw), Some(ref dev)) = (&old_gw, &old_dev) {
        let _ = run("ip", &["route", "add", &format!("{}/32", server_ip), "via", gw, "dev", dev]);
    } else {
        tracing::warn!("no default gateway detected; host route skipped");
    }

    let mut connmark_rules_installed = false;
    if let Some(ref dev) = old_dev {
        // `-C` probes print "Bad rule" to stderr when the rule is absent.
        // Use quiet variant so those expected misses don't leak to the GUI's
        // terminal. Insert still uses loud `run` — real errors must surface.
        if !probe_quiet("iptables", &["-t", "mangle", "-C", "PREROUTING",
              "-i", dev, "-j", "CONNMARK", "--set-mark", FWMARK]) {
            run("iptables", &["-t", "mangle", "-I", "PREROUTING", "1",
                "-i", dev, "-j", "CONNMARK", "--set-mark", FWMARK])?;
        }
        if !probe_quiet("iptables", &["-t", "mangle", "-C", "OUTPUT",
              "-m", "connmark", "--mark", FWMARK,
              "-j", "MARK", "--set-mark", FWMARK]) {
            run("iptables", &["-t", "mangle", "-I", "OUTPUT", "1",
                "-m", "connmark", "--mark", FWMARK,
                "-j", "MARK", "--set-mark", FWMARK])?;
        }
        connmark_rules_installed = true;
    }

    run("ip", &["route", "add", "default", "dev", tun_name, "table", ROUTE_TABLE])?;
    run("ip", &["rule", "add", "not", "fwmark", FWMARK, "table", ROUTE_TABLE])?;
    run("ip", &["rule", "add", "table", "main", "suppress_prefixlength", "0"])?;
    tracing::info!("Policy routing installed (table {})", ROUTE_TABLE);

    Ok(RouteGuard {
        server_ip,
        old_gw,
        old_dev,
        tun_name: tun_name.to_string(),
        connmark_rules_installed,
    })
}

/// Silent probe: run a command with stdout+stderr suppressed, return whether
/// it succeeded. Used for `iptables -C` existence checks where a negative
/// result is normal and must not pollute the GUI terminal.
fn probe_quiet(prog: &str, args: &[&str]) -> bool {
    Command::new(prog).args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn run(prog: &str, args: &[&str]) -> anyhow::Result<()> {
    let status = Command::new(prog).args(args).status()
        .with_context(|| format!("exec {} {}", prog, args.join(" ")))?;
    if !status.success() {
        anyhow::bail!("{} {} exit {}", prog, args.join(" "), status);
    }
    Ok(())
}
