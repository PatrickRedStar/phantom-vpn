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
    use tokio::sync::watch;

    use bytes::Bytes;
    use client_common::helpers::{self, Args};
    use client_common::{tls_connect, tls_rx_loop, tls_tx_loop, write_handshake};
    use phantom_core::config::ClientConfig;
    use phantom_core::wire::{flow_stream_idx, n_data_streams};
    use rustls::pki_types::{CertificateDer, PrivateKeyDer};

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TunnelExit {
    Shutdown,
    TunnelDied,
}

fn resolve_transport(args: &Args, cfg: &ClientConfig) -> anyhow::Result<String> {
    if let Some(transport) = args.transport.as_deref() {
        return helpers::normalize_transport(transport);
    }
    if let Some(transport) = cfg.transport.as_deref() {
        return helpers::normalize_transport(transport);
    }
    Ok("h2".to_string())
}

async fn wait_for_shutdown(shutdown_rx: &mut watch::Receiver<bool>) {
    if *shutdown_rx.borrow() {
        return;
    }
    let _ = shutdown_rx.changed().await;
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

        let (shutdown_tx, shutdown_rx) = watch::channel(false);

        // Register signals early
        tokio::spawn(async move {
            let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt()).unwrap();
            let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = sigint.recv() => { tracing::info!("Received SIGINT. Initiating shutdown..."); }
                _ = sigterm.recv() => { tracing::info!("Received SIGTERM. Initiating shutdown..."); }
            }
            let _ = shutdown_tx.send(true);
        });

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
    // Defensive: tolerate bare hostnames in server_addr (user-editable in
    // UI / conn string). `lookup_host` rejects them as "invalid socket
    // address". See client_common::with_default_port.
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

    // Load mTLS client identity (cert + key) — inline PEM or file path
    let client_identity = helpers::load_tls_identity(&cfg)?;

    // Load server CA cert — inline PEM or file path
    let server_ca = helpers::load_server_ca(&cfg)?;

    let skip_verify = cfg.network.insecure;
    if !skip_verify && server_ca.is_none() {
        anyhow::bail!("No CA certificate provided and insecure=false. Set insecure=true or provide ca_cert_path.");
    }

    // Resolve transport: CLI override > config/conn string > default h2
    let transport = resolve_transport(&args, &cfg)?;
    tracing::info!("Using transport: {}", transport);

    let exit = run_tls_tunnel(cfg, server_addr, skip_verify, server_ca, client_identity, shutdown_rx).await?;

    match exit {
        TunnelExit::Shutdown => tracing::info!("Client shutdown complete."),
        TunnelExit::TunnelDied => tracing::warn!("Tunnel exited without shutdown signal."),
    }

    Ok(())
}

