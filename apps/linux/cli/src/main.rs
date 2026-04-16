//! phantom-client-linux: Linux VPN client with raw TLS transport.
//! TUN interface via /dev/net/tun + ioctl TUNSETIFF.

#[cfg(target_os = "linux")]
mod linux {
    use std::fs::{File, OpenOptions};
    use std::io;
    use std::net::SocketAddr;
    use std::os::unix::io::AsRawFd;
    use std::process::Command;

    use anyhow::Context;
    use clap::Parser;
    use tokio::signal;

    use client_common::helpers::{self, Args};
    use client_core_runtime::{ConnectProfile, TunIo, TunnelSettings};

    const TUNSETIFF:  libc::c_ulong = 0x400454CA;
    const IFF_TUN:    libc::c_short = 0x0001;
    const IFF_NO_PI:  libc::c_short = 0x1000;

    #[repr(C)]
    struct Ifreq {
        ifr_name:  [libc::c_char; libc::IFNAMSIZ],
        ifr_flags: libc::c_short,
        _pad:      [u8; 22],
    }

// ─── TUN creation ────────────────────────────────────────────────────────────

fn create_tun(name: &str, addr_cidr: &str, mtu: u32) -> anyhow::Result<File> {
    let file = OpenOptions::new()
        .read(true).write(true)
        .open("/dev/net/tun")
        .context("Failed to open /dev/net/tun — is the tun module loaded?")?;

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
        anyhow::bail!("TUNSETIFF ioctl failed: {} (run as root?)", io::Error::last_os_error());
    }

