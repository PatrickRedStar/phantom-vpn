//! phantom-client-linux: Linux VPN client with QUIC transport.
//! TUN interface via /dev/net/tun + ioctl TUNSETIFF.

#[cfg(target_os = "linux")]
mod linux {
    use std::net::SocketAddr;
    use std::fs::{File, OpenOptions};
    use std::io::{self, Read, Write};
    use std::os::unix::io::AsRawFd;
    use std::path::Path;
    use std::pin::Pin;
    use std::process::Command;
    use std::task::Poll;

    use anyhow::Context;
    use clap::Parser;
    use tokio::io::unix::AsyncFd;
    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf, AsyncReadExt};
    use tokio::sync::mpsc;
    use tokio::signal;

    use client_common::helpers::{self, Args};

    const TUNSETIFF:  libc::c_ulong = 0x400454CA;
    const IFF_TUN:    libc::c_short = 0x0001;
    const IFF_NO_PI:  libc::c_short = 0x1000;

    #[repr(C)]
    struct Ifreq {
        ifr_name:  [libc::c_char; libc::IFNAMSIZ],
        ifr_flags: libc::c_short,
        _pad:      [u8; 22],
    }

// ─── AsyncTun ────────────────────────────────────────────────────────────────

struct AsyncTun { inner: AsyncFd<File> }

impl AsyncTun {
    fn new(file: File) -> io::Result<Self> {
        Ok(Self { inner: AsyncFd::new(file)? })
    }
}

impl AsyncRead for AsyncTun {
    fn poll_read(
        self: Pin<&mut Self>, cx: &mut std::task::Context<'_>, buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        loop {
            let mut guard = match self.inner.poll_read_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            let unfilled = buf.initialize_unfilled();
            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::read(
                        inner.as_raw_fd(),
                        unfilled.as_mut_ptr() as *mut libc::c_void,
                        unfilled.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
            }) {
                Ok(Ok(n))     => { buf.advance(n); return Poll::Ready(Ok(())); }
                Ok(Err(e))    => return Poll::Ready(Err(e)),
                Err(_blocked) => continue,
            }
        }
    }
}

