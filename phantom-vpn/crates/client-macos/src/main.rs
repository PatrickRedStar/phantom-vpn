//! phantom-client-macos: macOS VPN client with QUIC transport.
//! Uses macOS `utun` via AF_SYSTEM sockets.

#[cfg(target_os = "macos")]
mod macos {
    use std::net::SocketAddr;
    use std::sync::Arc;
    use std::io;
    use std::os::unix::io::{AsRawFd, FromRawFd, RawFd};
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

    const AF_SYSTEM: libc::c_int = 32;
    const SYSPROTO_CONTROL: libc::c_int = 2;
    const UTUN_CONTROL_NAME: &[u8] = b"com.apple.net.utun_control\0";
    const UTUN_OPT_IFNAME: libc::c_int = 2;

    const CTLIOCGINFO: libc::c_ulong = 0xc0644e03;

#[repr(C)]
struct ctl_info {
    ctl_id: u32,
    ctl_name: [libc::c_char; 96],
}

#[repr(C)]
struct sockaddr_ctl {
    sc_len: libc::c_uchar,
    sc_family: libc::c_uchar,
    ss_sysaddr: u16,
    sc_id: u32,
    sc_unit: u32,
    sc_reserved: [u32; 5],
}

// ─── AsyncTun macOS ──────────────────────────────────────────────────────────

struct AsyncTun {
    inner: AsyncFd<std::fs::File>,
}

impl AsyncTun {
    fn new(fd: RawFd) -> io::Result<Self> {
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
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

            let mut temp_buf = vec![0u8; buf.remaining() + 4];

            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::read(
                        inner.as_raw_fd(),
                        temp_buf.as_mut_ptr() as *mut libc::c_void,
                        temp_buf.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n) }
            }) {
                Ok(Ok(n)) => {
                    if n >= 4 {
                        buf.put_slice(&temp_buf[4..n as usize]);
                    }
                    return Poll::Ready(Ok(()));
                }
                Ok(Err(e)) => return Poll::Ready(Err(e)),
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

            let mut write_buf = Vec::with_capacity(data.len() + 4);
            write_buf.extend_from_slice(&[0, 0, 0, 2]); // AF_INET
            write_buf.extend_from_slice(data);

            match guard.try_io(|inner| {
                let n = unsafe {
                    libc::write(
                        inner.as_raw_fd(),
                        write_buf.as_ptr() as *const libc::c_void,
                        write_buf.len(),
                    )
                };
                if n < 0 { Err(io::Error::last_os_error()) } else { Ok(n) }
            }) {
                Ok(Ok(n)) => {
                    let written_user_bytes = if n >= 4 { (n as usize) - 4 } else { 0 };
                    return Poll::Ready(Ok(written_user_bytes));
                }
                Ok(Err(e))    => return Poll::Ready(Err(e)),
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

// ─── Control Commands ────────────────────────────────────────────────────────

fn run_cmd(prog: &str, args: &[&str]) -> anyhow::Result<()> {
    let status = Command::new(prog).args(args).status()
        .with_context(|| format!("Failed to exec: {} {}", prog, args.join(" ")))?;
    if !status.success() {
        anyhow::bail!("{} {} exited with {}", prog, args.join(" "), status);
    }
    Ok(())
}

pub struct RouteCleanup {
    server_ip: String,
    old_gw: Option<String>,
    old_dev: Option<String>,
    tun_name: String,
}

impl Drop for RouteCleanup {
    fn drop(&mut self) {
        tracing::info!("Restoring original routes...");
        let _ = run_cmd("route", &["delete", "-net", "0.0.0.0/1", "-interface", &self.tun_name]);
        let _ = run_cmd("route", &["delete", "-net", "128.0.0.0/1", "-interface", &self.tun_name]);
        let _ = run_cmd("route", &["delete", "-host", &self.server_ip]);

        if let (Some(ref gw), Some(ref dev)) = (&self.old_gw, &self.old_dev) {
            tracing::info!("Restored default route via {} dev {}", gw, dev);
        } else {
            tracing::warn!("No original gateway collected. Original default route may be unchanged.");
        }
    }
}

fn add_default_route(tun_name: &str, server_addr: &SocketAddr) -> anyhow::Result<RouteCleanup> {
    let server_ip = server_addr.ip().to_string();

    let output = Command::new("route").args(&["-n", "get", "default"])
        .output().context("Failed to get default route")?;
    let route_str = String::from_utf8_lossy(&output.stdout);

    let mut old_gw = None;
    let mut old_dev = None;

    for line in route_str.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("gateway:") {
            old_gw = trimmed.split_whitespace().nth(1).map(|s| s.to_string());
        } else if trimmed.starts_with("interface:") {
            old_dev = trimmed.split_whitespace().nth(1).map(|s| s.to_string());
        }
    }

    if let (Some(ref gw), Some(ref _dev)) = (&old_gw, &old_dev) {
        let _ = run_cmd("route", &["add", "-host", &server_ip, gw]);
        tracing::info!("Host route: {} via {}", server_ip, gw);
    } else {
        tracing::warn!("Could not detect original default gateway — split routing may fail");
    }

    run_cmd("route", &["add", "-net", "0.0.0.0/1", "-interface", tun_name])?;
    run_cmd("route", &["add", "-net", "128.0.0.0/1", "-interface", tun_name])?;
    tracing::info!("Policy routes set via {}: 0.0.0.0/1 and 128.0.0.0/1", tun_name);

    Ok(RouteCleanup {
        server_ip,
        old_gw,
        old_dev,
        tun_name: tun_name.to_string(),
    })
}

// ─── UTUN Creation ───────────────────────────────────────────────────────────

fn create_utun(addr_cidr: &str, mtu: u32) -> anyhow::Result<(RawFd, String)> {
    let fd = unsafe { libc::socket(AF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL) };
    if fd < 0 {
        anyhow::bail!("Failed to create AF_SYSTEM socket: {}", io::Error::last_os_error());
    }

    let mut info = ctl_info {
        ctl_id: 0,
        ctl_name: [0; 96],
    };
    for (i, &b) in UTUN_CONTROL_NAME.iter().enumerate() {
        info.ctl_name[i] = b as libc::c_char;
    }

    let ret = unsafe { libc::ioctl(fd, CTLIOCGINFO, &mut info as *mut _) };
    if ret < 0 {
        unsafe { libc::close(fd); }
        anyhow::bail!("CTLIOCGINFO failed: {}", io::Error::last_os_error());
    }

    let addr = sockaddr_ctl {
        sc_len: std::mem::size_of::<sockaddr_ctl>() as libc::c_uchar,
        sc_family: AF_SYSTEM as libc::c_uchar,
        ss_sysaddr: libc::AF_SYS_CONTROL as u16,
        sc_id: info.ctl_id,
        sc_unit: 0,
        sc_reserved: [0; 5],
    };

    let ret = unsafe {
        libc::connect(
            fd,
            &addr as *const _ as *const libc::sockaddr,
            std::mem::size_of_val(&addr) as libc::socklen_t
        )
    };
    if ret < 0 {
        unsafe { libc::close(fd); }
        anyhow::bail!("connect to utun failed: {}", io::Error::last_os_error());
    }

    let mut ifname = [0u8; 16];
    let mut ifname_len = ifname.len() as libc::socklen_t;
    let ret = unsafe {
        libc::getsockopt(
            fd,
            SYSPROTO_CONTROL,
            UTUN_OPT_IFNAME,
            ifname.as_mut_ptr() as *mut libc::c_void,
            &mut ifname_len,
        )
    };
    if ret < 0 {
        unsafe { libc::close(fd); }
        anyhow::bail!("getsockopt UTUN_OPT_IFNAME failed: {}", io::Error::last_os_error());
    }

    let ifname_str = std::str::from_utf8(&ifname[..(ifname_len as usize - 1)])
        .unwrap_or("utunX")
        .to_string();

    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL, 0);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }

    let ip = addr_cidr.split('/').next().unwrap_or("10.7.0.2");

    run_cmd("ifconfig", &[&ifname_str, ip, ip, "mtu", &mtu.to_string(), "up"])?;
    tracing::info!("TUN {} up: addr={} mtu={}", ifname_str, ip, mtu);

    Ok((fd, ifname_str))
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
        tracing::info!("PhantomVPN macOS Client starting (QUIC transport)...");

    let cfg = helpers::load_config(&args.config)?;

    let server_addr: SocketAddr = if let Some(ref sa) = args.server {
        sa.parse().context("Invalid --server address")?
    } else {
        cfg.network.server_addr.parse().context("Invalid config server_addr")?
    };
    tracing::info!("Server address: {}", server_addr);

    let client_keys = Arc::new(helpers::load_client_keys(&cfg)?);
    let server_public = helpers::load_server_public_key(&cfg)?;
    tracing::info!("Client public key: {}", hex::encode(&client_keys.public));

    // ─── QUIC endpoint ──────────────────────────────────────────────────
    let client_config = phantom_core::quic::make_client_config(cfg.network.insecure);
    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)
        .context("Failed to create QUIC endpoint")?;
    endpoint.set_default_client_config(client_config);

    tracing::info!("QUIC endpoint created");

    // ─── QUIC + Noise IK Handshake ──────────────────────────────────────
    let server_name = cfg.network.server_name.as_deref().unwrap_or("phantom");

    tracing::info!("Connecting to {} (SNI: {}) via QUIC...", server_addr, server_name);
    let (connection, noise_session, streams) = client_common::connect_and_handshake(
        &endpoint, server_addr, server_name, &client_keys, &server_public,
    ).await.context("QUIC handshake failed")?;
    tracing::info!("QUIC + Noise handshake complete ({} data streams)!", streams.len());

    // ─── TUN interface ───────────────────────────────────────────────────
    let tun_addr = cfg.network.tun_addr.as_deref().unwrap_or("10.7.0.2/24");
    let tun_mtu  = cfg.network.tun_mtu.unwrap_or(1350);

    tracing::info!("Creating macOS utun interface...");
    let (fd, ifname) = create_utun(tun_addr, tun_mtu)?;
    let async_tun = AsyncTun::new(fd).context("Failed to create async TUN")?;
    let (mut tun_reader, mut tun_writer) = tokio::io::split(async_tun);

    // Default route
    let _cleanup_guard = if cfg.network.default_gw.is_some() {
        match add_default_route(&ifname, &server_addr) {
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
    let noise_arc = Arc::new(noise_session);
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

    // ─── QUIC stream RX: N параллельных потоков → TUN ────────────────────
    for recv in recvs {
        let noise_rx = noise_arc.clone();
        let pkt_tx = quic_pkt_tx.clone();
        tokio::spawn(async move {
            if let Err(e) = client_common::quic_stream_rx_loop(recv, noise_rx, pkt_tx).await {
                tracing::error!("quic_stream_rx_loop exited: {}", e);
            }
        });
    }

    // ─── TUN → N параллельных QUIC streams ───────────────────────────────
    {
        let noise_tx = noise_arc.clone();
        tokio::spawn(async move {
            if let Err(e) = client_common::quic_stream_tx_loop(tun_pkt_rx, sends, noise_tx).await {
                tracing::error!("quic_stream_tx_loop exited: {}", e);
            }
        });
    }

    tracing::info!("Tunnel active on {}. Press Ctrl-C to exit.", ifname);

    // Wait for SIGINT or SIGTERM
    {
        let mut sigint = signal::unix::signal(signal::unix::SignalKind::interrupt())?;
        let mut sigterm = signal::unix::signal(signal::unix::SignalKind::terminate())?;

        tokio::select! {
            _ = sigint.recv() => { tracing::info!("Received SIGINT. Shutting down..."); }
            _ = sigterm.recv() => { tracing::info!("Received SIGTERM. Shutting down..."); }
        }
    }

    // Close QUIC connection gracefully
    connection.close(0u32.into(), b"client shutdown");

    // _cleanup_guard will be dropped here, restoring routes
    Ok(())
}
}

#[cfg(target_os = "macos")]
fn main() -> anyhow::Result<()> {
    macos::async_main()
}

#[cfg(not(target_os = "macos"))]
fn main() {
    println!("PhantomVPN macOS Client can only be run on macOS.");
}