/// Raw TLS tunnel implementation
async fn run_tls_tunnel(
    cfg: ClientConfig,
    server_addr: SocketAddr,
    skip_verify: bool,
    server_ca: Option<Vec<CertificateDer<'static>>>,
    client_identity: Option<(Vec<CertificateDer<'static>>, PrivateKeyDer<'static>)>,
    mut shutdown_rx: watch::Receiver<bool>,
) -> anyhow::Result<TunnelExit> {
    if *shutdown_rx.borrow() {
        return Ok(TunnelExit::Shutdown);
    }

    let client_config = phantom_core::h2_transport::make_h2_client_tls(skip_verify, server_ca, client_identity)
        .context("Failed to build TLS client config")?;
    let n_streams = n_data_streams();

    let server_name = cfg.network.server_name.as_deref().unwrap_or("phantom").to_string();

    // Open N parallel TLS streams; each sends a 2-byte handshake [stream_idx, max_streams].
    let mut tls_writers = Vec::with_capacity(n_streams);
    let mut tls_readers = Vec::with_capacity(n_streams);
    for idx in 0..n_streams {
        let (r, mut w) = tls_connect(server_addr, server_name.clone(), client_config.clone())
            .await
            .with_context(|| format!("stream {}: TLS connect failed", idx))?;
        write_handshake(&mut w, idx as u8, n_streams as u8)
            .await
            .with_context(|| format!("stream {}: write_handshake failed", idx))?;
        tracing::info!("Stream {}: connected", idx);
        tls_readers.push(r);
        tls_writers.push(w);
    }

    tracing::info!("All {} TLS streams up", n_streams);

    // ─── TUN interface ───────────────────────────────────────────────────
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

    // ─── io_uring TUN I/O ────────────────────────────────────────────────
    // tun_uring speaks `Bytes`, so we pipe straight through with no copies.
    let (mut tun_pkt_rx, tun_pkt_tx) =
        phantom_core::tun_uring::spawn(tun_fd, 4096)
            .context("Failed to start io_uring TUN handler")?;
    tracing::info!("io_uring TUN handler started");

    // Per-stream TX channels.
    let mut tx_senders: Vec<tokio::sync::mpsc::Sender<Bytes>> = Vec::with_capacity(n_streams);
    let mut tx_receivers: Vec<tokio::sync::mpsc::Receiver<Bytes>> = Vec::with_capacity(n_streams);
    for _ in 0..n_streams {
        let (tx, rx) = tokio::sync::mpsc::channel::<Bytes>(2048);
        tx_senders.push(tx);
        tx_receivers.push(rx);
    }

    // Single sink for RX: all N rx loops push Bytes here; a forwarder task
    // converts them back to Vec<u8> for the io_uring TUN writer.
    let (rx_sink_tx, mut rx_sink_rx) = tokio::sync::mpsc::channel::<Bytes>(4096);

    // Dispatcher: tun_uring reader → per-stream channel via flow hash.
    //
    // IMPORTANT: `try_send` — not `send().await`. Per-stream pinning means a
    // single slow TLS stream would cross-stall every flow (HoL blocking across
    // independent streams). Matches server's `tun_dispatch_loop` — drop-on-full
    // and let TCP retransmit sort the slow stream out.
    let tx_senders_clone = tx_senders.clone();
    let n_streams_dispatch = n_streams;
    tokio::spawn(async move {
        let mut drop_full: u64 = 0;
        let mut drop_closed: u64 = 0;
        while let Some(pkt) = tun_pkt_rx.recv().await {
            let idx = flow_stream_idx(&pkt, n_streams_dispatch);
            match tx_senders_clone[idx].try_send(pkt) {
                Ok(()) => {}
                Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {
                    drop_full += 1;
                    if drop_full == 1 || drop_full % 1024 == 0 {
                        tracing::warn!(
                            "dispatcher: stream {} full (dropped_full={})",
                            idx, drop_full
                        );
                    }
                }
                Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => {
                    drop_closed += 1;
                    tracing::warn!(
                        "dispatcher: stream {} closed (dropped_closed={}), exiting",
                        idx, drop_closed
                    );
                    return;
                }
            }
        }
    });
    drop(tx_senders);

    // RX forwarder: Bytes sink → tun_uring writer.
    let tun_write_tx = tun_pkt_tx.clone();
    tokio::spawn(async move {
        while let Some(pkt) = rx_sink_rx.recv().await {
            if tun_write_tx.send(pkt).await.is_err() {
                return;
            }
        }
    });
    drop(tun_pkt_tx);

    // N TX + N RX tasks.
    let mut tx_handles = Vec::with_capacity(n_streams);
    let mut rx_handles = Vec::with_capacity(n_streams);
    for (idx, (w, rxc)) in tls_writers.into_iter().zip(tx_receivers.into_iter()).enumerate() {
        tx_handles.push(tokio::spawn(async move {
            let res = tls_tx_loop(w, rxc).await;
            tracing::warn!("stream {}: tx loop ended: {:?}", idx, res);
            res
        }));
    }
    for (idx, r) in tls_readers.into_iter().enumerate() {
        let sink = rx_sink_tx.clone();
        rx_handles.push(tokio::spawn(async move {
            let res = tls_rx_loop(r, sink).await;
            tracing::warn!("stream {}: rx loop ended: {:?}", idx, res);
            res
        }));
    }
    drop(rx_sink_tx);

    tracing::info!("Tunnel active. Press Ctrl-C to exit.");

    tokio::select! {
        _ = wait_for_shutdown(&mut shutdown_rx) => {
            tracing::info!("Shutdown signal received.");
            for h in tx_handles { h.abort(); }
            for h in rx_handles { h.abort(); }
            drop(_cleanup_guard);
            return Ok(TunnelExit::Shutdown);
        }
        _ = async {
            for h in &mut tx_handles { let _ = h.await; }
        } => {
            tracing::warn!("All TX loops exited.");
        }
        _ = async {
            for h in &mut rx_handles { let _ = h.await; }
        } => {
            tracing::warn!("All RX loops exited.");
        }
    }

    drop(_cleanup_guard);
    tracing::info!("Tunnel died, exiting for restart.");

    Ok(TunnelExit::TunnelDied)
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