    // Non-blocking
    unsafe {
        let flags = libc::fcntl(file.as_raw_fd(), libc::F_GETFL, 0);
        libc::fcntl(file.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    // Configure
    run_cmd("ip", &["addr", "add", addr_cidr, "dev", name])?;
    run_cmd("ip", &["link", "set", name,
        "mtu", &mtu.to_string(),
        "txqueuelen", "10000",
        "up"])?;
    tracing::info!("TUN {} up: addr={} mtu={} txqueuelen=10000", name, addr_cidr, mtu);

    Ok(file)
}

const FWMARK: &str = "0x50";
const ROUTE_TABLE: &str = "51820";

pub struct RouteCleanup {
    server_ip: String,
    old_gw: Option<String>,
    old_dev: Option<String>,
    tun_name: String,
    connmark_rules_installed: bool,
}

impl Drop for RouteCleanup {
    fn drop(&mut self) {
        tracing::info!("Cleaning up policy routing rules...");
        let _ = run_cmd("ip", &["rule", "del", "not", "fwmark", FWMARK, "table", ROUTE_TABLE]);
        let _ = run_cmd("ip", &["rule", "del", "table", "main", "suppress_prefixlength", "0"]);
        let _ = run_cmd(
            "ip",
            &["route", "del", "default", "dev", &self.tun_name, "table", ROUTE_TABLE],
        );

        if self.old_gw.is_some() && self.old_dev.is_some() {
            let _ = run_cmd("ip", &["route", "del", &format!("{}/32", self.server_ip)]);
        }
        if self.connmark_rules_installed {
            if let Some(ref dev) = self.old_dev {
                let _ = run_cmd(
                    "iptables",
                    &[
                        "-t", "mangle", "-D", "PREROUTING",
                        "-i", dev,
                        "-j", "CONNMARK", "--set-mark", FWMARK,
                    ],
                );
            }
            let _ = run_cmd(
                "iptables",
                &[
                    "-t", "mangle", "-D", "OUTPUT",
                    "-m", "connmark", "--mark", FWMARK,
                    "-j", "MARK", "--set-mark", FWMARK,
                ],
            );
        }

        // Remove route state file
        let _ = std::fs::remove_file("/run/phantom-vpn-routes.json");
    }
}

fn write_route_state(cleanup: &RouteCleanup) {
    let state = serde_json::json!({
        "server_ip": cleanup.server_ip,
        "old_gw": cleanup.old_gw,
        "old_dev": cleanup.old_dev,
        "tun_name": cleanup.tun_name,
        "connmark_rules_installed": cleanup.connmark_rules_installed,
    });
    if let Err(e) = std::fs::write("/run/phantom-vpn-routes.json", state.to_string()) {
        tracing::warn!("Failed to write route state file: {}", e);
    }
}

fn add_default_route(tun_name: &str, server_addr: &SocketAddr) -> anyhow::Result<RouteCleanup> {
    let server_ip = server_addr.ip().to_string();

    let output = Command::new("ip").args(["route", "show", "default"])
        .output().context("Failed to get default route")?;
    let route_str = String::from_utf8_lossy(&output.stdout);
    let old_gw = route_str.split_whitespace()
        .skip_while(|&w| w != "via")
        .nth(1)
        .map(|s| s.to_string());
    let old_dev = route_str.split_whitespace()
        .skip_while(|&w| w != "dev")
        .nth(1)
        .map(|s| s.to_string());

    if let (Some(ref gw), Some(ref dev)) = (&old_gw, &old_dev) {
        let _ = run_cmd("ip", &["route", "add", &format!("{}/32", server_ip), "via", gw, "dev", dev]);
        tracing::info!("Host route: {} via {} dev {}", server_ip, gw, dev);
    } else {
        tracing::warn!("Could not detect original default gateway — host route for server skipped");
    }

    let mut connmark_rules_installed = false;
    if let Some(ref dev) = old_dev {
        if run_cmd(
            "iptables",
            &["-t", "mangle", "-C", "PREROUTING", "-i", dev,
              "-j", "CONNMARK", "--set-mark", FWMARK],
        ).is_err() {
            run_cmd(
                "iptables",
                &["-t", "mangle", "-I", "PREROUTING", "1", "-i", dev,
                  "-j", "CONNMARK", "--set-mark", FWMARK],
            )?;
        }
        if run_cmd(
            "iptables",
            &["-t", "mangle", "-C", "OUTPUT",
              "-m", "connmark", "--mark", FWMARK,
              "-j", "MARK", "--set-mark", FWMARK],
        ).is_err() {
            run_cmd(
                "iptables",
                &["-t", "mangle", "-I", "OUTPUT", "1",
                  "-m", "connmark", "--mark", FWMARK,
                  "-j", "MARK", "--set-mark", FWMARK],
            )?;
        }
        connmark_rules_installed = true;
    }

    run_cmd("ip", &["route", "add", "default", "dev", tun_name, "table", ROUTE_TABLE])?;
    run_cmd("ip", &["rule", "add", "not", "fwmark", FWMARK, "table", ROUTE_TABLE])?;
    run_cmd("ip", &["rule", "add", "table", "main", "suppress_prefixlength", "0"])?;
    tracing::info!(
        "Policy routing enabled: unmarked traffic -> table {}, marked traffic -> main",
        ROUTE_TABLE
    );

    let cleanup = RouteCleanup {
        server_ip,
        old_gw,
        old_dev,
        tun_name: tun_name.to_string(),
        connmark_rules_installed,
    };

    // Write state file for crash recovery
    write_route_state(&cleanup);

    Ok(cleanup)
}

fn run_cmd(prog: &str, args: &[&str]) -> anyhow::Result<()> {
    let status = Command::new(prog).args(args).status()
        .with_context(|| format!("Failed to exec: {} {}", prog, args.join(" ")))?;
    if !status.success() {
        anyhow::bail!("{} {} exited with {}", prog, args.join(" "), status);
    }
    Ok(())
}

// ─── Main ────────────────────────────────────────────────────────────────────

    #[tokio::main]
    pub async fn async_main() -> anyhow::Result<()> {
        // Явно выбираем ring как TLS-провайдер (rustls 0.23 требует этого при наличии нескольких провайдеров)
        rustls::crypto::ring::default_provider()
            .install_default()
            .expect("Failed to install ring crypto provider");

        let args = Args::parse();
        helpers::init_logging(args.verbose);
        tracing::info!("PhantomVPN Linux Client starting...");

        // Load config: --conn-string overrides TOML config file
        let cfg = if let Some(cs_cfg) = helpers::load_conn_string(&args)? {
            tracing::info!("Config loaded from connection string");
            cs_cfg
        } else {
            helpers::load_config(&args.config)?
        };

        let raw_addr = if let Some(ref sa) = args.server {
            sa.clone()
        } else {
            cfg.network.server_addr.clone()
        };
        let raw_addr = client_common::with_default_port(&raw_addr, 443);
        let server_addr: SocketAddr = if let Ok(addr) = raw_addr.parse() {
            addr
        } else {
            tracing::info!("Resolving DNS for {}", raw_addr);
            tokio::net::lookup_host(&raw_addr).await
                .context("DNS lookup failed")?
                .next()
                .ok_or_else(|| anyhow::anyhow!("No DNS results for {}", raw_addr))?
        };
        tracing::info!("Server address: {}", server_addr);

        let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
        let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
        let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

        tracing::info!("Creating TUN interface {}...", tun_name);
        let tun_file = create_tun(tun_name, tun_addr, tun_mtu)?;
        let tun_fd = tun_file.as_raw_fd();
        std::mem::forget(tun_file);

        // Default route
        let _cleanup_guard = if cfg.network.default_gw.is_some() {
            match add_default_route(tun_name, &server_addr) {
                Ok(guard) => Some(guard),
                Err(e) => {
                    tracing::warn!("Route setup failed: {}", e);
                    None
                }
            }
        } else {
            None
        };

        // Build ConnectProfile from the parsed ClientConfig.
        // Reconstruct conn_string from args (it was already loaded from args/file).
        let conn_string = if let Some(ref cs) = args.conn_string {
            cs.clone()
        } else if let Some(ref csf) = args.conn_string_file {
            std::fs::read_to_string(csf)
                .context("read conn_string_file")?
                .trim()
                .to_string()
        } else {
            // Config was loaded from TOML — reconstruct a minimal conn_string or
            // pass the raw server_addr. Since parse_conn_string is required by the
            // runtime, build a ghs:// URL here if possible. For TOML configs that
            // pre-date conn_string, fall back to passing cfg directly via a
            // helper that builds the profile from ClientConfig fields.
            anyhow::bail!(
                "TOML-file configs are not yet supported with client-core-runtime; \
                 use --conn-string or --conn-string-file"
            )
        };

        let settings = TunnelSettings {
            auto_reconnect: false, // CLI: single attempt, user retries manually
            ..TunnelSettings::default()
        };

        let profile = ConnectProfile {
            name: "cli".to_string(),
            conn_string,
            settings,
        };

        let (status_tx, _status_rx) = tokio::sync::watch::channel(
            client_core_runtime::StatusFrame::default()
        );
        let (log_tx, _log_rx) = tokio::sync::mpsc::channel(256);

        tracing::info!("Starting tunnel via client-core-runtime...");
        let (handles, join_handle) = client_core_runtime::run(
            profile,
            TunIo::Uring(tun_fd),
            status_tx,
            log_tx,
        ).await.context("client_core_runtime::run")?;

        // Wait for SIGINT/SIGTERM to cancel, or for the tunnel to die.
        let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt()).unwrap();
        let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate()).unwrap();
        tokio::pin!(join_handle);
        tokio::select! {
            _ = sigint.recv() => {
                tracing::info!("Received SIGINT. Initiating shutdown...");
                handles.cancel.notify_waiters();
                let _ = join_handle.await;
            }
            _ = sigterm.recv() => {
                tracing::info!("Received SIGTERM. Initiating shutdown...");
                handles.cancel.notify_waiters();
                let _ = join_handle.await;
            }
            res = &mut join_handle => {
                tracing::warn!("Tunnel exited: {:?}", res);
            }
        }

        drop(_cleanup_guard);
        tracing::info!("Client shutdown complete.");
        Ok(())
    }

}

#[cfg(target_os = "linux")]
fn main() -> anyhow::Result<()> {
    linux::async_main()
}

#[cfg(not(target_os = "linux"))]
fn main() {
    println!("PhantomVPN Linux Client can only be run on Linux.");
}