impl AsyncWrite for AsyncTun {
    fn poll_write(
        self: Pin<&mut Self>, cx: &mut std::task::Context<'_>, data: &[u8],
    ) -> Poll<io::Result<usize>> {
        loop {
            let mut guard = match self.inner.poll_write_ready(cx) {
                Poll::Ready(Ok(g))  => g,
                Poll::Ready(Err(e)) => return Poll::Ready(Err(e)),
                Poll::Pending       => return Poll::Pending,
            };
            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.as_raw_fd(),
                        data.as_ptr() as *const libc::c_void,
                        data.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n as usize) }
            }) {
                Ok(result)    => return Poll::Ready(result),
                Err(_blocked) => continue,
            }
        }
    }
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut std::task::Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
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

    let ret = unsafe { libc::ioctl(file.as_raw_fd(), TUNSETIFF, &req as *const _) };
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
    run_cmd("ip", &["link", "set", name, "mtu", &mtu.to_string(), "up"])?;
    tracing::info!("TUN {} up: addr={} mtu={}", name, addr_cidr, mtu);

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
        tracing::info!("PhantomVPN Linux Client starting (QUIC transport)...");

        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();

        // Register signals early
        tokio::spawn(async move {
            let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt()).unwrap();
            let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = sigint.recv() => { tracing::info!("Received SIGINT. Initiating shutdown..."); }
                _ = sigterm.recv() => { tracing::info!("Received SIGTERM. Initiating shutdown..."); }
            }
            let _ = shutdown_tx.send(());
        });

    let cfg = helpers::load_config(&args.config)?;

    let server_addr: SocketAddr = if let Some(ref sa) = args.server {
        sa.parse().context("Invalid --server address")?
    } else {
        cfg.network.server_addr.parse().context("Invalid config server_addr")?
    };
    tracing::info!("Server address: {}", server_addr);

    // ─── QUIC endpoint with SO_MARK ─────────────────────────────────────
    let std_socket = std::net::UdpSocket::bind("0.0.0.0:0")
        .context("Failed to bind UDP socket")?;

    // Set SO_MARK so QUIC traffic bypasses the VPN tunnel
    let mark: u32 = 0x50;
    let ret = unsafe {
        libc::setsockopt(
            std_socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_MARK,
            &mark as *const _ as *const libc::c_void,
            std::mem::size_of::<u32>() as libc::socklen_t,
        )
    };
    if ret != 0 {
        anyhow::bail!("Failed to set SO_MARK: {}", io::Error::last_os_error());
    }
    std_socket.set_nonblocking(true)?;

    // Load mTLS client identity (cert + key) if configured
    let client_identity = if let Some(ref qc) = cfg.quic {
        if let (Some(ref cp), Some(ref kp)) = (&qc.cert_path, &qc.key_path) {
            tracing::info!("Loading client TLS certificate from {}", cp);
            let identity = phantom_core::quic::load_pem_certs(Path::new(cp), Path::new(kp))
                .context("Failed to load client TLS certificate")?;
            Some(identity)
        } else { None }
    } else { None };

    // Load server CA cert if configured (for verifying server cert instead of skip)
    let server_ca = if let Some(ref qc) = cfg.quic {
        if let Some(ref ca_path) = qc.ca_cert_path {
            Some(phantom_core::quic::load_pem_cert_chain(Path::new(ca_path))
                .context("Failed to load server CA cert")?)
        } else { None }
    } else { None };

    let skip_verify = cfg.network.insecure || (server_ca.is_none() && client_identity.is_none());
    let client_config = phantom_core::quic::make_client_config(skip_verify, server_ca, client_identity)
        .context("Failed to build QUIC client config")?;

    let runtime = quinn::default_runtime()
        .ok_or_else(|| anyhow::anyhow!("No async runtime available"))?;
    let mut endpoint = quinn::Endpoint::new(
        quinn::EndpointConfig::default(),
        None,
        std_socket,
        runtime,
    ).context("Failed to create QUIC endpoint")?;
    endpoint.set_default_client_config(client_config);

    tracing::info!("QUIC endpoint created with SO_MARK={:#x}", mark);

    // ─── QUIC connect + open data streams ───────────────────────────────
    let server_name = cfg.network.server_name.as_deref().unwrap_or("phantom");

    let (connection, streams) = client_common::connect_and_handshake(
        &endpoint, server_addr, server_name,
    ).await.context("QUIC connect failed")?;
    tracing::info!("QUIC connected ({} data streams)!", streams.len());

    // ─── TUN interface ───────────────────────────────────────────────────
    let tun_name = cfg.network.tun_name.as_deref().unwrap_or("tun0");
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

    tracing::info!("Creating TUN interface {}...", tun_name);
    let tun_file = create_tun(tun_name, tun_addr, tun_mtu)?;
    let async_tun = AsyncTun::new(tun_file).context("Failed to create async TUN")?;
    let (mut tun_reader, mut tun_writer) = tokio::io::split(async_tun);

    // Default route (with split routing for server IP)
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

    // ─── Channels ────────────────────────────────────────────────────────
    let (tun_pkt_tx, tun_pkt_rx) = mpsc::channel::<Vec<u8>>(4096);
    let (quic_pkt_tx, mut quic_pkt_rx) = mpsc::channel::<Vec<u8>>(4096);

    // ─── TUN writer: decrypted packets → TUN ─────────────────────────────
    tokio::spawn(async move {
        use tokio::io::AsyncWriteExt;
        while let Some(pkt) = quic_pkt_rx.recv().await {
            if let Err(e) = tun_writer.write_all(&pkt).await {
                tracing::error!("TUN write error: {}", e);
            }
        }
    });

    // ─── TUN reader: TUN → channel ───────────────────────────────────────
    tokio::spawn(async move {
        let mut buf = vec![0u8; 65536];
        loop {
            match tun_reader.read(&mut buf).await {
                Ok(0) => continue,
                Ok(n) => {
                    if tun_pkt_tx.send(buf[..n].to_vec()).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    tracing::error!("TUN read error: {}", e);
                    tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
                }
            }
        }
    });

    // ─── Разделяем N data streams на sends и recvs ───────────────────────
    let (sends, recvs): (Vec<_>, Vec<_>) = streams.into_iter().unzip();

    // ─── QUIC stream RX / TX tasks ────────────────────────────────────────
    let mut tunnel_set = tokio::task::JoinSet::new();

    for recv in recvs {
        let pkt_tx = quic_pkt_tx.clone();
        tunnel_set.spawn(async move {
            client_common::quic_stream_rx_loop(recv, pkt_tx).await
        });
    }
    tunnel_set.spawn(async move {
        client_common::quic_stream_tx_loop(tun_pkt_rx, sends).await
    });

    tracing::info!("Tunnel active. Press Ctrl-C to exit.");

    // Exit (triggering RouteCleanup Drop) when shutdown signal arrives
    // OR when any tunnel task dies (connection dropped) — systemd will restart us.
    tokio::select! {
        _ = shutdown_rx => {
            tracing::info!("Shutdown signal received.");
        }
        Some(res) = tunnel_set.join_next() => {
            if let Ok(Err(e)) = res {
                tracing::error!("Tunnel task failed: {}", e);
            }
            tracing::info!("Tunnel died, exiting for restart.");
        }
    }

    // Close QUIC connection gracefully
    connection.close(0u32.into(), b"client shutdown");

    // Manually drop the guard to restore routes before tokio runtime shuts down
    drop(_cleanup_guard);
    tracing::info!("Shutdown complete.");

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
